# Proxmox provider

The Proxmox provider is the infrastructure layer on the garage's Proxmox VE
9.2 hosts: the compute contract, `infra.Compute` in
[`providers/infra`](../infra/infra.go), made of Proxmox VMs. It owns
everything about Proxmox: the API client, the ownership tags, placement
across the nodes, VMIDs, the node network's facts and reserved ranges, each
VM's MAC, the cloud-init snippets and their `cicustom` attachment, the ISO
download, and the API token with its privilege list.

It knows nothing of Talos or Kubernetes. The Kubernetes layer,
[`providers/talos`](../talos/README.md), says what VMs it wants: their names,
sizes, addresses, the image they boot, their role and pool as labels, and
each VM's network config, which this provider writes into a snippet and
attaches without building it. The one thing it reads back from its own
snippets is the node address it gave the VM, since Proxmox keeps no other
record of it. The program that wires the two together, `talosvm`, lives
with the Kubernetes layer; its usage, the image, resizing, restarting and
the config file are in [its README](../talos/README.md#talosvm).

Block storage, the infrastructure layer's second contract, is the Ceph cluster
the hosts already run, which ceph-csi uses directly, and the bucket is RustFS
inside the cluster; this provider implements neither.

## What the VMs are

Every VM boots the ISO its spec names, the Talos `nocloud` ISO from Image
Factory ([The image](../talos/README.md#the-image)). The VM settings follow
the
[Talos Proxmox guide](https://docs.siderolabs.com/talos/v1.12/platform-specific-installations/virtualized-platforms/proxmox):

| Setting | Value | Why |
| --- | --- | --- |
| SCSI controller | VirtIO SCSI (`virtio-scsi-pci`) | VirtIO SCSI single, the Proxmox default, can hang Talos at bootstrap. |
| CPU | `host`, 1 socket | Passes the host's `vmx` flag through, so Kata gets `/dev/kvm`, and meets Talos's x86-64-v2 requirement. |
| Memory | fixed, ballooning off; 8 GiB for a control plane, 16 GiB for a worker | The guide disables ballooning; memory a balloon takes back is memory the kubelet has promised to pods. Because nothing reports the guest's use to Proxmox, it shows these VMs at 99% used; [Control plane memory](../talos/docs/control-plane-memory.md) explains why that is not a problem and how the control plane's size was chosen. Workers were 8 GiB, which left about 7.2 GiB to the kubelet; Quay alone uses 3.6 to 3.8 GiB, and its node reached 98% of its memory requests before Substrate and kagent. 16 GiB also leaves two workers room for a third's pods while it restarts. |
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

VMs are spread round robin over the online nodes, or the config's `nodes`, in
the order the Kubernetes layer asks for them, so one control plane and three
workers on three hosts put the control plane on the first host and the
workers one per host after it. A group of VMs can be pinned to nodes of its
own.

### How the provider knows its own VMs

Each VM carries Proxmox tags. They are named after `talosvm`, the program that
first made them, since the VMs that exist carry them:

| Tag | Meaning |
| --- | --- |
| `talosvm` | Created by this provider. |
| `talosvm-cluster-<name>` | The cluster the VM belongs to, the group the compute contract names. |
| `talosvm-<key>-<value>` | One of the VM's labels: `talosvm-role-controlplane` or `talosvm-role-worker`, and on workers `talosvm-pool-<name>`, which a Talos patch turns into a node label. Proxmox keeps a VM's tags sorted, so labels are looked up by key, never by position. |

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
starts it ([Resizing a pool](../talos/README.md#resizing-a-pool)). To change anything else
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
maintenance-mode Talos VMs already boot with. The provider writes the first
line; the rest is the network config the Kubernetes layer renders from the
address, MAC, gateway, MTU, nameserver and search domain the VM's NIC
reports:

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
exists, which is why the compute contract plans the VMs before it creates
them. The provider picks each new VM's MAC itself: the Proxmox OUI `BC:24:11`
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

The table is `Reservations` in [`network.go`](network.go); validation uses
it, and this table must match it. The Kubernetes layer checks its addresses
against it through the contract before it has credentials.

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
| 10.20.0.50 – .59 | Cluster slot 1 (the first cluster, `firstAddress` default .50, `FirstNodeAddress`) |
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

## What talosvm sends

`talosvm` ([Usage](../talos/README.md#usage)) is how this provider runs. These
are the Proxmox side of its commands.

`create -dry-run`, `resize -dry-run` and `destroy` without `-yes` print the exact Proxmox API
calls, method, path and every parameter, and send none of them, so the first
real run can be checked by eye. Everything before that still happens: they
read Proxmox, and `create` posts the schematic to Image Factory, which only
returns its ID. A real run prints the same calls, then sends them in order and
waits for each task.

`create` first checks the config and posts the schematic to Image Factory,
which names the ISO and changes nothing on Proxmox. Then, before any call,
the provider checks the snippets directory, the token's privileges, that the
nodes are online, that no name is taken by a VM it does not own, that no
address or MAC is in use and that no existing VM's address would change, and
that `local-zfs` and `garage` (with ISO and snippets content) are on every
target node. It then downloads the ISO into `garage` through one node with Proxmox's own
`download-url`, unless a file of the same name is already there; the name
carries the Talos version and a schematic ID prefix, so an upgrade is a new
file. VMIDs start at `/cluster/nextid` and skip IDs in use.

`list` reports each VM's VMID, the Proxmox cluster as its region and the node
it runs on as its zone, its labels from its tags, and its address from its
snippet, which it leaves blank when the snippets mount is not there to read.

`destroy` stops each running VM hard and deletes it with its disks, with
`purge` so it also leaves backup jobs, replication and HA. It does not send
`destroy-unreferenced-disks`, which would scan every storage, including other
tenants', for disks carrying the same VMID.

`resize` reads each VM's cores and memory, now and pending, from
`GET /nodes/{node}/qemu/{vmid}/pending`, and for each VM to change sends
`PUT /nodes/{node}/qemu/{vmid}/config` with `memory`, `cores` or both,
whichever differ from what the VM will run with after its next start, and
nothing else: `balloon` stays `0`, and the disk is never resized. The VMs
have no CPU or memory hotplug, so Proxmox holds the change to a running VM as
pending until it is stopped and started.

`restart -mode power-cycle` shuts the VM down and starts it again through the
API: `status/shutdown` with `forceStop=1` and `timeout` the
`-shutdown-timeout`, then `status/start`. A power cycle that fails in the
shutdown can leave the VM still shutting down, and one that fails in the
start leaves it stopped; the error says to start it in Proxmox.

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
