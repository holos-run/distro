# Talos provider

The Talos provider is the Kubernetes layer: Talos Linux on the VMs an
infrastructure provider makes, the way GKE is Kubernetes on GCE. It reaches
the VMs only through the compute contract, `infra.Compute` in
[`providers/infra`](../infra/infra.go), so the same code runs on Proxmox,
GCE or EC2, and its tests run against a fake compute.

It owns the Talos side: the Image Factory schematic and the ISO it names, the
nocloud network config each guest reads, rendered from the NIC compute
assigns the VM, the cluster's shape (the control plane and pools, their sizes
and addresses), the role and pool labels, `restart`, `cluster.sh` with the
machine configuration patches, and each cluster's rendered patches under
`clusters/<cluster>/`. It does not create VMs, disks, buckets or hypervisor
credentials, and installs no CNI, storage class or platform component: the
cluster it hands over has its API and registered nodes, which are not Ready
until the platform installs Cilium.

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

# 1. Change memoryMiB or cores: the default in providers/talos/config.go,
#    or the pool in the -config file the cluster was made with.
# 2. See what changes, then change it. Pass the -config and -workers that
#    create was given, if any.
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
  `-shrink` is given. Without `-config` it takes the built-in sizes, so a
  cluster made with a `-config` must be resized with the same file, or a
  plain `resize` would shrink it; the refusal names each VM, current and
  new size;
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
Before it changes anything it checks the token's privileges and refuses
unless:

- every node is `Ready`, except a control plane: `treasury-cp-1` is kept off
  the pod network (Q33) and reads `NotReady` for good. The check runs again
  before each node;
- every target is a running VM of the cluster with a Kubernetes node of the
  same name, and the VM's address and the node's `InternalIP` agree, which
  also catches a `KUBECONFIG` of another cluster;
- every target worker has a Ready pod of each `-require-daemonsets`
  (default `kube-system/cilium,istio-system/ztunnel`).

The control plane is restarted only when `-nodes` names it. With one control
plane the Kubernetes API is down while it restarts; `restart` waits through
that for its new boot ID, not for `Ready`.

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

Without `-config` the program uses the defaults below. A JSON file overrides
only the fields it names, except that `pools` replaces the default pools as a
whole; unknown fields are an error. `-cluster`, `-first-address` and
`-workers` (the first pool's count, on `create` and `resize`) override the file.

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

- `cluster` has no default: every command names the cluster it acts on.
- `nodes` is the Proxmox nodes to spread VMs across, round robin, starting
  with the control plane. Empty means every online node, sorted by name;
  naming them keeps placement stable when a host is down. `controlPlane` and
  each pool take their own `nodes` to pin a group.
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
and the control plane stays `NotReady` after that too: it is kept off the pod
network, as on GKE and EKS, and the API server reaches webhooks through the
ingress Gateway's LoadBalancer address on the LAN. Webhooks start permissive
and are switched to enforcing by a CUE flag once each answers through the
Gateway. ADR 0001 has the reasoning and the two provisioning steps.

### Patches

| File | Applies to | Sets |
| --- | --- | --- |
| [`patches/all.yaml`](patches/all.yaml) | every node | KubePrism on `127.0.0.1:7445`; sysctls for sandbox density and user namespaces |
| [`patches/controlplane.yaml`](patches/controlplane.yaml) | control plane | Flannel deleted, kube-proxy disabled, Talos's CoreDNS disabled; API server `runtime-config=certificates.k8s.io/v1beta1=true` and `enable-aggregator-routing=true`; node label `holos.run/pod-network: none` |
| [`clusters/<cluster>/controlplane.yaml`](clusters/treasury/controlplane.yaml) (rendered, committed) | the cluster's control plane | `StaticHostConfig`: every admission webhook hostname at the ingress Gateway's address |
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
  control plane (Webhook host entries, below);

- the cluster name and the endpoint `https://<control plane address>:6443`,
  with no VIP;
- the installer image `factory.talos.dev/nocloud-installer/<schematic>:v1.14.4`,
  where the schematic is read from the control plane node itself
  (`talosctl get extensions`), or taken from `INSTALLER` when set. It must
  be the schematic `talosvm create` printed, so the installed system keeps
  the extensions and the `nocloud` platform;
- Talos `v1.14` config and Kubernetes `1.37.1`, pinned in the script.

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
| `talosconfig` | Talos API client config, endpoint and node set to the control plane. |
| `kubeconfig` | Cluster admin kubeconfig. |

Back the directory up: without `secrets.yaml` and `talosconfig` the cluster
can no longer be administered.

### Bringing a cluster up

`talosctl` v1.14.4, `kubectl`, `jq` and Go are needed, and `gen` and
`apply` read the inventory with `talosvm list`, which needs the Proxmox
credentials and the snippets mount described in the [Proxmox provider
README](../proxmox/README.md#snippets); without
the mount it leaves addresses blank and the script refuses. Install `talosctl`
from the Talos release, checking its checksum:

```sh
cd "$(mktemp -d)"
gh release download v1.14.4 -R siderolabs/talos -p talosctl-linux-amd64 -p sha256sum.txt
grep ' talosctl-linux-amd64$' sha256sum.txt | sha256sum -c -
install -m 0755 talosctl-linux-amd64 ~/.local/bin/talosctl
```

Then, from the repository root, with the Proxmox credentials loaded for
`talosvm list`:

```sh
set -a; . ~/.config/holos/proxmox.env; set +a

go run ./providers/talos/cmd/talosvm create -cluster treasury

# create returns once Proxmox has started the VMs, before Talos is up. Wait
# until every node answers in maintenance mode (under a minute on the garage).
# Only for new VMs: a configured node never answers --insecure, so the loop
# would wait forever on a cluster that is already up.
for a in $(go run ./providers/talos/cmd/talosvm list -cluster treasury -json | jq -r '.[].address'); do
  until talosctl get machinestatus -n "$a" --insecure >/dev/null 2>&1; do sleep 5; done
done

providers/talos/cluster.sh up treasury

export TALOSCONFIG=~/.config/holos/talos/treasury/talosconfig
export KUBECONFIG=~/.config/holos/talos/treasury/kubeconfig
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

### Webhook host entries

The API server reaches every admission webhook at
`https://<service>.<namespace>.webhooks.<cluster>.<privateDomain>:9443`, on
the ingress Gateway's address (`holos/webhooks.cue`), or at a hostname the
webhook's entry sets instead, as approver-policy's
`cert-manager-approver-policy.cert-manager.svc`. The control plane
resolves those names from a `StaticHostConfig` document, the Talos 1.14 form
of `extraHostEntries`, so it does not depend on the router's
`*.bank.internal` record. Talos's host DNS, which the API server resolves
through, answers them itself.

The document is rendered from the platform's CUE (`holos/talos.cue`): every
hostname in the webhook registry, at `clusters.<cluster>.loadBalancer.gateway`.
Render it with every platform render and commit it:

```sh
cd holos
cue cmd talos   # writes providers/talos/clusters/<cluster>/controlplane.yaml
git status ../providers/talos/clusters
```

`gen` refuses a cluster without it. Only the control plane calls webhooks, so
the workers get no entries.

A webhook added to the registry, or a new gateway address, reaches a running
control plane only through `talosctl`, not Argo CD. `gen` and `apply` do it
like any other patch change, from scratch. Without the Proxmox credentials
`gen` needs, patch the control plane in place. Host entries apply without a
reboot; check that with a dry run first:

```sh
export TALOSCONFIG=~/.config/holos/talos/treasury/talosconfig
p=providers/talos/clusters/treasury/controlplane.yaml
del=$'apiVersion: v1alpha1\nkind: StaticHostConfig\nname: 10.20.0.30\n$patch: delete'
talosctl -n 10.20.0.50 patch mc -p "$del" -p @$p --dry-run   # "without a reboot", and the diff
talosctl -n 10.20.0.50 patch mc -p "$del" -p @$p --mode no-reboot
talosctl -n 10.20.0.50 get statichosts
```

The delete comes first because a patch appends to `hostnames` rather than
replacing it: applied twice, the same file would list every name twice.
Deleting the document by its `name`, the address, and adding it again makes
the patch idempotent; a second run reports `no changes detected`. If the
address changed, delete the old one. Then bring the saved config in step, so
that a later `apply` without `gen` does not take the entries away:

```sh
c=~/.config/holos/talos/treasury/nodes/treasury-cp-1.yaml
talosctl machineconfig patch $c -p "$del" -p @$p --output $c
```

The kube-apiserver Pod's own `/etc/hosts` is the kubelet's copy and does not
list the entries; Talos's host DNS on `169.254.116.108` answers them, with
the authoritative flag and a 10-second TTL, where a forwarded name has
neither.

`talosctl health` passes without a CNI: it skips the node-ready, kube-proxy
and CoreDNS checks. Talos's own CoreDNS is disabled by the control plane
patch, so the cluster has no DNS until the platform's `cilium`,
`cilium-resources` and `coredns` components are applied; see
[holos/README.md](../../holos/README.md).
