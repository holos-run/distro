# Talos provider

The Talos provider is the Kubernetes layer: Talos Linux on the VMs an
infrastructure provider makes, the way GKE is Kubernetes on GCE. It reaches
the VMs only through the compute contract, `infra.Compute` in
[`providers/infra`](../infra/infra.go), so the same code runs on Proxmox,
GCE or EC2, and its tests run against a fake compute.

It owns the Talos side: the Image Factory schematic and the ISO it names, the
nocloud network config each guest reads, rendered from the NIC compute
assigns the VM, the cluster's shape (the control plane and pools, their sizes
and addresses), the role and pool labels, `restart`, and `cluster.sh` with
the machine configuration patches. It does not create VMs, disks, buckets or
hypervisor credentials, and installs no CNI, storage class or platform
component: the cluster it hands over has its API and registered nodes, which
are not Ready until the platform installs Cilium.

The garage's compute is the [Proxmox provider](../proxmox/README.md), which
covers the API token, the snippets mount, the node network and its address
plan, the VM settings and the calls each command sends.

## talosvm

`talosvm` is the one program that wires the Proxmox provider into this layer.
The garage is rebuilt more than once, so the VMs come from a program rather
than from hand-made VMs, and the program is small: `talosvm create`, `list`,
`resize`, `restart` and `destroy`, plus `check` for the API token.

`talosvm` stops at VMs booted into Talos maintenance mode with a working
static network. It does not apply Talos machine configuration; that is the
next step, `talosctl` with the patches below ([Machine
configuration](#machine-configuration)).

### The image

Every VM boots the Talos `nocloud` ISO from
[Image Factory](https://factory.talos.dev) with three system extensions:

| Extension | Why it is there |
| --- | --- |
| `siderolabs/qemu-guest-agent` | Proxmox sees the VM's addresses and can shut it down cleanly. |
| `siderolabs/gvisor` | Present from day one so a later sandbox item never rebuilds the nodes. Substrate brings its own `runsc` inside its worker pods and does not use it. |
| `siderolabs/kata-containers` | The microVM sandbox class, configured by a later item. |

The schematic is fixed in the program, so its ID is stable: Image Factory
derives the ID from the content. `create` prints the schematic ID and the
installer image, `factory.talos.dev/nocloud-installer/<id>:<version>`, which
the Talos machine config must name so the installed system keeps the
extensions and the platform.

The platform is `nocloud`, not the `metal` of the Talos Proxmox guide, because
the `k8s` vnet has no DHCP. The nocloud platform reads the address, route,
resolver and hostname (the VM name) from the cloud-init drive Proxmox
attaches, whose network-config is the VM's snippet, so a VM is reachable in maintenance mode without anyone typing
kernel arguments at its console.

### Usage

`destroy -yes` takes the cluster's private root and the Anthropic key with it.
To rebuild a cluster, do not run it on its own: follow [Rebuilding a
cluster](../../holos/README.md#rebuilding-a-cluster), which runs `cmd/state
save` as the last step before it.

```sh
set -a; . ~/.config/holos/proxmox.env; set +a

go run ./providers/talos/cmd/talosvm check
go run ./providers/talos/cmd/talosvm create  -cluster treasury -dry-run
go run ./providers/talos/cmd/talosvm create  -cluster treasury
go run ./providers/talos/cmd/talosvm list    -cluster treasury
go run ./providers/talos/cmd/talosvm resize  -cluster treasury -dry-run
go run ./providers/talos/cmd/talosvm restart -cluster treasury -dry-run
go run ./providers/talos/cmd/talosvm destroy -cluster treasury        # prints the calls only
go run ./providers/talos/cmd/talosvm destroy -cluster treasury -yes   # sends them
```

The Proxmox credentials, the CA and the snippets mount are set up once
([Before the first run](../proxmox/README.md#before-the-first-run)).
`create -dry-run`, `resize -dry-run` and `destroy` without `-yes` print the
exact Proxmox API calls and send none of them
([What talosvm sends](../proxmox/README.md#what-talosvm-sends)).
`-cluster` also picks the cluster's committed config ([Config](#config)).

`create` checks the config and posts the schematic to Image Factory, which
names the ISO the VMs boot, then asks compute to plan the VMs: compute checks
every address, gives each new VM its MAC and node, and refuses any conflict
before anything changes. Then `create` renders each VM's network config from the NIC compute
planned and has compute make the VMs with it. A VM that exists keeps its
address, MAC and node; `create` only starts it if it is stopped, and points at
`resize` when it runs with another size than the config's.

`list` prints each VM's name, VMID, Proxmox cluster (region) and node (zone),
role, pool, address, status, cores and memory, and under `PENDING` a new
size `resize` gave a running VM that waits for its next start. The cluster and node become the worker's
`topology.kubernetes.io/region` and `zone` labels in the Talos patches, and
`list -json` prints the same rows for scripts.

### Resizing a pool

`create` makes VMs at the config's sizes and never changes one that exists,
so a new size for a pool, or for the control plane, reaches a running
cluster in three steps: change the size, `resize`, and power-cycle the VMs
one at a time.

```sh
set -a; . ~/.config/holos/proxmox.env; set +a

# 1. Change memoryMiB or cores in the cluster's file,
#    providers/talos/clusters/treasury/talosvm.json.
# 2. See what changes, then change it. Pass the -workers that create was
#    given, if any, and the -config, if it was given another file.
go run ./providers/talos/cmd/talosvm resize -cluster treasury -dry-run
go run ./providers/talos/cmd/talosvm resize -cluster treasury
# 3. Apply it, one node at a time: the command resize prints at the end.
go run ./providers/talos/cmd/talosvm restart -cluster treasury -mode power-cycle \
  -nodes treasury-general-1,treasury-general-2,treasury-general-3
```

`resize` reads each of the cluster's VMs' cores and memory, now and pending,
from `GET /nodes/{node}/qemu/{vmid}/pending`, and prints one line per VM:
`at size`, `resize` with what changes, `pending` for a VM an earlier resize
changed that has not been restarted since, `skip` for a VM of the cluster the
config does not ask for, and `missing` for one `create` has not made. For each
VM to change it sends `PUT /nodes/{node}/qemu/{vmid}/config` with `memory`,
`cores` or both, whichever differ, and nothing else: `balloon` stays `0`, and
the disk is never resized. Like every command it looks only at VMs with the
`talosvm` tag and this cluster's tag, whatever their names. `-nodes a,b`
limits it to the VMs named; without it every VM the config asks for is
resized. `-workers` overrides the first pool's count exactly as on `create`,
so a cluster made with `create -workers 5` is resized with `-workers 5`;
without it, workers beyond the config's count are skipped as VMs the config
does not ask for.

It refuses the whole run, dry run included, before any change, when:

- it would give a VM fewer cores or less memory than it runs with, unless
  `-shrink` is given, so a config that has fallen behind the VMs cannot
  shrink them; the refusal names each VM, current and new size;
- a VM's role or pool tag is not the one the config gives its name, such as
  a worker renamed by hand to `treasury-cp-1`;
- two of the cluster's VMs share a name, or `-nodes` names one that is not
  the cluster's.

The VMs have no CPU or memory hotplug, so Proxmox holds the change to a
running VM as pending, and the VM keeps its old size until it is stopped and
started; a reboot inside the guest keeps the running QEMU process and does
not apply it. A stopped VM takes the change at once. `resize` ends with the
`restart -mode power-cycle -nodes ...` command for every running VM whose new
size waits, including those an earlier run changed, so a rerun after an
interrupted restart prints what is still to do. `list` shows those VMs'
pending size until they are restarted; a VM whose pending size cannot be
read shows `?` there (and no pending fields in `-json`), with a warning on
stderr, and the rest of the list is printed as usual.

### Restarting nodes

`restart` restarts the cluster's workers one at a time, in name order, or
the VMs `-nodes` names, in that order. It is for a change a node only picks
up when it starts, such as containerd reading a new trust store or the VM
getting new memory:

```sh
set -a; . ~/.config/holos/proxmox.env; set +a
export KUBECONFIG=~/.config/holos/talos/treasury/kubeconfig
export TALOSCONFIG=~/.config/holos/talos/treasury/talosconfig

go run ./providers/talos/cmd/talosvm restart -cluster treasury -dry-run          # the steps of every node
go run ./providers/talos/cmd/talosvm restart -cluster treasury                   # talosctl reboot
go run ./providers/talos/cmd/talosvm restart -cluster treasury -mode power-cycle # Proxmox shutdown and start
go run ./providers/talos/cmd/talosvm restart -cluster treasury -nodes treasury-general-2
```

`-mode reboot`, the default, runs `talosctl reboot`, which is enough for
anything inside the guest. `-mode power-cycle` shuts the VM down and starts
it again through the Proxmox API (`status/shutdown`, then `status/start`). A
changed VM config, such as new memory, applies only this way, because a
guest reboot keeps the running QEMU process. The shutdown is a clean one,
through the guest agent, so Talos stops its kubelet and unmounts its volumes
as on a reboot; `forceStop` makes Proxmox stop the VM hard if it has not shut
down within `-shutdown-timeout` (5m), so the VM always ends up stopped and is
then started.

For each node in turn it:

1. cordons it, so nothing new is scheduled there while it goes down, and
   marks the cordon its own with the annotation `talosvm.holos.run/cordoned`.
   A node that still reads `Ready` otherwise keeps being sent replacement
   pods, which its shutting-down kubelet refuses to admit with
   `NodeShutdown`: this is what left a hundred Failed `cilium-operator` pods
   on the treasury workers after a hand-run reboot loop;
2. restarts it in the chosen mode;
3. waits until it has booted again, which it tells by the node's boot ID
   changing, so a node that has not gone down yet is never taken for one that
   is back; then until it is `Ready`; then until every DaemonSet that had a
   Ready pod on it, Cilium and ztunnel among them, has a Ready pod again
   that is another pod, or the same pod with new container IDs, since right
   after a quick reboot the API can still show the old containers Ready;
4. uncordons it and removes the annotation;
5. deletes the Failed pods left on it, and prints how many of each kind:
   those with reason `Terminated` that the kubelet's graceful node shutdown
   killed (message "Pod was terminated in response to imminent node
   shutdown.", or a `DisruptionTarget` condition with reason
   `TerminationByKubelet`), those it refused with `NodeShutdown`, `Evicted`
   ones, and those whose container status is `ContainerStatusUnknown`. A
   Failed pod with any other reason or message, such as a Job's pod that
   exited with `Error`, and every pod that is not Failed, stay;
6. waits until every Deployment and StatefulSet that had a pod on it, and was
   available before the restart, is available again. This, not the node
   alone, is what catches a dependency coming back late, as Keycloak did for
   Quay. One that was not available before is named and not waited for.

Only then does it move to the next node.

It does not drain. A drain would not keep pods in place either: the
kubelet's graceful node shutdown stops the node's pods, and their
controllers recreate Deployment and StatefulSet pods on the other workers,
which are not cordoned, so pods and their RBD volumes can move, and a
StatefulSet's new pod can wait in `Multi-Attach` until the old node reports
the volume unmounted. Step 6 is what waits for those moved and recreated
workloads. What a drain would add is evicting them first, through
PodDisruptionBudgets, which the shutdown does not honor; whether to add
`-drain` is left for later.

It drives `kubectl` and `talosctl` (`-kubectl`, `-talosctl`), which act with
the kubeconfig and talosconfig `KUBECONFIG` and `TALOSCONFIG` name, and
reaches Talos at the VM's own address, from its config or its network
snippet, or the node's `InternalIP` when the snippets mount is not there.
`-talosctl` defaults to plain `talosctl`, so a cluster whose
`talosVersion` differs from that binary, or a machine that has only
`talosctl-<version>`, passes `-talosctl talosctl-<version>`.
Before it changes anything it checks the token's privileges and refuses
unless:

- every node is `Ready`, the control plane included, since it runs the
  Cilium agent like every node. The check runs again before each node;
- every target is a running VM of the cluster with a Kubernetes node of the
  same name, and the VM's address and the node's `InternalIP` agree, which
  also catches a `KUBECONFIG` of another cluster;
- every target worker has a Ready pod of each `-require-daemonsets`
  (default `kube-system/cilium,istio-system/ztunnel`).

The control plane is restarted only when `-nodes` names it. With one control
plane the Kubernetes API is down while it restarts; `restart` waits through
that for its new boot ID, then for `Ready` and its Cilium agent and envoy.

`-timeout` (15m) bounds one node, from cordon to its workloads being
available. A failure or a timeout stops the run at that node and does not go
on to the next. A node that fails before it is uncordoned is left cordoned,
so nothing is scheduled onto a node that did not come back; the error says
so, and names the nodes not restarted and the `-nodes` to rerun them with.
A rerun uncordons a node a failed run left cordoned, which it knows by the
annotation; a node someone else cordoned, without it, stays cordoned after
its restart.

A power cycle that fails or times out in the shutdown can leave the VM still
shutting down, and one that fails in the start leaves it stopped; a rerun
refuses a stopped VM, so the error says to start it in Proxmox.

`-dry-run` does the same reads and checks and prints every node's steps,
with the exact `kubectl` and `talosctl` commands and Proxmox calls, and
changes nothing.

### Config

Each cluster's config is committed at
`providers/talos/clusters/<cluster>/talosvm.json`. It records the Talos
version, addresses and sizes the cluster was made with, with the endpoint name
and Kubernetes version of one that states its own, and nothing in it is secret.
`-cluster` finds the file from the repository root, the nearest directory at or
above the working directory whose `go.mod` declares
`go.holos.run/distro`, so the commands run from anywhere in the repository.
`-config` names another file instead.

`create` and `resize` refuse a cluster with no file, naming the path, and
refuse to run outside the repository without `-config`: falling back would
let a mistyped name build from the defaults at .50. `list`, `restart` and
`destroy` use the file when it is there and go on without it. A file that is
there but cannot be read or decoded is an error for every command, and so is
a `-config` that does not exist.

The file sits over the built-in defaults below. It overrides only the fields
it names, except that `pools` replaces the default pools as a whole; unknown
fields are an error. `-cluster`, `-first-address` and `-workers` (the first
pool's count, on `create` and `resize`) override the file.

The file holds both layers' settings, with flat keys as before the split:
`nodes`, the storages, `diskSSD`, `nameserver` and `searchDomain` are the
Proxmox provider's (`proxmox.Config`), and the rest is the cluster's
(`talos.Config`), whose `bridge` and `firstAddress` defaults are the
provider's node network and first node address.

```json
{
  "cluster": "treasury",
  "talosVersion": "v1.14.4",
  "nodes": [],
  "diskStorage": "local-zfs",
  "isoStorage": "garage",
  "snippetStorage": "garage",
  "diskSSD": true,
  "bridge": "k8s",
  "nameserver": "192.168.2.1",
  "searchDomain": "lan",
  "firstAddress": "10.20.0.50",
  "controlPlane": { "count": 1, "cores": 2, "memoryMiB": 8192, "diskGiB": 32 },
  "pools": [
    { "name": "general", "count": 3, "cores": 4, "memoryMiB": 16384, "diskGiB": 64 }
  ]
}
```

- `cluster` has no default: every command names the cluster it acts on. A
  committed file's `cluster` is the name of its directory.
- `talosVersion` picks the Image Factory ISO. `cluster.sh` reads it too, so
  one cluster can lead another on a patch.
- `endpoint`, not set by default, is a DNS name for the cluster's Kubernetes
  endpoint: a lowercase name of at least two labels, the last starting with a
  letter, with no scheme, port or trailing dot, such as `api.example.internal`.
  `cluster.sh gen` generates the cluster with `https://<endpoint>:6443` in place of
  `https://<control plane address>:6443`, so the kubeconfig, the nodes' machine
  configs and the service account issuer carry the name. Set it before the first
  `gen`: the endpoint and the issuer are fixed when the configs are generated.
  The name must resolve to the control plane's address for `kubectl`, for the
  nodes and in pods; what that costs is in [ADR
  0001](../../docs/adr/0001-talos-cluster-profile.md). `talosctl` stays on the
  address.
- `kubernetesVersion` is the Kubernetes release `gen` generates the cluster with,
  such as `1.37.2`, without a leading `v`. Its default is `KUBERNETES_VERSION` in
  `cluster.sh`.
- `cluster.sh` reads `endpoint` and `kubernetesVersion` from the file itself, as
  it does `talosVersion`, and like `create` and `resize` refuses a value that is
  not of the form above, an empty string included. `null` is the same as leaving
  the field out. The script also refuses either key in another case, such as
  `Endpoint`.
- `nodes` is the Proxmox nodes to spread VMs across, round robin, starting
  with the control plane. Empty means every online node, sorted by name;
  naming them keeps placement stable when a host is down, and `create` refuses
  the whole run while a named node is offline. `controlPlane` and each pool
  take their own `nodes` to pin a group.
- `firstAddress` is the cluster's first node address. VMs take consecutive
  addresses in the order `cp-1`, then each pool's workers. `controlPlane` and
  each pool take an `addresses` list instead, one per VM.
- The control plane count must be odd, for etcd; sizes must meet the Talos
  minimums of 2 cores, 2048 MiB and 10 GiB.

A microVM pool later is a second pool entry:

```json
{ "name": "microvm", "count": 2, "cores": 8, "memoryMiB": 16384, "diskGiB": 100, "nodes": ["r620c"] }
```

## Machine configuration

`talosvm` stops at VMs in Talos maintenance mode. `cluster.sh` turns them
into a Kubernetes cluster with `talosctl` and the patches committed here, as
[ADR 0001](../../docs/adr/0001-talos-cluster-profile.md) decided. There is
no program: `cluster.sh` is a thin wrapper that reads the node inventory from
`talosvm list -json` and runs `talosctl`.

The result is one control plane node and the workers, bootstrapped, with no
CNI and no kube-proxy. Every node stays `NotReady` until Cilium is installed,
the control plane included: the Cilium agent and envoy run there, as upstream
Talos runs its CNI, so the API server reaches Services in the cluster, and
Talos's default `node-role.kubernetes.io/control-plane:NoSchedule` taint
keeps every other pod off it (ADR 0003). The API server reaches every
admission webhook by the Service its configuration names (Admission
webhooks, below).

### Patches

| File | Applies to | Sets |
| --- | --- | --- |
| [`patches/all.yaml`](patches/all.yaml) | every node | KubePrism on `127.0.0.1:7445`; sysctls for sandbox density and user namespaces |
| [`patches/controlplane.yaml`](patches/controlplane.yaml) | control plane | Flannel deleted, kube-proxy disabled, Talos's CoreDNS disabled; API server `runtime-config=certificates.k8s.io/v1beta1=true` and `enable-aggregator-routing=true` |
| `clusters/<cluster>/controlplane.yaml` (optional, committed; none today) | the cluster's control plane | whatever that one cluster needs |
| `nodes/<vm>.patch.yaml` (generated) | one node | `topology.kubernetes.io/region` and `zone`, and `holos.run/nodepool` on workers |

The sysctls:

| Sysctl | Value | Source |
| --- | --- | --- |
| `net.ipv4.neigh.default.gc_thresh1` | 4096 | Substrate's GKE node pool (`tools/setup-gcp/cmd/cluster.go`) |
| `net.ipv4.neigh.default.gc_thresh2` | 16384 | same |
| `net.ipv4.neigh.default.gc_thresh3` | 32768 | same |
| `fs.inotify.max_user_instances` | 65536 | same |
| `fs.inotify.max_user_watches` | 1048576 | same |
| `user.max_user_namespaces` | 11255 | Talos's user namespace test patch; Talos defaults it to 0 |

The node labels come from `talosvm list`: region is the Proxmox cluster
(`garage`), zone is the Proxmox node the VM was created on, and the pool is
the worker's pool label, which Proxmox keeps as its `talosvm-pool-<name>` tag. A VM moved to another Proxmox node
keeps its old zone until `gen` and `apply` run again.

The patches in `patches/` name no cluster, node or address. `gen` adds the
rest:

- the cluster's own patch, `clusters/<cluster>/controlplane.yaml`, on the
  control plane, if the file exists;
- the cluster name and the endpoint, `https://<control plane address>:6443`, or
  `https://<endpoint>:6443` when the cluster's config sets `endpoint`, with no
  VIP;
- the installer image `factory.talos.dev/nocloud-installer/<schematic>:<talosVersion>`,
  where the schematic is read from the control plane node itself
  (`talosctl get extensions`), or taken from `INSTALLER` when set. It must
  be the schematic `talosvm create` printed, so the installed system keeps
  the extensions and the `nocloud` platform;
- the Talos config of the minor release of the cluster's `talosVersion`, such
  as `v1.14`, and Kubernetes `1.37.1`, the default in the script, or the
  config's `kubernetesVersion`.

The machine config has no network section. The installed system is still the
`nocloud` platform, so it keeps reading the /32 address, the on-link default
route and MTU 8950 from the VM's cloud-init snippet on every boot, exactly as
in maintenance mode.

### Secrets and state

Everything `cluster.sh` writes lives outside the repository, in
`~/.config/holos/talos/<cluster>/` (or `$HOLOS_TALOS_DIR/<cluster>/`). The
script sets `umask 077`, so directories are 0700 and files 0600:

| File | What it is |
| --- | --- |
| `secrets.yaml` | `talosctl gen secrets`: the cluster CAs, tokens and keys. Generated once and reused, so regenerating configs keeps the cluster's identity. |
| `nodes.json` | The `talosvm list -json` inventory `gen` used. |
| `nodes/<vm>.yaml` | Each node's full machine config, which embeds secrets. |
| `nodes/<vm>.patch.yaml` | Each node's label patch. |
| `talosconfig` | Talos API client config, endpoint and node set to the control plane's address, also when the config sets `endpoint`. |
| `kubeconfig` | Cluster admin kubeconfig. Its server is the endpoint: the config's `endpoint`, or else the control plane's address. |

Back the directory up: without `secrets.yaml` and `talosconfig` the cluster
can no longer be administered, and no snapshot of its etcd can be restored.
[etcd snapshots](#etcd-snapshots) writes an encrypted copy every day, for a
cluster that has them.

### Bringing a cluster up

This section is steps 7 and 8 of [Adding a
cluster](../../holos/README.md#adding-a-cluster), the whole procedure for a
new cluster. A rebuild is [Rebuilding a
cluster](../../holos/README.md#rebuilding-a-cluster), which saves the cluster's
state with `cmd/state` before tearing it down, then uses that procedure from
step 8 and restores the state inside step 9.

`kubectl`, `jq`, Go and the `talosctl` of the cluster's `talosVersion` are
needed, and `gen` and `apply` read the inventory with `talosvm list`, which
needs the Proxmox credentials and the snippets mount described in the [Proxmox
provider README](../proxmox/README.md#snippets); without
the mount it leaves addresses blank and the script refuses.

`cluster.sh` reads `talosVersion` from the cluster's `talosvm.json`. It runs
`TALOSCTL` when that is set, else `talosctl-<version>` on `PATH`, else plain
`talosctl`, and refuses any of them that is not that version, printing the
steps below for it. Install `talosctl` from the Talos release, checking its
checksum, starting from the repository root with `cluster` set to the cluster's
name:

```sh
version=$(jq -r .talosVersion "providers/talos/clusters/$cluster/talosvm.json")
asset=talosctl-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
cd "$(mktemp -d)"
gh release download "$version" -R siderolabs/talos -p "$asset" -p sha256sum.txt
grep " $asset\$" sha256sum.txt | shasum -a 256 -c -
mkdir -p ~/.local/bin
install -m 0755 "$asset" ~/.local/bin/"talosctl-$version"
```

The `talosctl` commands run by hand below mean that binary, under its own name
or a link named `talosctl`.

Then, from the repository root, with `cluster` set and the Proxmox
credentials loaded for `talosvm list`:

```sh
set -a; . ~/.config/holos/proxmox.env; set +a

go run ./providers/talos/cmd/talosvm create -cluster "$cluster"

# create returns once Proxmox has started the VMs, before Talos is up. Wait
# until every node answers in maintenance mode (under a minute on the garage).
# Only for new VMs: a configured node never answers --insecure, so the loop
# would wait forever on a cluster that is already up.
for a in $(go run ./providers/talos/cmd/talosvm list -cluster "$cluster" -json | jq -r '.[].address'); do
  until talosctl get machinestatus -n "$a" --insecure >/dev/null 2>&1; do sleep 5; done
done

providers/talos/cluster.sh up "$cluster"

export TALOSCONFIG=~/.config/holos/talos/$cluster/talosconfig
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
talosctl health
kubectl get nodes -o wide --show-labels
```

`up` is `gen`, `apply` and `bootstrap`, which also run alone:

- `gen` reads the inventory, generates `secrets.yaml` if it is missing, and
  writes every node's config. It refuses a cluster without exactly one
  control plane VM.
- `apply` sends each node its config: with `--insecure` to a node in
  maintenance mode, which installs Talos to `/dev/sda` and reboots, and over
  the authenticated API to a node that is already configured. A node that
  has not booted yet does not answer the insecure probe, so `apply` takes it
  for a configured node and the authenticated call fails, which is why the
  usage above waits for maintenance mode first; `gen` also reads the schematic from the control
  plane node over the same insecure API, unless `INSTALLER` is set.
- `bootstrap` waits for the control plane, bootstraps etcd (an etcd that is
  already bootstrapped is fine), and writes the kubeconfig once the API
  server answers.

All three can be rerun. To change the patches on a running cluster, edit
them, then `gen` and `apply`.

### etcd snapshots

Marina has one control plane node, so its etcd is snapshotted every day from
the operator's machine: the claude VM, host `claude`, 10.20.0.4, which ran
`cluster.sh` for marina and holds `~/.config/holos/talos/marina/`. Treasury
and cartography have no snapshots. A systemd user timer there,
`etcd-snapshot@marina.timer`, runs [`etcd-snapshot.sh`](etcd-snapshot.sh),
which writes two files with one UTC timestamp to the `garage` export, mounted
at `/mnt/pve/garage` ([The backups
directory](../proxmox/README.md#the-backups-directory)):

| File in `/mnt/pve/garage/backups/etcd/marina/` | What it is |
| --- | --- |
| `marina-<timestamp>.snapshot` | `talosctl etcd snapshot`, not encrypted. |
| `marina-<timestamp>.secrets.tar.gpg` | `~/.config/holos/talos/marina/`, encrypted to the key the unit names. |

The timestamp is in the form `20261125T101700Z`, so the last in a listing is
the newest. A run writes both under hidden names and puts them in place only
once both are whole, the archive first, so a snapshot that is there has its
archive. It refuses a name that exists. Only after a run that worked does it
delete the old ones: it keeps the newest 30 snapshots, a month of daily runs,
and their archives, and touches no other file.

The units are in [`systemd/`](systemd/). The timer runs at 03:17 local time,
give or take, and at the next start of a machine that was off
(`Persistent=true`). The service fails, and leaves the unit failed, when the
export is not mounted: the mount is `nofail`, and a snapshot must not land on
the local disk in its place. The mount belongs to the system manager, so the
unit tests for it with `mountpoint` rather than `RequiresMountsFor=`, which
does nothing in a user unit, and the script tests again. A failed run is tried
again every 10 minutes, four times in all, for a boot that reaches the timer
before the mount. The export is mounted `hard`, so a run that blocks on it is
ended after 15 minutes.

Encrypting needs only the public key, so a run needs no unlocked key.

#### Installing the timer

The service runs an installed copy of the script, so it depends on no checkout.
Install again after a change to the script or the units. From the repository's
root on the operator's machine, with `cluster` set:

```sh
install -D -m 0755 providers/talos/etcd-snapshot.sh ~/.local/libexec/holos/etcd-snapshot.sh
install -D -m 0644 -t ~/.config/systemd/user providers/talos/systemd/etcd-snapshot@.service providers/talos/systemd/etcd-snapshot@.timer
install -D -m 0644 -t ~/.config/systemd/user/etcd-snapshot@$cluster.service.d providers/talos/systemd/etcd-snapshot@$cluster.service.d/cluster.conf
loginctl show-user "$USER" -p Linger   # yes, or: sudo loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user enable --now etcd-snapshot@$cluster.timer

systemctl --user start etcd-snapshot@$cluster.service   # one run now; returns when it is done
journalctl --user -u etcd-snapshot@$cluster -n 10 -o cat
systemctl --user list-timers
providers/talos/etcd-snapshot.sh check $cluster
```

The last command is the one that tells whether snapshots still work, and is in
[Check](../../holos/README.md#check): it prints the newest snapshot's name and
age, and fails when that is more than 48 hours old, not whole or without its
archive, when there is none, or when the export is not mounted. The age is the
name's, the time the run began, since a file's mtime changes when it is copied.

Decrypt one archive by hand when the timer is installed, to show that the key
opens it, listing the names alone (done on 2026-11-25 for marina):

```sh
gpg -d "$(ls /mnt/pve/garage/backups/etcd/$cluster/*.secrets.tar.gpg | tail -n 1)" | tar -t
```

The cluster's own settings are in its drop-in,
[`etcd-snapshot@marina.service.d/cluster.conf`](systemd/etcd-snapshot@marina.service.d/cluster.conf):
the control plane's address, and the `talosctl` of the cluster's Talos
version, by its full path, since a user unit's `PATH` has no `~/.local/bin`.
**An upgrade of the cluster's Talos must change the version there too**, and
install it again; `go test` fails while the two disagree. Another cluster is a
drop-in of its own and the block above.

Stop the timer before a restore, or before tearing the cluster down, so that
what it takes next is not taken for the newest good snapshot.

#### What this leaves open

- The snapshots are not encrypted. Talos encrypts Secret values in etcd with a
  key that is in the encrypted archive, but every other object is in clear, and
  any host on the LAN can mount the export and, as root, read, write and delete
  what is on it.
- The GPG secret key is on the same VM as the secrets it protects, and that VM
  runs on the garage. Losing the VM loses the secrets and the key that opens
  their copy.
- A stopped timer is seen only by someone who looks. The admin client
  certificate in the talosconfig expires after a year, for marina on
  2027-11-25, and that will stop it.
- The timer uses the admin talosconfig. A narrower Talos role may be enough.
- A run that is killed outright leaves a hidden `.partial` file of some 50 MB,
  which nothing removes or takes for a snapshot.

### Restoring etcd from a snapshot

> **Unrehearsed.** Nobody has run this procedure. It was written on 2026-11-25
> against Talos v1.14.7, from `talosctl`'s own help, Talos's [disaster
> recovery
> guide](https://docs.siderolabs.com/talos/v1.14/build-and-extend-talos/cluster-operations-and-maintenance/disaster-recovery)
> and the code here. Read it to the end before you start.

Use it when the control plane is lost and the workers and Ceph are intact.
Otherwise [rebuild](../../holos/README.md#rebuilding-a-cluster). It brings the
cluster's objects back as they were when the snapshot was taken, with the same
cluster identity, so the workers rejoin as they are. What was made since is
gone from the API: a volume made since is left in Ceph with no PersistentVolume,
and one deleted since comes back with none.

What not to do:

- **Do not run `cluster.sh up` or `cluster.sh bootstrap`.** Both run a plain
  `talosctl bootstrap`, which makes an empty etcd, and `--recover-from` is then
  refused until the node is wiped.
- **Do not run any `cluster.sh` command before the secrets directory is back.**
  With no `secrets.yaml`, `cluster.sh gen` makes new secrets without asking: a
  new cluster identity, which no snapshot fits.
- **Do not run `talosvm destroy`.** It takes the whole cluster, and the private
  root with it. A dead control plane VM is removed by hand in Proxmox.
- **Do not remove the VM, or wipe its disk, while it might still start.** Its
  disk has an etcd newer than any snapshot. Power-cycle it in Proxmox first.

Which block: if the VM runs and Talos answers (the `talosctl version` in the
second block), it is the second. If the VM is gone, its disk is lost, or Talos
never answers, it is the first.

Both are for marina, from the repository's root on the operator's machine, and
need its GPG key unlocked (an `attach-gpg` pane) if the secrets directory is
gone. Run them a few lines at a time, reading what each prints. The version in
`talosctl` is the cluster's `talosVersion`, in
[`talosvm.json`](clusters/marina/talosvm.json), and [Bringing a cluster
up](#bringing-a-cluster-up) installs it.

#### The control plane VM is gone

`talosvm create` makes the VMs the config asks for that do not exist, so here
the control plane alone, at the same size and address and on the first online
Proxmox node by name. It changes none of the VMs that exist, beyond starting a
stopped one and writing a snippet that is missing. Two things stand in its way:

- The dead VM, while Proxmox still lists it. It counts as existing, so `create`
  only tries to start it. Remove it by hand first. Its snippet can stay.
- An offline host. `create` refuses the whole run while `r620a`, `r620b` or
  `r620c` is offline, since marina's workers are pinned to them, though it
  makes no worker here. It also fails while any other host with a guest on it
  is, since it reads every guest's config to check addresses.

A control plane lost with its host therefore waits for the host. The case where
the host never comes back is not written here.

```sh
setopt interactivecomments 2>/dev/null || true
cluster=marina cp=10.20.0.70
talosctl=~/.local/bin/talosctl-v1.14.7
"$talosctl" version --client --short
state=~/.config/holos/talos/$cluster
export TALOSCONFIG=$state/talosconfig KUBECONFIG=$state/kubeconfig
systemctl --user disable --now etcd-snapshot@$cluster.timer
systemctl --user stop etcd-snapshot@$cluster.service

# The newest snapshot, the last in the listing. Check that its size is like the
# rest and that it is older than the failure, or else set snap by hand.
ls -l /mnt/pve/garage/backups/etcd/$cluster/
snap=$(ls /mnt/pve/garage/backups/etcd/$cluster/$cluster-*.snapshot | tail -n 1)
ls -l "${snap:?}"

# Only if the secrets directory is gone. If it is there and a file below is
# missing, or it may hold new secrets, move it aside and run this again.
[ -e "$state" ] || (umask 077 && mkdir -p ~/.config/holos/talos &&
  gpg -d "${snap%.snapshot}.secrets.tar.gpg" | tar -x -C ~/.config/holos/talos)
ls -l $state/secrets.yaml $state/talosconfig $state/nodes/$cluster-cp-1.yaml

# Remove the dead VM by hand, in Proxmox: marina-cp-1, and no other VM.
set -a; . ~/.config/holos/proxmox.env; set +a

# The list must show the workers alone, and the dry run make marina-cp-1 alone.
go run ./providers/talos/cmd/talosvm list -cluster $cluster
go run ./providers/talos/cmd/talosvm create -cluster $cluster -dry-run
go run ./providers/talos/cmd/talosvm create -cluster $cluster

# Maintenance mode, then the saved config, which installs Talos and reboots.
until "$talosctl" get machinestatus -n $cp --insecure >/dev/null 2>&1; do sleep 5; done
"$talosctl" apply-config -n $cp --insecure --file $state/nodes/$cluster-cp-1.yaml

# etcd waits in Preparing for a bootstrap, a few minutes later. If it says
# Running instead, stop here, since something has bootstrapped it. If the
# bootstrap says it is not available yet, wait and run that line again.
until "$talosctl" -n $cp service etcd 2>/dev/null | grep -E '^STATE +(Preparing|Running)'; do sleep 5; done
[ -s "${snap:?}" ] && "$talosctl" -n $cp bootstrap --recover-from="$snap"

# Running and OK, marina-cp-1 the only member, and in a few minutes every node
# Ready.
"$talosctl" -n $cp service etcd
"$talosctl" -n $cp etcd members
until kubectl get --raw /readyz; do sleep 5; done
kubectl get nodes
```

If `create` put the VM on another Proxmox node than before, its zone label is
the old one. Once the node is back, `cluster.sh gen` writes the new one to its
config, and this applies it to that node alone:

```sh
"$talosctl" -n $cp apply-config --file $state/nodes/$cluster-cp-1.yaml
```

Not `cluster.sh apply`, which sends every node its saved config. The workers'
saved configs have no [trust of the
root](../../holos/README.md#trusting-the-root-on-the-workers), which is patched
in live, so it would go.

#### The VM is alive and etcd is broken

Here Talos answers and etcd does not work. Wiping the node's `EPHEMERAL`
partition takes the broken etcd away, and the node then waits for a bootstrap
as a new one does. Its machine config is on `STATE`, which stays, so the node
comes back configured and no config is applied.

`EPHEMERAL` is all of `/var`: besides etcd's data, the containers and their
images, the kubelet's state and certificates, the CNI's, and the node's logs,
which is the evidence of what broke. All of it but etcd is made again when the
node starts. Nothing but the control plane's own pods and the DaemonSets runs
there, so no workload's data is on it.

```sh
setopt interactivecomments 2>/dev/null || true
cluster=marina cp=10.20.0.70
talosctl=~/.local/bin/talosctl-v1.14.7
"$talosctl" version --client --short
state=~/.config/holos/talos/$cluster
export TALOSCONFIG=$state/talosconfig KUBECONFIG=$state/kubeconfig
systemctl --user disable --now etcd-snapshot@$cluster.timer
systemctl --user stop etcd-snapshot@$cluster.service

# The newest snapshot, the last in the listing. Check that its size is like the
# rest and that it is older than the failure, or else set snap by hand.
ls -l /mnt/pve/garage/backups/etcd/$cluster/
snap=$(ls /mnt/pve/garage/backups/etcd/$cluster/$cluster-*.snapshot | tail -n 1)
ls -l "${snap:?}"

# Only if the secrets directory is gone. If it is there and a file below is
# missing, or it may hold new secrets, move it aside and run this again.
[ -e "$state" ] || (umask 077 && mkdir -p ~/.config/holos/talos &&
  gpg -d "${snap%.snapshot}.secrets.tar.gpg" | tar -x -C ~/.config/holos/talos)
ls -l $state/secrets.yaml $state/talosconfig

# See that it is really broken. A reboot is the cheapest repair.
"$talosctl" -n $cp version --short
"$talosctl" -n $cp service etcd
"$talosctl" -n $cp etcd members
"$talosctl" -n $cp logs etcd | tail -n 50

# Keep what the node has. It stays out of the restore unless you choose it
# below.
keep=$HOME/$cluster-etcd-$(date -u +%Y%m%dT%H%M%SZ); (umask 077 && mkdir "$keep")
"$talosctl" -n $cp etcd snapshot "$keep/etcd.snapshot"
"$talosctl" -n $cp cp /var/lib/etcd/member/snap/db "$keep"
"$talosctl" -n $cp logs etcd >"$keep/etcd.log"
ls -lR "$keep"

# Wipe etcd, with all of EPHEMERAL, and reboot, only with a snapshot in hand.
[ -s "${snap:?}" ] && "$talosctl" -n $cp reset --graceful=false --reboot --system-labels-to-wipe=EPHEMERAL

# etcd waits in Preparing for a bootstrap. If it says Running, stop here. If
# the bootstrap says it is not available yet, wait and run that line again.
until "$talosctl" -n $cp service etcd 2>/dev/null | grep -E '^STATE +(Preparing|Running)'; do sleep 5; done
[ -s "${snap:?}" ] && "$talosctl" -n $cp bootstrap --recover-from="$snap"

# Running and OK, marina-cp-1 the only member, and in a few minutes every node
# Ready.
"$talosctl" -n $cp service etcd
"$talosctl" -n $cp etcd members
until kubectl get --raw /readyz; do sleep 5; done
kubectl get nodes
```

`--graceful=false` skips leaving etcd, which a broken one cannot do.
`--recover-skip-hash-check` is not for a snapshot that `talosctl etcd snapshot`
made, here or by the timer, since it ends with its hash. The copied `db` has
none: to restore that instead, because the snapshot is too old, set
`snap=$keep/db` and add the flag, and expect that the file may not be
consistent.

`$keep/etcd.snapshot`, when etcd still answered, is newer than the timer's.
Restore it, with `snap=$keep/etcd.snapshot`, only when what it holds is good: a
size and number of keys like the timer's, and no mistake in the data itself. An
etcd that a plain `bootstrap` made empty answers too, and its snapshot restores
the emptiness.

#### After either

The controllers on the workers remember versions of objects newer than the
restored ones. Once every node is Ready, restart the workers, one at a time, which also restarts their
kubelets ([Restarting nodes](#restarting-nodes)), then run
[Check](../../holos/README.md#check) and start the timer again:

```sh
set -a; . ~/.config/holos/proxmox.env; set +a
go run ./providers/talos/cmd/talosvm restart -cluster $cluster -talosctl "$talosctl"
systemctl --user enable --now etcd-snapshot@$cluster.timer
systemctl --user start etcd-snapshot@$cluster.service
providers/talos/etcd-snapshot.sh check $cluster
```

Delete `$keep` once the cluster is well.

### Admission webhooks

The API server reaches every admission webhook by the `service:` reference
its configuration names, as ADR 0003 requires: the control plane runs a
Cilium agent, so the API server, a host-network static pod, reaches pods on
the overlay, and `--enable-aggregator-routing` makes it dial the Service's
endpoints, as GKE and EKS do. Nothing in the machine config names a webhook,
so a webhook added to the platform needs no change here.

A control plane configured before ADR 0001's Gateway webhook path was
retired still has its `StaticHostConfig`, which pointed every webhook
hostname at the ingress Gateway's address. Nothing uses the entries. A
`gen` and `apply` drops them; without the Proxmox credentials `gen` needs,
delete the document in place, which needs no reboot, and bring the saved
config in step so that a later `apply` without `gen` does not restore it:

```sh
export TALOSCONFIG=~/.config/holos/talos/treasury/talosconfig
del=$'apiVersion: v1alpha1\nkind: StaticHostConfig\nname: 10.20.0.30\n$patch: delete'
talosctl -n 10.20.0.50 patch mc -p "$del" --dry-run   # "without a reboot", and the diff
talosctl -n 10.20.0.50 patch mc -p "$del" --mode no-reboot
talosctl -n 10.20.0.50 get statichosts                # treasury-cp-1 alone, the node's own name
c=~/.config/holos/talos/treasury/nodes/treasury-cp-1.yaml
talosctl machineconfig patch $c -p "$del" --output $c
```

`talosctl health` passes without a CNI: it skips the node-ready, kube-proxy
and CoreDNS checks. Talos's own CoreDNS is disabled by the control plane
patch, so the cluster has no DNS until the platform's `cilium`,
`cilium-resources` and `coredns` components are applied; see
[holos/README.md](../../holos/README.md).
