# Proxmox provider

The Proxmox provider puts Talos VMs on the garage's Proxmox VE 9.2 hosts. The
garage is rebuilt more than once, so the VMs come from a program rather than
from hand-made VMs, and the program is small: `talosvm create`, `list`,
`resize`, `restart` and `destroy`, plus `check` for the API token.

`talosvm` stops at VMs booted into Talos maintenance mode with a working
static network. It does not apply Talos machine configuration; that is the
next step, `talosctl` with patches under [`talos/`](talos/README.md).

## What the VMs are

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

The VM settings follow the
[Talos Proxmox guide](https://docs.siderolabs.com/talos/v1.12/platform-specific-installations/virtualized-platforms/proxmox):

| Setting | Value | Why |
| --- | --- | --- |
| SCSI controller | VirtIO SCSI (`virtio-scsi-pci`) | VirtIO SCSI single, the Proxmox default, can hang Talos at bootstrap. |
| CPU | `host`, 1 socket | Passes the host's `vmx` flag through, so Kata gets `/dev/kvm`, and meets Talos's x86-64-v2 requirement. |
| Memory | fixed, ballooning off; 8 GiB for a control plane, 16 GiB for a worker | The guide disables ballooning; memory a balloon takes back is memory the kubelet has promised to pods. Because nothing reports the guest's use to Proxmox, it shows these VMs at 99% used; [Control plane memory](docs/control-plane-memory.md) explains why that is not a problem and how the control plane's size was chosen. Workers were 8 GiB, which left about 7.2 GiB to the kubelet; Quay alone uses 3.6 to 3.8 GiB, and its node reached 98% of its memory requests before Substrate and kagent. 16 GiB also leaves two workers room for a third's pods while it restarts. |
| Firmware | OVMF on q35, 4m EFI disk without pre-enrolled keys | The guide's recommendation. Enrolled keys would turn on Secure Boot, which the plain ISO is not signed for. |
| Disk | `scsi0` on `local-zfs`, `discard=on`, `ssd=1` | |
| CD-ROM | `ide0`, the Talos ISO from the shared `garage` storage | |
| Cloud-init | `ide2` on `local-zfs`, `citype=nocloud`, `cicustom=network=garage:snippets/talosvm_<cluster>_<vm>-net.yaml` | The drive where the garage's other VMs keep it; the network config is the VM's snippet. |
| Address | `10.20.0.X/32`, on-link default route via 10.20.0.1, nameserver `192.168.2.1`, search `lan`, all in the snippet | See [Node network](#node-network). |
| Network | `net0` VirtIO on the `k8s` vnet, a fixed MAC, `mtu=1` | The snippet matches the NIC by MAC. `mtu=1` makes the NIC take the bridge's MTU, 8950, and the snippet sets 8950 too. |
| Serial | `serial0` socket | A console that survives a hung display, as on the garage's Talos templates. |
| Boot order | `scsi0`, then `ide0` | The disk is empty until `talosctl` installs Talos, so the first boot falls through to the ISO and later boots come from the disk. |
| Guest agent | enabled | Only works because the extension is in the image. |
| Start | by a separate start call, and on host boot | Proxmox only warns when start-after-create fails, so `create` starts each VM with its own call, whose failure is an error. |

One control plane VM and three workers by default. Workers belong to a pool;
the default pool is `general`, and a dedicated microVM pool is one more entry
in the config. The control plane goes on the first node and the workers
follow round robin, so three workers land one per host.

### How talosvm knows its own VMs

Each VM carries Proxmox tags:

| Tag | Meaning |
| --- | --- |
| `talosvm` | Created by this program. |
| `talosvm-cluster-<name>` | The cluster the VM belongs to. |
| `talosvm-role-controlplane` or `talosvm-role-worker` | Its role. |
| `talosvm-pool-<name>` | Workers only: the pool, which a later patch turns into a node label. |

VM names are `<cluster>-cp-<n>` and `<cluster>-<pool>-<n>`, but a name is
never ownership. `list` and `destroy` consider only VMs with both the
`talosvm` tag and this cluster's tag, so the other tenants of the garage
(VMs 100 to 103 and 200, the templates 9101 to 9302), and every other cluster
made by `talosvm`, are never touched. `create` leaves a VM that already exists
under its name with those tags as it is, except to start it if it is stopped,
and refuses to run at all, before changing anything, if any of its names is
taken by some other VM. It never moves or readdresses an existing VM:
if the config now gives an existing VM another address, for example because a
rerun forgot the cluster's `-first-address`, `create` refuses with
"VM X has address P, config says Q". Nor does it resize one. When a VM runs
with another size than the config's it points at `resize`, or, when the
config's size is already pending on a running VM, at the power-cycle
`restart` that applies it; a stopped VM takes a pending size when `create`
starts it ([Resizing a pool](#resizing-a-pool)). To change anything else
about a VM, destroy and create the cluster again.
Lowering a pool's count does not remove the extra VMs either; `destroy`
removes the whole cluster.

## Node network

VMs do not go on `vmbr0`. They attach to the SDN EVPN vnet `k8s` (zone
`cloud`): subnet 10.20.0.0/24, an anycast gateway 10.20.0.1 on every node, MTU
8950, routed to the LAN through the exit nodes without NAT, and no DHCP.

Every node address is a /32, and all of a node's traffic goes to the anycast
gateway on its own hypervisor. Proxmox's `ipconfig0` cannot say that: it
writes nocloud network-config version 1, whose gateway Talos turns into a
plain default route, which the kernel refuses for a gateway outside a /32. So
each VM gets a network-config version 2 snippet, the shape the garage's
maintenance-mode Talos VMs already boot with:

```yaml
# Written by talosvm for cluster treasury, VM treasury-cp-1.
version: 2
ethernets:
  net0:
    match:
      macaddress: "BC:24:11:xx:xx:xx"
    addresses:
      - 10.20.0.50/32
    mtu: 8950
    routes:
      - to: 0.0.0.0/0
        via: 10.20.0.1
        on-link: true
    nameservers:
      addresses: [192.168.2.1]
      search: [lan]
```

Talos v1.14.4's nocloud platform turns `on-link: true` on a version 2 route
into a link-scope route to the gateway before the default route, which is
what makes the /32 work. It applies the nameservers and ignores `search`.

The snippet matches the NIC by MAC, so the MAC must be known before the VM
exists. `talosvm` picks each new VM's MAC itself: the Proxmox OUI `BC:24:11`
and three bytes of a hash of the cluster and VM name. Three bytes can
collide, so if another guest, or another VM of the same run, already has
that MAC, it hashes again with an attempt number (`talosvm/<cluster>/<vm>/1`,
`/2`, ...) and takes the first free one. It writes the snippet, creates the
VM with that MAC in `net0`, and then starts it. An existing VM keeps the MAC
on its `net0`.

### Snippets

The Proxmox API cannot upload snippets (upload accepts only `iso`, `vztmpl`
and `import` on 9.2.21), so `talosvm` writes them as plain files into the
`garage` NFS export, mounted on the machine that runs it, and the Proxmox
nodes read them from their own mount of the same export. `-snippets-dir`
names the mount's `snippets` directory and defaults to
`/mnt/pve/garage/snippets`, the path Proxmox uses on the nodes.

Setting up the talosvm host (done on 2026-10-23 for 10.20.0.4):

1. On `coffee.lan`, export the dataset to the talosvm host as well as the
   LAN. `no_root_squash` keeps root on the Proxmox nodes able to manage the
   storage as before:

   ```sh
   zfs set sharenfs="no_root_squash,async,rw=192.168.2.0/23:10.20.0.4/32" data/pve/garage
   ```

2. Make `snippets/` writable by the unprivileged user that runs talosvm
   (uid 1001 on 10.20.0.4) without opening it to everyone: group 1001, mode
   2775. The setgid bit keeps new files in that group.

   ```sh
   chown root:1001 /data/pve/garage/snippets
   chmod 2775 /data/pve/garage/snippets
   ```

3. On the talosvm host, mount the export where Proxmox mounts it on the
   nodes:

   ```sh
   sudo mkdir -p /mnt/pve/garage
   echo 'coffee.lan:/data/pve/garage /mnt/pve/garage nfs4 vers=4.2,hard,_netdev,nofail 0 0' | sudo tee -a /etc/fstab
   sudo mount /mnt/pve/garage
   ```

`talosvm` runs as the unprivileged user, so its files belong to that user
and group 1001. It sets mode 0644 explicitly, whatever the umask, so the
Proxmox nodes can read every snippet when they build a VM's cloud-init drive.

`create` and `destroy` check that the directory exists and is writable before
any change; a dry run checks only that it exists, and writes nothing.

- Each VM's snippet is `talosvm_<cluster>_<vm>-net.yaml`. The underscores
  are separators that cluster, pool and VM names (DNS labels) cannot
  contain, so a file name belongs to exactly one cluster and VM.
- The first line of every snippet is
  `# Written by talosvm for cluster <cluster>, VM <vm>.` `talosvm` overwrites
  or removes a file only if it is a regular file whose first line is exactly
  that for the cluster and VM its name says. It checks once when planning and
  again just before the change, and refuses anything else.
- Snippets are written atomically (a temporary file in the same directory,
  then a rename) with mode 0644. A dry run prints every path and its full
  content.
- An existing VM's snippet is never rewritten. A rerun of `create` only
  writes it again if it is missing, after the same address check a new VM
  gets. If it is there, its address must match the config.
- `destroy` removes the snippet of each VM it deletes: the one file named
  after that VM. It never globs, so other files in the directory, such as
  `tenant-k8s1-api1-net.yaml`, and a file that merely has the cluster's
  prefix but belongs to no deleted VM, are left alone.
- Other tenants' snippets are read for the address check only if they are
  regular files (not symlinks, FIFOs or devices) of at most 1 MiB.

### Addresses

`talosvm` refuses a node address outside 10.20.0.0/24, the network,
broadcast or gateway address, or inside a reserved range:

| Name | Range | Purpose |
| --- | --- | --- |
| `manual` | 10.20.0.20 – 10.20.0.29 | Jeff's hand-made VMs for manual testing |
| `ingress` | 10.20.0.30 – 10.20.0.49 | Ingress Gateway LoadBalancer addresses, about six clusters with three or four gateways each |

The table is `Reservations` in `internal/talosvm/network.go`; validation uses
it, and this table must match it.

Before creating anything, `talosvm` reads every guest's config in the Proxmox
cluster: the `ipconfigN` (VM) and `netN` (container) settings, and, when a
guest's `cicustom` network snippet is in `garage`, that file from the mount.
It refuses an address or a MAC already in use. An address set only inside a
guest, or in a snippet on another storage, is invisible to that check, which
is one more reason to keep to the table below.

### Address allocation

| Addresses | Use |
| --- | --- |
| 10.20.0.0 | Network |
| 10.20.0.1 | Anycast gateway on every node |
| 10.20.0.2 – .19 | Other garage VMs; .4, .5 and .10 were in use on 2026-10-23 |
| 10.20.0.20 – .29 | **Reserved** (`manual`): Jeff's hand-made VMs for manual testing |
| 10.20.0.30 – .49 | **Reserved** (`ingress`): ingress Gateway LoadBalancer addresses. Suggested: three per cluster slot, slot n at .30+3(n−1), with .48 and .49 spare for a fourth. |
| 10.20.0.50 – .59 | Cluster slot 1 (the first cluster, `firstAddress` default .50) |
| 10.20.0.60 – .69 | Cluster slot 2 |
| 10.20.0.70 – .79 | Cluster slot 3 |
| 10.20.0.80 – .89 | Cluster slot 4 |
| 10.20.0.90 – .99 | Unassigned; .99 was in use on 2026-10-23 |
| 10.20.0.100 – .109 | Cluster slot 5 |
| 10.20.0.110 – .119 | Cluster slot 6 |
| 10.20.0.120 – .254 | Unassigned |
| 10.20.0.255 | Broadcast |

Ten addresses per slot fit one control plane and up to nine workers, or three
control planes and seven workers. A cluster takes its slot with
`-first-address`, or `firstAddress` in its config.

## Before the first run

### Nested virtualization on each host

The microVM sandbox class runs Kata inside the Talos VMs, so each Proxmox host
kernel must allow nested virtualization; CPU type `host`, which `talosvm`
sets, is the VM half. The garage's three hosts already have it
(`kvm_intel nested=Y`). On a rebuilt host, check:

```sh
cat /sys/module/kvm_intel/parameters/nested   # Intel: want Y
cat /sys/module/kvm_amd/parameters/nested     # AMD: want 1
```

If not, on an Intel host:

```sh
echo 'options kvm_intel nested=Y' > /etc/modprobe.d/kvm-nested.conf
```

or on an AMD host:

```sh
echo 'options kvm_amd nested=1' > /etc/modprobe.d/kvm-nested.conf
```

then reboot the host, or with every VM on it stopped, reload the module
(`modprobe -r kvm_intel && modprobe kvm_intel`, or the `kvm_amd` pair).
`preflight.sh` below checks every node. Inside a running Talos worker,
`/dev/kvm` existing is the end-to-end check.

### API access: preflight.sh

`talosvm` authenticates as the token `holos@pve!distro`, whose user holds the
role `HolosProvisioner` on `/`. [`preflight/privileges.txt`](preflight/privileges.txt)
is the authoritative list of that role's privileges, one per line with the API
calls that need it. [`preflight/preflight.sh`](preflight/preflight.sh) sets the
cluster to exactly that list, and `talosvm` embeds the same file and checks
the token against it before `create`, `resize`, `restart` and `destroy` change
anything, so the role and the program cannot drift apart. **Whenever `talosvm` calls a new
Proxmox API endpoint, or sends a new parameter, add what it needs to
`privileges.txt` in the same change**, and run the script again.

Run the script as root on any one node. It needs `privileges.txt` next to it,
so copy the directory:

```sh
scp -r providers/proxmox/preflight root@r620a.lan:/root/holos-preflight
ssh root@r620a.lan sh /root/holos-preflight/preflight.sh --check   # report only; exit 1 on drift
ssh root@r620a.lan sh /root/holos-preflight/preflight.sh           # converge
```

It is idempotent, prints every change it makes, and converges on:

- the user `holos@pve`;
- the role `HolosProvisioner` holding exactly the listed privileges. An
  existing role is set with `pveum role modify` without `-append`, which
  removes privileges the list no longer has;
- `holos@pve` holding that role on `/` with propagation, and no other ACL
  entry for the user or its tokens. A group the user is in that holds ACLs is
  reported (and fails `--check`) but not changed, since that grant is someone
  else's; so is the role being granted to anyone else, whom setting the role
  narrows too. A disabled or expired user is reported as a problem;
- the token `holos@pve!distro` with privilege separation off, so it has the
  user's privileges. The secret is printed once, raw, the moment the token is
  created, before anything that could fail;
  an existing token's secret is never shown or rotated.

It also reports, without changing them, the prerequisites `talosvm` depends
on: nested virtualization on every node (reached over the cluster's root
ssh), the `k8s` vnet in zone `cloud`, `local-zfs` and the shared `garage`
storage active on every node, `garage` allowing ISO and snippets content,
the `cloud` zone's MTU being 8950 (the MTU every snippet sets), and a datacenter tag policy that lets a user
without `Sys.Modify` set `talosvm`'s tags (the default, `user-allow=free`).

The ACL is on `/` because the program reads every guest's config to find
addresses in use, and because one path keeps the check simple. `VM.Allocate`
on `/` lets the token delete any VM through the API; the ownership tags are
what keep `talosvm` from doing so.

The role `HolosProvisioner` was first made by hand. Compared with that role,
the list adds `VM.Config.Cloudinit` (Proxmox requires it for `cicustom` and
`citype`; the `cicustom` snippet volume also needs `Datastore.AllocateSpace`
on `garage`, already in the list) and `Sys.AccessNetwork` (the narrower privilege that allows
`download-url`), and drops `Sys.Modify`, `VM.Console`, `VM.GuestAgent.Audit`,
`VM.Config.CDROM`, `Datastore.Allocate` and `Pool.Audit`, which no call
`talosvm` makes needs. `Sys.Modify` was the broadest of them: with
`Sys.AccessNetwork` the ISO download no longer needs it.

### Credentials and the CA

The token lives in `~/.config/holos/proxmox.env`, outside the repository:

```sh
PROXMOX_URL=https://r620a.lan:8006
PROXMOX_TOKEN_ID=holos@pve!distro
PROXMOX_TOKEN_SECRET=...
```

The program reads exactly those three variables and never takes the secret
from a flag or the config file. Load them into the shell with:

```sh
set -a; . ~/.config/holos/proxmox.env; set +a
```

Proxmox signs its hosts' certificates with the cluster's own CA. Copy it once;
`talosvm` uses `~/.config/holos/pve-root-ca.pem` when it exists, or the file
named by `-ca-file`:

```sh
scp root@r620a.lan:/etc/pve/pve-root-ca.pem ~/.config/holos/pve-root-ca.pem
```

`-insecure` skips verification instead. It is never the default.

## Usage

```sh
set -a; . ~/.config/holos/proxmox.env; set +a

go run ./providers/proxmox/cmd/talosvm check
go run ./providers/proxmox/cmd/talosvm create  -cluster treasury -dry-run
go run ./providers/proxmox/cmd/talosvm create  -cluster treasury
go run ./providers/proxmox/cmd/talosvm list    -cluster treasury
go run ./providers/proxmox/cmd/talosvm resize  -cluster treasury -dry-run
go run ./providers/proxmox/cmd/talosvm restart -cluster treasury -dry-run
go run ./providers/proxmox/cmd/talosvm destroy -cluster treasury        # prints the calls only
go run ./providers/proxmox/cmd/talosvm destroy -cluster treasury -yes   # sends them
```

`create -dry-run`, `resize -dry-run` and `destroy` without `-yes` print the exact Proxmox API
calls, method, path and every parameter, and send none of them, so the first
real run can be checked by eye. Everything before that still happens: they
read Proxmox, and `create` posts the schematic to Image Factory, which only
returns its ID. A real run prints the same calls, then sends them in order and
waits for each task.

Before any call, `create` checks the config, the snippets directory, the token's
privileges, that the nodes are online, that `local-zfs` and `garage` (with
ISO and snippets content) are on every target node, that no name is taken by a
VM it does not own and that no address or MAC is in use. It
then downloads the ISO into `garage` through one node with Proxmox's own
`download-url`, unless a file of the same name is already there; the name
carries the Talos version and a schematic ID prefix, so an upgrade is a new
file. VMIDs start at `/cluster/nextid` and skip IDs in use.

`list` prints each VM's name, VMID, Proxmox cluster (region) and node (zone),
role, pool, address, status, cores and memory, and under `PENDING` a new
size `resize` gave a running VM that waits for its next start. The cluster and node become the worker's
`topology.kubernetes.io/region` and `zone` labels in the Talos patches, and
`list -json` prints the same rows for scripts.

`destroy` stops each running VM hard and deletes it with its disks, with
`purge` so it also leaves backup jobs, replication and HA. It does not send
`destroy-unreferenced-disks`, which would scan every storage, including other
tenants', for disks carrying the same VMID.

### Resizing a pool

`create` makes VMs at the config's sizes and never changes one that exists,
so a new size for a pool, or for the control plane, reaches a running
cluster in three steps: change the size, `resize`, and power-cycle the VMs
one at a time.

```sh
set -a; . ~/.config/holos/proxmox.env; set +a

# 1. Change memoryMiB or cores: the default in internal/talosvm/config.go,
#    or the pool in the -config file the cluster was made with.
# 2. See what changes, then change it. Pass the -config and -workers that
#    create was given, if any.
go run ./providers/proxmox/cmd/talosvm resize -cluster treasury -dry-run
go run ./providers/proxmox/cmd/talosvm resize -cluster treasury
# 3. Apply it, one node at a time: the command resize prints at the end.
go run ./providers/proxmox/cmd/talosvm restart -cluster treasury -mode power-cycle \
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

go run ./providers/proxmox/cmd/talosvm restart -cluster treasury -dry-run          # the steps of every node
go run ./providers/proxmox/cmd/talosvm restart -cluster treasury                   # talosctl reboot
go run ./providers/proxmox/cmd/talosvm restart -cluster treasury -mode power-cycle # Proxmox shutdown and start
go run ./providers/proxmox/cmd/talosvm restart -cluster treasury -nodes treasury-general-2
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

## Inventory

The garage as of 2026-10-23.

| Fact | Value | Used by |
| --- | --- | --- |
| Proxmox VE version | 9.2.21 | VM settings |
| Proxmox cluster | `garage` | `topology.kubernetes.io/region` |
| Hosts | 3: `r620a` 192.168.2.35, `r620b` .36, `r620c` .37, on `vmbr0` | `nodes`, `topology.kubernetes.io/zone` |
| CPU per host | 2× Intel Xeon E5-2670 @ 2.60GHz, 16 cores / 32 threads | Pool sizes |
| RAM per host | 251 GiB | Pool sizes |
| Nested virtualization | `kvm_intel nested=Y` on every host | microVM sandbox class |
| LAN | 192.168.2.0/23, gateway and resolver 192.168.2.1, search domain `lan` | Node `nameserver`, `searchDomain` |
| VM disk storage | `local-zfs` (zfspool `rpool/data`, ~1.5 TiB per host) | `diskStorage` |
| Other local storage | `ssd` (zfspool, ~460 GiB per host); `local` (dir; ISO, import) | |
| ISO and snippet storage | `garage`, NFS `coffee.lan:/data/pve/garage`, shared (~18 TiB; ISO, snippets, images, import), mounted at `/mnt/pve/garage` | `isoStorage`, `snippetStorage`, `-snippets-dir`; one download serves every host |
| Other NFS storages | `coffee`, `vmfs`, `edge`, `r620a`, `r620b`: other uses, not the platform's | |
| Node network | SDN EVPN vnet `k8s`, zone `cloud`, 10.20.0.0/24, /32 node addresses, anycast gateway 10.20.0.1, MTU 8950, routed to the LAN, no NAT, no DHCP | `bridge`, node addresses |
| Reserved addresses | 10.20.0.20 – .29 manual testing; 10.20.0.30 – .49 ingress | Address validation |
| Ingress gateway range | 10.20.0.30 – 10.20.0.49 | Ingress Gateway LoadBalancer addresses |
| Platform private domain | `bank.internal` | Every platform hostname, the Cilium resolver |
| DNS for the private domain | The LAN resolver 192.168.2.1 | Every platform hostname, the Cilium resolver |
| Other tenants | VMs 100 `tenant-admin-vm`, 101 `runner`, 102 `claude`, 103 `jeffsbox`; templates 9101, 9102, 9201, 9202, 9301, 9302 | Never touched |
| GitHub runner host | `runner.lan` | CI |

### DNS

The platform's private domain is `bank.internal`. Jeff manages the LAN
resolver, 192.168.2.1, by hand and points the wildcard `*.bank.internal` at
the cluster's ingress Gateway address, from the reserved range above. The
platform needs no DNS automation; a new cluster's ingress address is a record
to add there. With more than one cluster up at once, only one can hold the
wildcard; the others need names of their own under `bank.internal`, which is a
decision for the item that brings up the second cluster.
