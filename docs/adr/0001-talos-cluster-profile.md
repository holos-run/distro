# 0001. Talos cluster profile

Status: accepted, 2026-10-23; amended 2026-10-26 (webhooks reach the
ingress Gateway's address, not an HAProxy load balancer)

## Context

The distro's first site is a garage Proxmox VE cluster named `garage`. The
`talosvm` provider (`providers/proxmox`) creates the VMs and stops at Talos
maintenance mode: each VM has booted the Image Factory `nocloud` ISO with its
extensions, and has a static /32 address on the `k8s` vnet from its
cloud-init network snippet. Something has to turn those VMs into a
Kubernetes cluster, and the garage is rebuilt often enough that it must be
repeatable.

The first clusters are for research, development and rehearsal. They need to
come up in one pass, run the same machine configuration every time, and leave
networking to the platform layer above them, where Cilium replaces the
default CNI and kube-proxy.

## Decision

### Machine configuration is talosctl with committed patches

Machine configuration is plain `talosctl gen config` with the Talos strategic
merge patches committed in `providers/proxmox/talos/patches`, driven by a
small script, `providers/proxmox/talos/cluster.sh`. There is no program and
no state store: the patches are the whole policy, and anyone can read them
or run `talosctl` by hand with the same result.

The patches in `patches/` are cluster-agnostic. The per-cluster inputs are
the cluster name, the control plane address and the node inventory, which
come from `talosvm list -json`, and one patch rendered from the platform's
CUE for the cluster (the webhook host entries, below); the script turns the
inventory into one small patch per node.

### One profile: a single control plane

Every cluster has exactly one control plane node and at least one worker.
Bootstrap completes once the single etcd member is healthy; nothing waits
for members that will never join. The Kubernetes API endpoint is the control
plane's address, `https://<address>:6443`, with no virtual IP and no DNS
name, so it works before any resolver knows about the cluster.

Workloads never run on the control plane, which keeps the Talos default
`NoSchedule` taint. That is why a worker is required even in the smallest
cluster.

A high-availability profile, three control plane nodes behind a shared
endpoint, is a later decision. `talosvm` can already create three control
plane VMs; the script refuses anything but one until that decision is made.

### The control plane is not on the pod network

The control plane is built the way GKE and EKS build theirs: it is not a
member of the pod network. On both managed services the control plane is not
a node and runs no CNI agent. Here it is a node, since Talos runs the control
plane as static pods under a kubelet, so it carries the label
`holos.run/pod-network: none`, every CNI and pod network DaemonSet keeps off
nodes with that label, and the node stays `NotReady` by design.

The pod network is a VXLAN overlay, so the API server can reach neither Pod
IPs nor Service ClusterIPs. It reaches everything it calls the way a client
outside the cluster does: through the ingress Gateway's LoadBalancer address,
which a worker announces on the LAN the control plane is on, the role an NLB
plays in AWS:

- An admission webhook's `clientConfig` names a URL on a hostname that
  resolves to the Gateway's address. A Gateway listener in TLS passthrough
  mode routes the connection on its SNI, by a TLSRoute, to the webhook's
  Service, and the webhook's Pods terminate TLS with a serving certificate
  that carries the hostname. The control plane's machine config maps each
  hostname to the address, so the API server does not depend on the site's
  resolver.
- An aggregated API's APIService can only name a Service. The API server runs
  with `--enable-aggregator-routing`, so it dials the Service's endpoints
  rather than its ClusterIP, and the Service is selectorless with an
  EndpointSlice naming the Gateway's address and a passthrough port. The API
  server sends the SNI `<service>.<namespace>.svc` there, so that port needs
  a listener of its own: the webhook listener's hostnames are under the
  cluster's webhook domain. There is no aggregated API yet.

This replaces the first form of this decision (interview Q34), a URL on an
HAProxy layer 4 load balancer on the control plane passing TLS through to a
host-network Gateway. The Gateway's address is reserved for it in the
cluster's LoadBalancer block, so it is as stable as a load balancer's, and
the control plane reaches it directly: there is no listener on the control
plane, no host-network Gateway and no proxy between them. The Gateway is a
single point of failure for admission only as far as it is one for ingress.

### Provisioning is two steps: permissive, then enforcing

The Gateway is itself a component installed on the cluster, and it depends
on webhooks it would carry: its certificate comes from cert-manager, and
istiod, which deploys it, mounts trust-manager's copy of the private root. So
the webhooks cannot depend on the Gateway while the cluster is being built.
With every webhook enforcing from the start, cert-manager's webhook, reached
through a Gateway that does not exist yet, would refuse the private CA's
resources, and the build would never reach the Gateway. Provisioning
therefore runs in two steps:

1. **Bootstrap, permissive.** Every admission webhook is rendered in a
   permissive mode (`failurePolicy: Ignore`), so an API request goes through
   when the API server cannot reach the webhook. The cluster comes up, the
   platform is installed, and the Gateway comes online at its address
   (behind an NLB in AWS).
2. **Enforcing.** Once every webhook answers through the Gateway, checked
   with a request each must refuse, a single flag in the platform's CUE
   configuration is turned on and every webhook is rendered enforcing
   (`failurePolicy: Fail`). The change is synced like any other.

A cluster rebuilt from scratch goes through both steps again: its flag is
turned off before the rebuild and on after it.

The flag is per cluster and one value for every webhook, so no component
decides its own enforcement and a cluster is either still bootstrapping or
enforcing, never half of each.

A lab control plane that shares the pod network hides these constraints
until a component meets a managed control plane in production. Building
this way from the first cluster means every webhook and aggregated API in
the distro is designed for a managed control plane from its first commit.

### What the patches set

For every node (`patches/all.yaml`):

- **KubePrism** on, at `127.0.0.1:7445`. It is the Talos 1.14 default and is
  stated so Cilium's kube-proxy replacement can rely on it.
- **Sysctls** from upstream Substrate's GKE node pool settings, for
  sandbox density: `net.ipv4.neigh.default.gc_thresh1/2/3` = 4096, 16384,
  32768; `fs.inotify.max_user_instances` = 65536;
  `fs.inotify.max_user_watches` = 1048576.
- **User namespaces**: `user.max_user_namespaces` = 11255. Talos sets it to 0
  for hardening; gVisor and Kubernetes user namespaces need it.

For control plane nodes (`patches/controlplane.yaml`):

- **No CNI and no kube-proxy**: the `KubeFlannelCNIConfig` document is
  deleted and `KubeProxyConfig` is disabled. Nodes report `NotReady` until
  Cilium is installed; that is the expected hand-off, not a failure.
- **Off the pod network**: the `holos.run/pod-network: none` node label and
  `--enable-aggregator-routing`, as above.
- **Webhook host entries**: a `StaticHostConfig` mapping every webhook
  hostname to the Gateway's address. It is rendered from the platform's CUE
  (`holos/talos.cue`) into `providers/proxmox/talos/clusters/<cluster>/`,
  committed, so it is the one per-cluster patch, and it applies without a
  reboot.
- **No Talos CoreDNS**: `KubeCoreDNSConfig` is disabled. Talos can set only
  CoreDNS's image, and `talosctl upgrade-k8s` re-applies its own Corefile, so
  the platform deploys CoreDNS with its own Corefile (`holos/components/coredns`).
- **`certificates.k8s.io/v1beta1`** served alongside v1
  (`--runtime-config=certificates.k8s.io/v1beta1=true`). Kubernetes 1.37
  serves PodCertificateRequest and ClusterTrustBundle as v1 by default, but
  Substrate's pod certificate controller and kagent's chart still ask for
  v1beta1.

Per node, written by the script:

- `topology.kubernetes.io/region`: the Proxmox cluster name, and
  `topology.kubernetes.io/zone`: the Proxmox node the VM was created on. They
  were set for the Proxmox CSI plugin, which Ceph RBD replaced; nothing reads
  them now, and they stay as the standard topology labels.
- `holos.run/nodepool`: the worker's pool, from its `talosvm-pool-<name>` tag.
  "Node pool" is the word GKE and Karpenter use for the same thing.

The node pool label is self-asserted. On a worker, Talos applies labels with
the node's own kubelet credentials, so the NodeRestriction admission plugin
refuses any `node-restriction.kubernetes.io/` label there (tested: "is not
allowed to modify labels"), and a compromised worker could rewrite
`holos.run/nodepool` on itself. The label steers scheduling; it is not an
isolation boundary. A pool that separates workloads by isolation level, such
as a microVM sandbox pool, needs a taint to keep other workloads off and a
`node-restriction.kubernetes.io/` label applied with admin credentials, not
from the machine config, before anything relies on it for isolation.

The installer image is the Image Factory `nocloud-installer` for the same
schematic the VM booted, so the installed system keeps the extensions and
keeps reading its network from the cloud-init drive. The node network stays
where `talosvm` put it; the machine config has no network section.

### Pod Security Admission stays at the Talos default

Talos enforces the `baseline` level cluster-wide and exempts only
`kube-system`. That stays. Namespaces that need `privileged` (the CNI, the
mesh's node agents, storage node plugins, sandbox runtimes) are labeled by
the component that owns them, not exempted in the API server.

Talos's strategic merge patches append to lists, and Talos already lists
`kube-system` as an exemption. A patch that repeats it produces a duplicate,
which Talos accepts but kube-apiserver refuses to start with. Any future
PodSecurity patch must not repeat an exemption Talos already has.

### Secrets stay out of git

`talosctl gen secrets` output, the generated machine configs, `talosconfig`
and `kubeconfig` live in `~/.config/holos/talos/<cluster>/`, directories mode
0700 and files 0600, never in the repository. The secrets bundle is
generated once per cluster and reused, so regenerating configs keeps the
cluster's identity.

## Consequences

A cluster is `talosvm create`, then `cluster.sh up`, and both can be rerun.
Changing cluster policy is a reviewed change to a YAML patch. Losing
`~/.config/holos/talos/<cluster>/` loses the ability to administer that
cluster; it must be backed up, or the cluster recreated.

The control plane node never becomes `Ready`, so once a CNI is installed
`talosctl health` reports it as not ready; that is expected. Every component
that registers an admission webhook or an APIService must be reached through
the Gateway's address, render its `failurePolicy` from the cluster's
enforcement flag, and the CNI must honor the pod network label. Until the
flag is on, the cluster's webhooks fail open. Once it is on, the Gateway and
istiod, which programs it, are in the path of every request a webhook
matches.

The single control plane is a single point of failure, acceptable for the
garage and for rehearsals but not for production. Moving a VM to another
Proxmox node leaves its zone label stale until the configs are regenerated
and applied. Choosing high availability later means a shared endpoint, three
control plane VMs, and changes to the script; the patches themselves do not
change.
