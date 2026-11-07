# The Bank of the Salish Sea platform

Terms with a meaning of their own here, such as atespace or ate-client ksa
token, are in the [glossary](../docs/glossary.md).

This directory is the distro's platform, Bank of the Salish Sea: CUE that
renders every component's Kubernetes manifests into `deploy/`, using the
holos tool's v1alpha6 API as released in holos v0.106.0. Bank of the Salish
Sea is the brand, `Brand` in `brand.cue`, which every name the distribution
chooses for itself is built from; a vendor's distribution sets its own
there, and the names follow. It is its own CUE module
(`go.holos.run/distro/holos`) beside the Go module at the repository root.

```text
holos/
├── cue.mod/        CUE module; holos init platform v1alpha6's schemas
├── brand.cue       the distribution's brand, Bank of the Salish Sea, which its own names are built from
├── clusters.cue    per-site and per-cluster data
├── registry.cue    the components, in sync order
├── collections.cue the ProjectClaim collection, bound into the platform, which claims each cluster takes, and its group and user definitions
├── argocd.cue      the repository, branch, project and signing keys Argo CD syncs with
├── private-ca.cue  the names of the private CA and its trust bundle, and the shape of its requesters
├── istio.cue       the mesh's release, namespace, images and trust domain
├── substrate.cue   the Substrate fork's commit and image digests, and the names Substrate is reached by
├── kagent.cue      the kagent fork's pins, its namespace and controller identity, which Substrate trusts
├── signing-keys/   the public keys commits on main are signed with
├── projects/       the ProjectClaim collection: its schema, and a file per project
├── platform/       the Platform: the registry, rendered per cluster
├── components/     one directory per component, each producing a BuildPlan
├── vendor/         git submodules a component renders from: substrate, the Substrate fork
└── deploy/         rendered manifests, committed; never edited by hand
```

## Before you start

The commands in this README act on one cluster, named by five shell
variables. Set them first, in every shell the commands run in:

```sh
cluster=treasury
domain=$cluster.bank.internal
root_ca=$HOME/$cluster-root-ca.pem
ceph_pool=k8s-rbd
ceph_user=k8s
```

`cluster` is the cluster the commands act on. `domain` is its
`ingressDomain`, the zone every service is named in, `<service>.$domain`.
`root_ca` is the file its private root is exported to (The private CA,
below). `ceph_pool` and `ceph_user` are its `ceph.pool` and `ceph.user` in
`clusters.cue`. `ceph_user` is the bare name, as `clusters.cue` has it and
as the Secret's `userID` holds it: `cartography`, not `client.cartography`.
The commands add `client.` where Ceph wants the full name, and the Secret is
`ceph-client-$ceph_user`.

Another cluster changes `cluster=`, `ceph_pool=` and `ceph_user=`.
Cartography's are:

```sh
cluster=cartography
domain=$cluster.bank.internal
root_ca=$HOME/$cluster-root-ca.pem
ceph_pool=cartography-rbd
ceph_user=cartography
```

The Ceph names do not follow from `$cluster`, because treasury's do not:
`k8s-rbd` and `k8s` are a recorded exception to `<cluster>-rbd` and
`<cluster>`. A pool or user left over from another cluster would act on that
cluster's volumes or key, so check them against the render, from this
directory:

```sh
grep -E ' pool:|node-stage-secret-name:' deploy/clusters/$cluster/components/ceph-csi-rbd/storageclass-ceph-rbd.yaml
# ceph-client-$ceph_user, then $ceph_pool
```

`domain` and `root_ca` follow from `$cluster`, and so do the admin configs,
while the cluster keeps the default `ingressDomain`,
`<cluster>.<privateDomain>` (Clusters, below), and was built with
`providers/talos/cluster.sh` with `HOLOS_TALOS_DIR` unset, so its admin
kubeconfig and talosconfig are in `~/.config/holos/talos/<cluster>/`. Every block that runs admin commands
starts by exporting `KUBECONFIG`, and `TALOSCONFIG` where it runs
`talosctl`, from `$cluster`, so it never acts on whatever cluster the shell
last pointed at. The blocks that log in through Keycloak use the kubectl
context and user `$cluster-oidc` instead (Logging in with kubectl, below).

The commands that reach Ceph run on the Ceph host `r620a` (`ssh root@r620a`),
which is the same for every cluster on the site (Storage, below).

The same names stand for their values outside the shell too: a URL to open
in a browser, such as `https://argocd.$domain`, or a path in an instruction,
is your cluster's. Email addresses are identities on the site's zone, such
as `jeff@bank.internal`, on every cluster, and never take `$domain`.
Expected-output comments follow `$domain` and `$cluster` too. Prose that
describes the platform as it runs names `treasury`, the garage's first cluster,
and its hosts, such as `keycloak.treasury.bank.internal`, and recorded logs
and IP addresses, such as the gateway's 10.20.0.30, are treasury's.

## Clusters

`clusters.cue` holds everything that differs between clusters: the site the
cluster runs in (its private DNS zone and resolvers), the Kubernetes networks
Talos configured, the node uplink, the cluster's block of LoadBalancer
addresses, the optional components it takes, and any labels of its own.
Components read their cluster as `Cluster`; none names a cluster or an
address. Every cluster in `clusters` gets the registry's stack up to
`standard`, the optional components it names and the ProjectClaims that
select it (The stack, below), rendered to
`deploy/clusters/<cluster>/components/<component>/`, one file per resource.

`metadata.labels` is what a claim's `clusterSelector` selects on, under
Kubernetes' rules for a label's key and value. Every cluster gets two from
its data, as Kubernetes sets `kubernetes.io/metadata.name`, and `clusters.cue`
does not spell them out; treasury's are `holos.run/cluster-name: treasury` and
`holos.run/site: garage`. A cluster adds its own with
`metadata: labels: "example.com/tier": "lab"`.

The garage's ingress range is 10.20.0.30 to .49, five blocks of four
addresses. `treasury` has the first, 10.20.0.30 to .33, and `cartography` the
second, .34 to .37. A new cluster takes the next free block, and states its
control plane's address and its Ceph pool and user, which have no defaults:

```cue
clusters: example: {
	site: sites.garage
	loadBalancer: {start: "10.20.0.38", stop: "10.20.0.41"}
	serviceAccountIssuer: "https://10.20.0.70:6443"
	apiServer: address: "10.20.0.70"
	ceph: {pool: "example-rbd", user: "example"}
}
```

`serviceAccountIssuer` and `apiServer.address` are recorded, not chosen: both
are the control plane's address, its slot's first, which `talosvm.json` sets
as `firstAddress` and `providers/talos/cluster.sh` generates the cluster with.

Its names are `<service>.example.bank.internal`, under its own
`*.example.bank.internal` wildcard, and the router gets a line of its own
pointing that subdomain at its Gateway, `/example.bank.internal/10.20.0.38`
(`providers/proxmox/README.md`, "DNS"). The whole procedure is under Adding a
cluster, below.

The ingress Gateway's address, `loadBalancer.gateway`, the block's first
unless set, is reserved, so the private zone's wildcard record stays right
when the Gateway or the cluster is recreated. `cilium-resources` splits the
block into two `CiliumLoadBalancerIPPool`s that do not overlap:

- `<cluster>` (`treasury`) holds only the gateway's address and selects only
  the gateway's Service, by the `gateway.networking.k8s.io/gateway-name` label
  istiod sets on it and the `io.kubernetes.service.namespace` label LB IPAM
  adds to every Service. No other Service can be given the address, whatever
  order things start in, even one that asks for it; it stays Pending with
  `pool_selector_mismatch`.
- `<cluster>-general` (`treasury-general`) holds the rest of the block,
  10.20.0.31 to .33, for every namespace but the gateway's. The gateway's
  Service matches only the first pool, so it can be given nothing else.

The pool holding the gateway's address keeps the cluster's name, the name the
single pool had: narrowing a pool in place carries the gateway's allocation
over, where removing or renaming it releases the address first and the
Service would lose it, however briefly, until the new pool appeared.

`#Cluster.loadBalancer` requires the block to run forward and `gateway` to lie
in it, comparing the addresses as numbers, so a bad value fails `cue vet`.
`holos render platform` does not report it: it renders no components and
exits 0, which is why the render procedure runs `cue vet` first.

To change the gateway's address, set `loadBalancer.gateway` (or the block)
and render; the Gateway's `spec.addresses` and both pools follow. Then
change the cluster's router line, `/<cluster>.bank.internal/<address>`, to
match.

### The stack

The platform is a stack. Every entry in the registry (`registry.cue`) states
a `priority`, its level in the stack, in Debian's vocabulary: `required` at
the bottom, then `important`, then `standard`, and `optional` at the top.
The field has no default: a forgotten one that defaulted to `optional` would
render nowhere with every check passing. Left out, it fails `cue vet`, which
says only that some instances are incomplete; `cue vet -c` names the entry.

A cluster takes the stack up to `standard`, plus the optional components it
names in `components`. The cluster picks its components, as a Debian machine
picks its packages, and a component never names clusters. Treasury takes all
seven:

```cue
clusters: treasury: components: [
	"substrate",
	"substrate-shim",
	"kagent-crds",
	"kagent",
	"toolhive-crds",
	"toolhive-operator",
	"toolhive",
]
```

A cluster that sets no `components` takes none of them. Each name must be an
optional entry (`#OptionalComponents`), so a typo, a component further down
the stack, such as `quay`, or a claim, such as `project-payments`, fails
`cue vet`. As with `#Cluster.loadBalancer`, `holos render platform` does not
report it: it renders no components and exits 0.

A ProjectClaim's entry is `optional` too, but no cluster names it: a claim
runs the other way, and selects its clusters by label (Projects, below). A
claim's atespace and route land in `ate-system` and `substrate-shim`, so they
render only on a cluster that names both `substrate` and `substrate-shim`. On
any other cluster it selects, a claim renders the rest of what it stands for.

`clusterRegistry`, in `registry.cue`, is the result: the registry as each
cluster takes it, keyed by cluster, in the registry's order.
`platform/platform.cue` renders each cluster's list and `argocd-apps` makes
its `Application`s from it, so a cluster's sync waves are indexes into its
own list and an entry it does not take can never move them. It is a map in
the root files, not a filter on `Cluster`, because the platform instance does
not load `components/component.cue`, where `Cluster` is defined, and never
gets the `clusterName` tag: a filter on that would quietly read its default,
treasury, for every cluster. `clusterProjects`, in `collections.cue`, is the
claims each cluster takes, a map for the same reason. `Projects.reserved`
reads the whole registry, so a name is reserved whether or not a cluster
takes it.

Nothing may depend on a component above it in the stack, further up toward
`optional`: that is a layering violation
([glossary](../docs/glossary.md#the-platform)). Stack order is not sync
order. The registry's order is the sync order, whatever the priorities, so
`hello`, `standard`, syncs before `ceph-csi-rbd`, `important`.

Nothing at `standard` or beneath it renders for an optional entry the cluster
does not name, either. An object that serves one stays in its component, so the
`Application` that owns it does not change, and is conditional on the entry
through `Takes` (`components/component.cue`):

| Objects | Render on a cluster that names |
| --- | --- |
| `private-ca-ate-system`, RustFS's `substrate` consumer, Quay's `demo` `Organization` and `demo-echo` `Repository` | `substrate` |
| `private-ca-substrate-shim`, the ingress `Gateway`'s `ate` listener | `substrate-shim` |
| The `kagent` atespace's wildcard in `private-ca-substrate-shim` | `substrate-shim` and `kagent` |
| Argo CD's `MCPServer` health check | `toolhive` |
| A claim's atespace objects | `substrate` and `substrate-shim` |

A name stays reserved on every cluster, whether its objects render there or not
(`Projects.reserved`), so a claim cannot take `demo` on a cluster with no
`demo` `Organization`.

### Adding a cluster

This is the whole procedure for a new cluster, in order. It crosses this
README, [`providers/proxmox/README.md`](../providers/proxmox/README.md) and
[`providers/talos/README.md`](../providers/talos/README.md), which link here
rather than repeat it, and each step points at the section with its commands.
A rebuild of a cluster that exists is not this procedure from the top: start
at Rebuilding a cluster, below, which saves the cluster's state first and uses
these steps from step 8.
Steps 1 to 3 are a pull request, which merges before anything boots, since
Argo CD syncs a cluster's tree from `main`. The rest are by hand.

A step marked *Only with* an entry belongs to that optional entry. A cluster
that does not name the entry in `components` skips the step, and nothing on it
waits for what the step makes. `cartography` names no optional entry, so it
skips steps 11, 14 and 15: no `ate-setup` and no Anthropic key. The other
optional entries have no hand step.

1. **Take the addresses.** The next free cluster slot and ingress block, from
   [Address
   allocation](../providers/proxmox/README.md#address-allocation). The control
   plane takes the slot's first address.
2. **Add the cluster.** Its entry in `clusters.cue`, as in the example under
   Clusters, above, with the optional components it takes in `components`. Its
   config at `providers/talos/clusters/<cluster>/talosvm.json`
   ([Config](../providers/talos/README.md#config)), with `cluster`,
   `talosVersion` and `firstAddress`: `talosvm create` and `cluster.sh` refuse a
   cluster with no committed file. It needs at least three workers, since
   ceph-csi's three provisioner replicas take one worker each. *Only with
   `substrate`*, one pool is named `general`, which `WorkerPool` `gvisor`
   selects.
3. **Render and merge.** Render and run `contract-check` (Render, below). The
   cluster's tree appears under `deploy/clusters/<cluster>/`, and no other
   cluster's tree changes. Merge to `main`: the bootstrap applies from a
   checkout of it, and the cluster syncs from it.
4. **Set the variables.** All five under Before you start, above, in every
   shell from here on.
5. **Make the Ceph pool and user.** [Ceph pool and
   user](../providers/proxmox/README.md#ceph-pool-and-user), over root SSH to
   `r620a`. ceph-csi creates no pool and no user, and step 9 reads the user's
   key.
6. **Add the router line.** `/<cluster>.bank.internal/<gateway address>`
   ([DNS](../providers/proxmox/README.md#dns)). Pods reach Keycloak and Quay at
   `$domain` through it from their first sync, by CoreDNS's forward to the
   router, and so do the laptop and `quay-bootstrap`.
7. **Install the cluster's `talosctl`.** `cluster.sh` takes `talosctl-<version>`
   for the cluster's `talosVersion`, or a plain `talosctl` of that version, and
   refuses any other, printing the install steps, which are also under
   [Bringing a cluster up](../providers/talos/README.md#bringing-a-cluster-up).
   Clusters can pin different versions: `cartography` is on v1.14.5 and
   `treasury` on v1.14.4, so a machine that runs both keeps `talosctl-v1.14.5`
   beside `talosctl`. On such a cluster every `talosctl` run by hand below means
   that binary, and `talosvm restart` is passed `-talosctl talosctl-v1.14.5`.
8. **Make the VMs and the cluster.** `talosvm create`, the wait for maintenance
   mode and `cluster.sh up`, under [Bringing a cluster
   up](../providers/talos/README.md#bringing-a-cluster-up).
9. **Bootstrap Argo CD.** The hand applies, the Ceph key and the root, under
   Bootstrap Argo CD, below. On a rebuild, `state restore` runs in this step,
   after the Ceph key and before the root (Rebuilding a cluster, below). The
   steps after this one are the hand steps that section names, in the order
   the root reaches them.
10. **Trust the new root.** Once `private-ca-bundle` is `Healthy`, restart
    `argocd-server` (Bootstrap Argo CD, below) and export the cluster's root for
    the laptop (The private CA, below). It goes beside any other cluster's
    root, which stays. A rebuild that restored the root restarts `argocd-server`
    and checks the fingerprint instead of exporting anything: the laptop already
    trusts it (Rebuilding a cluster, below).
11. *Only with `substrate`.* **The key pools**, with `ate-setup`, within ten
    minutes of the namespaces syncing (Bringing Substrate up, under Substrate,
    below).
12. **Quay's credential.** Once Quay's pod is up,
    `quay-bootstrap token -quay-url https://quay.$domain` (Bringing Quay up,
    under Quay, below). That block's step 1 is only for a realm imported before
    `svc-quay-controller` was added, so a new cluster skips it. Every run passes
    `-quay-url`, whose default is treasury's.
13. **The workers' trust.** The `TrustedRootsConfig` patch and `talosvm restart`
    (Trusting the root on the workers, under Quay, below). A rebuild does this
    even when it restored the root, since the patch went with the old nodes.
14. *Only with `substrate`.* **The demo atespace and its actors** (Bringing
    Substrate up, under Substrate, below). Their image is copied into Quay, so
    this comes after step 12.
15. *Only with `kagent`.* **The Anthropic key** (Adding the Anthropic key, under
    kagent, below). A rebuild skips this only if `state restore` listed
    the key as created or left as is. If it skipped the key, this step stands:
    `kagent` stays `Degraded` until the key is in.
16. **Finish the root's sync.** If its retries ran out during these steps, sync
    it again (Bootstrap Argo CD, below). Every `Application` the cluster takes
    is then `Synced` and `Healthy`; on `cartography` the last before the root is
    `project-splunk`.
17. **Log in and check.** As `jeff`, with the password from Secret
    `keycloak/seabank-user-jeff`, generated per cluster (Logging in, below), and
    with `kubectl` as `$cluster-oidc` (Logging in with kubectl, under
    holos-authenticator, below). Then Check, below.

## Components

| Component | What it renders |
| --- | --- |
| `cilium` | Cilium 1.20.4 from its Helm chart, in `kube-system`: CNI, kube-proxy replacement, LB IPAM and L2 announcements |
| `cilium-resources` | The cluster's two `CiliumLoadBalancerIPPool`s, one reserving the gateway's address and one for the rest of the block, a `CiliumL2AnnouncementPolicy` on `eth0`, and the `allow-ambient-hostprobes` `CiliumClusterwideNetworkPolicy` |
| `coredns` | CoreDNS from the CoreDNS project's Helm chart, replacing the one Talos deploys, with the site's private zone forwarded to its resolvers |
| `argocd` | Argo CD v3.5.7 from argo-helm's `argo-cd` chart 10.11.7, in `argocd`, syncing this repository's `main` |
| `gateway-api` | The Gateway API v1.6.3 CRDs, standard channel, vendored from the release, ahead of Istio |
| `cert-manager` | cert-manager v1.21.3 from Jetstack's OCI chart, in `cert-manager`, with its CRDs and its webhook, and its own approver off |
| `approver-policy` | approver-policy v0.29.0 from Jetstack's OCI chart, in `cert-manager`, with its `CertificateRequestPolicy` CRD and its webhook |
| `private-ca` | The self-signed bootstrap `Issuer`, the root `Certificate`, the `private-ca` `ClusterIssuer`, and the `CertificateRequestPolicy`s and RBAC that approve every certificate request but a claim's wildcard, which renders its own |
| `trust-manager` | trust-manager v0.25.0 from Jetstack's OCI chart, in `cert-manager`, with its `Bundle` CRD and its webhook |
| `private-ca-bundle` | The `private-ca` `Bundle`: the root as ConfigMap `private-ca`, key `ca.crt`, in every namespace |
| `istio-base` | Istio 1.31.4's CRDs from its OCI `base` chart, the `istio-system` namespace (privileged) and the default revision's validating webhook |
| `istiod` | Istio's control plane in ambient mode, in `istio-system`, with its webhooks, the private root as its JWKS trust and the platform authenticator as an ext_authz provider |
| `istio-cni` | Istio's CNI node agent, chained after Cilium on every worker |
| `ztunnel` | Ambient's node proxy on every worker |
| `cloudnative-pg` | The CloudNativePG operator 1.30.1 from its `cloudnative-pg` chart 0.29.1, in `cnpg-system`, with its CRDs and its webhooks; no `Cluster` |
| `external-secrets` | The External Secrets operator v2.14.0 from its `external-secrets` chart 2.14.0, in `external-secrets`, with its CRDs and its webhook; no store, no `ExternalSecret` |
| `management-namespaces` | The Secrets Manager's management organization `seabank-org-platform` and project `seabank-prj-platform`, and the `RoleBinding` granting the server its `secrets` verbs in the project |
| `ingress-gateway` | The `ingress` `Gateway` in `istio-ingress` at the pinned address, its `*.treasury.bank.internal` certificate, the HTTP to HTTPS redirect, Argo CD's `HTTPRoute`, the `ate` passthrough listener for `*.ate.treasury.bank.internal` on a cluster that names `substrate-shim`, and the `k8s` passthrough listener for `k8s.treasury.bank.internal` |
| `hello` | An echo service in the ambient namespace `hello`, at `hello.treasury.bank.internal` |
| `ceph-csi-rbd` | ceph-csi 3.17.2's RBD driver from its `ceph-csi-rbd` chart, in `ceph-csi-rbd` (privileged), against the hosts' Ceph, and the default StorageClass `ceph-rbd` |
| `local-path` | local-path-provisioner v0.0.37 from its release manifest, in `local-path-storage` (privileged), and the `local-path` StorageClass, not the default |
| `rustfs` | RustFS 1.0.4 standalone from its `rustfs` chart 1.0.4, in the ambient namespace `rustfs`: one pod, one `ceph-rbd` volume, the S3 endpoint `rustfs-svc.rustfs.svc:9000`, generated keys, and a Job that registers the `quay` bucket and user, and `substrate`'s on a cluster that names it |
| `keycloak-operator` | The Keycloak Operator 26.8.2 from the release's manifests, vendored, in the ambient namespace `keycloak`, with its four CRDs; no `Keycloak` |
| `keycloak` | Keycloak 26.8.2 in `keycloak`, at `keycloak.treasury.bank.internal`: the `Keycloak` resource, its one-instance CloudNativePG cluster `keycloak-db` on `ceph-rbd`, and its generated admin and database credentials |
| `seabank-controller` | The platform controller, holos-controller 0.22.0 from aavis-ops' manifests, vendored, from `components/holos-controller`, in the ambient namespace `seabank-controller`, its objects renamed from the release's `holos-controller` names, with its eight CRDs and the private root in its trust; no resources of its kinds |
| `keycloak-realm` | The realm `default`: its `KeycloakRealmImport` and generated secrets, the users `jeff` and `svc-quay-controller`, the platform controller's credential, the `Instance`, the group `/platform/owners` and its membership, and the Job that writes the `Instance`'s `caBundle` |
| `seabank-authenticator` | The platform authenticator, holos-authenticator 0.21.0, from `components/holos-authenticator`, in the ambient namespace `seabank-authenticator`: its `Backend` CRD, vendored, the manager and its RBAC, the impersonator and its grants, the `Backend` for `k8s.treasury.bank.internal`, `/platform/owners` as `cluster-admin`, and the ClusterIP `Gateway` `k8s` behind `ingress`'s `k8s` listener, with the ext_authz policy, the Lua `TrafficExtension` and the TLS to the API server |
| `secrets-manager` | The Bank of the Salish Sea Secrets Manager, holos-run/secrets-manager v0.20.0, in the ambient namespace `secrets-manager`, at `secrets.treasury.bank.internal`, its Keycloak `Client` `secrets-manager`, and its RBAC |
| `toolhive-crds` | ToolHive 0.59.0's fourteen `toolhive.stacklok.dev` CRDs from its `toolhive-operator-crds` OCI chart, which Argo CD neither prunes nor deletes |
| `toolhive-operator` | The ToolHive operator 0.59.0 from its `toolhive-operator` OCI chart, images by digest, in `toolhive-system`, watching only the `toolhive` namespace, which it renders too (both restricted, not in the mesh) |
| `toolhive` | The MCP server `everything` in `toolhive`, at `toolhive.treasury.bank.internal/mcp`: its `MCPServer`, the `MCPOIDCConfig` that checks the realm's `kubectl` ID tokens, the `MCPAuthzConfig` with its Cedar policies, the `HTTPRoute` to the proxy runner and the NetworkPolicies that make the proxy the only way to the server (ToolHive, below) |
| `substrate` | Agent Substrate from the holos-run fork's install tree at the submodule's commit, images from `ghcr.io/holos-run/substrate` by digest, in `ate-system` (privileged, not in the mesh) and `podcertificate-controller-system`: the pod certificate controller, the API server, the IdP, the controller, the router, the egress gateway, the Kubernetes Secrets credential provider and atelet; its one-instance CloudNativePG cluster `substrate-db` and role Job, snapshots in RustFS's bucket `substrate`, the gVisor `WorkerPool` `gvisor` in `ate-workers`, and the `NetworkPolicy` that admits the claims' atespace Jobs to the API server |
| `substrate-shim` | The Substrate shim: the ClusterIP `Gateway` `ate` in `substrate-shim` behind `ingress`'s `ate` listener, a listener and `*.<atespace>.ate.treasury.bank.internal` certificate per atespace of the platform's (`demo`, `kagent`; a claim brings its own), the Keycloak token and group policy, the Lua `TrafficExtension` that sets `ate-target-actor` from the host, the `HTTPRoute`s in `ate-system` and the mutual TLS to the router |
| `kagent-crds` | kagent's eight `api.kagent.dev` CRDs from the holos-run fork's `kagent-crds` OCI chart, which Argo CD neither prunes nor deletes |
| `kagent` | kagent from the holos-run fork's `kagent` OCI chart, images by digest, in `kagent` (not in the mesh), at `kagent.treasury.bank.internal` behind oauth2-proxy and Keycloak: the controller, the UI, the read-only tool server and oauth2-proxy; its schema and roles in `substrate-db`, with their role Job and passwords in `ate-system`; its Keycloak `Client` `kagent`, the copy of the platform secret `anthropic-api-key`, a zero-replica placeholder `WorkerPool` `gvisor` naming the platform pool, and the NetworkPolicies that admit only the hop before each pod |
| `quay` | Quay 3.17.6 in the ambient namespace `quay`, at `quay.treasury.bank.internal`: one Deployment, its one-instance CloudNativePG cluster `quay-db`, an ephemeral Redis, blobs in RustFS's bucket `quay`, its Keycloak `Client` `quay`, the platform controller's Quay credential, and on a cluster that names `substrate`, the `Organization` `demo` and its public `Repository` `demo/echo` |
| `project-<name>` | One per ProjectClaim in `projects/` that selects the cluster, from `components/project` (Projects, below): the project's ambient namespace, its Keycloak groups, owners and membership, its Quay `Organization`, the owners' `RoleBinding`, its `AppProject` and `Application`, and on a cluster that names `substrate` and `substrate-shim`, its Substrate atespace with its route through the shim |
| `argocd-apps` | The `platform` `AppProject` and an Argo CD `Application` per component its cluster takes, its own being the root `Application` |

Helm charts are cached in `components/<name>/vendor/<version>/`, which is
committed, so a render needs no network and reads the same chart everywhere.
A component installed from release manifests rather than a chart vendors
them in the same place, unmodified, and renders them with `#FileArtifact`.

### Cilium

The values follow the Talos guide: Kubernetes IPAM from the node podCIDRs,
kube-proxy replacement reaching the API server through KubePrism on
`localhost:7445`, the agent and clean-state capability lists, and Talos's own
cgroup2 mount. The overlay is VXLAN, as ADR 0001 decided. For Istio ambient,
`cni.exclusive` is off, `socketLB.hostNamespaceOnly` is on and BPF
masquerading stays off.

Cilium 1.20's tested Kubernetes versions stop at 1.36; 1.37 is first tested
by 1.21, which is still a pre-release. 1.20.4, the latest stable release, runs
on 1.37 here; move to 1.21 once it is released.

The agent and Envoy DaemonSets tolerate every taint and run on every node,
the control plane included, as upstream Talos runs its CNI there: the
control plane turns `Ready`, and the API server, a host-network static pod,
reaches Services in the cluster (ADR 0003). The operator has a required node
affinity `node-role.kubernetes.io/control-plane DoesNotExist` and stays on the
workers. `policyCIDRMatchMode` is `nodes`, so a NetworkPolicy's `ipBlock` on
the control plane's address still matches once the address carries a node
identity (ToolHive, below). The socket load balancer serves host-namespace
processes, the API server's among them: the kube-proxy replacement turns it
on although the rendered `bpf-lb-sock` reads `false`, and `cilium-dbg status
--verbose` reports `Socket LB: Enabled`, coverage `Hostns-only`. Cilium
registers no admission webhook and no APIService.

Cilium is in `kube-system`, which Talos exempts from its baseline Pod
Security enforcement, so no namespace label is needed. The chart also creates
the `cilium-secrets` namespace, which holds only Secrets and RBAC.

Hubble's TLS certificates are made in the cluster by the chart's certgen Job
and CronJob (`hubble.tls.auto.method=cronJob`), not by `helm template`, which
would put a new private key in `deploy/` on every render.

### CoreDNS

Talos deploys CoreDNS itself, but its `KubeCoreDNSConfig` has only `enabled`
and `image`, and `talosctl upgrade-k8s` re-applies Talos's own Corefile and
prunes objects it no longer renders. The Corefile is platform policy, so the
platform owns CoreDNS: `providers/talos/patches/controlplane.yaml`
sets `KubeCoreDNSConfig` `enabled: false`, and this component deploys CoreDNS
as the same `kube-dns` Service at `10.96.0.10`, the address every kubelet was
given. The chart's CoreDNS is 1.14.7, the version Talos 1.14.4 deploys.

The Corefile has two server blocks: `.` resolves cluster names and forwards
the rest to the node's resolver (Talos host DNS, which forwards to the LAN
resolver), and `bank.internal.` forwards straight to 192.168.2.1, so the
private zone does not depend on how the nodes' resolvers are set.

### Admission webhooks

Every webhook configuration names its webhook's Service by the `service:`
reference its chart ships, with the chart's `failurePolicy` and
`timeoutSeconds`, as ADR 0003 requires. The API server reaches the Service
as a pod does: the control plane runs a Cilium agent (Cilium, above), so
the API server, a host-network static pod, reaches pods on the overlay, and
`--enable-aggregator-routing` makes it dial the Service's endpoints rather
than its ClusterIP (`providers/talos/patches/controlplane.yaml`). A webhook
needs nothing outside its own component: no route, no host entry on the
control plane and no extra name on its serving certificate. `contract-check`
holds every render to this (Render, below).

cert-manager's cainjector fills each configuration's `caBundle`. istiod
fills its own (see Istio below). CloudNativePG and External Secrets would
fill their own too, each with a CA of its own, and are told not to
(CloudNativePG and External Secrets, below).

Every webhook fails closed: while its pods are down, a request it matches is
refused, such as any write of a cert-manager resource, a `Bundle`, an Istio
resource or a CloudNativePG resource, and any write or delete of an
`ExternalSecret` or a store. Pods and other core objects are not matched
(the sidecar injector matches only Pods that ask for a sidecar), so a
webhook's own pods can always be restarted, and no component's objects are
matched by a webhook its own sync brings up.

A cluster bootstraps with its webhooks failing closed. The root
`Application` creates each component's `Application` in registry order and
waits for it to be `Synced` and `Healthy` (Bootstrap Argo CD, below), so a
webhook's pods are up before a later component writes an object it matches:
cert-manager's and approver-policy's before `private-ca`'s issuers and
policies, trust-manager's before `private-ca-bundle`, istiod's before
anything of Istio's, CloudNativePG's and External Secrets' before their
first consumers. `istio-base`'s validator fails closed from its first sync,
before istiod exists, and `istiod`, `istio-cni` and `ztunnel`, which come
next, write no Istio resource. A call made before cainjector or istiod has
written the `caBundle` fails, and Argo CD retries the sync it refused.

`private-ca`'s root `Certificate` syncs in a wave after the policies that
approve it, so its request never meets `deny-all` alone: approver-policy
v0.29.0 denies a request reviewed before a policy that would approve it is
in its cache, for good, and cert-manager would then back off for an hour.
A policy that exists but has no `Ready` condition yet leaves the request
unprocessed instead, until it does. The `private-ca` `ClusterIssuer` syncs
in the wave after the root's: it is not `Ready` until the root's Secret
exists, and Argo CD holds a wave back while an earlier one is `Degraded`.
`treasury`'s rebuild of 2026-11-02 was the first bootstrap with
approver-policy alone, and the root was approved on its first request
(Approval, under The private CA, below).

Check that every webhook answers with a request each must refuse, as
server-side dry runs; each error names the webhook that refused it:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl apply --dry-run=server -f - <<'YAML'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: bad, namespace: default}
spec:
  secretName: bad
  issuerRef: {group: cert-manager.io, kind: ClusterIssuer, name: private-ca}
YAML
# admission webhook "webhook.cert-manager.io" denied the request: ... at least one of commonName ... must be set
kubectl apply --dry-run=server -f - <<'YAML'
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata: {name: bad}
spec:
  sources: [{useDefaultCAs: true}]
  target:
    configMap: {key: ca.crt}
    namespaceSelector: {matchExpressions: [{key: a, operator: Bogus}]}
YAML
# admission webhook "trust.cert-manager.io" denied the request: ... not a valid selector operator
kubectl apply --dry-run=server -f - <<'YAML'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: bad, namespace: default}
spec: {action: CUSTOM, rules: [{}]}
YAML
# admission webhook "validation.istio.io" denied the request: ... `provider.name` must not be empty
kubectl create --dry-run=server -v=8 -f - <<'YAML' 2>&1 | grep -o 'admission webhook [^:]*: [^:]*'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: bad, namespace: default}
spec:
  instances: 1
  storage: {size: 1Gi}
  postgresql: {parameters: {listen_addresses: "*"}}
YAML
# admission webhook \"vcluster.cnpg.io\" denied the request: Cluster.postgresql.cnpg.io \"bad\" is invalid
kubectl create --dry-run=server -f - <<'YAML'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: bad, namespace: default}
spec:
  target: {creationPolicy: Merge, deletionPolicy: Delete}
  dataFrom: [{sourceRef: {generatorRef: {kind: Password, name: bad}}}]
YAML
# admission webhook "validate.externalsecret.external-secrets.io" denied the request: deletionPolicy=Delete must not be used ...
kubectl create --dry-run=server -f - <<'YAML'
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata: {name: bad}
spec:
  provider: {fake: {data: []}}
  conditions: [{namespaceRegexes: ["("]}]
YAML
# admission webhook "validate.clustersecretstore.external-secrets.io" denied the request: failed to compile 0th namespace regex ...
kubectl create --dry-run=server -f - <<'YAML'
apiVersion: policy.cert-manager.io/v1alpha1
kind: CertificateRequestPolicy
metadata: {name: bad}
spec:
  allowed: {dnsNames: {required: true}}
  selector: {}
YAML
# admission webhook "policy.cert-manager.io" denied the request: [spec.selector: Required value: one of issuerRef or namespace must be defined, ...]
```

A `Bundle` with two kinds of source is refused too, but by the CRD's own
validation, before any webhook is called, so it proves nothing about the
webhook. kubectl rewrites CloudNativePG's refusal, a `422 Invalid`, as `The
Cluster "bad" is invalid: ... Can't set fixed configuration parameter`,
without the webhook's name; `-v=8` shows the API server's message, which
names it.

### The private CA

The cluster's certificates come from a private CA (`private-ca.cue` has the
names). The self-signed `Issuer` `cert-manager/private-ca-bootstrap` signs the
root, `Certificate` `cert-manager/private-ca-root`, an ECDSA P-256 CA valid
for ten years whose key cert-manager generates in the cluster, so neither the
key nor the certificate is in git. The `ClusterIssuer` `private-ca` issues
from it. trust-manager writes the root to ConfigMap `private-ca`, key
`ca.crt`, in every namespace, including ones created later. The root's key
is only in Secret `cert-manager/private-ca-root`; cert-manager and
trust-manager, whose trust namespace is `cert-manager`, can both read it. Its
`rotationPolicy` is `Never`, so a reissue keeps the root's key, though not
its certificate (Renewing the root in place, below).

The root carries name constraints, marked critical. It may sign DNS names
only within three subtrees, `PrivateCA.permittedDNSDomains` in
`components/private-ca.cue`: the cluster's `ingressDomain`, `$domain`, and
the in-cluster Service names under `svc` and `svc.cluster.local`. Every IP
address, v4 and v6, is excluded. So a machine that trusts it, the laptop,
the claude VM or a pod, refuses a certificate it signed for another
cluster's host, such as `keycloak.other.bank.internal`, for a host outside
the garage, or for an IP address, even if the root's key leaked or a
request was approved that should not have been. The names the issuer signs
are each a Service's, `<service>.<namespace>.svc` or the same under
`svc.cluster.local`, or one in `$domain`; a short name such as
`substrate-db-rw` or `substrate-db-rw.ate-system` is in no subtree, so the
database's certificate carries only the two long ones, which every client
dials. The render checks
that every name in `PrivateCA.requesters` is within a subtree, and fails on
one that is not. approver-policy cannot check the constraints: it approves
the root's request whatever constraints it carries, so only the root's
`Certificate` in git sets them.

A new cluster has a new root. A rebuild keeps the old one when it saves and
restores it with `cmd/state` (Rebuilding a cluster, below), and then nothing
here is needed. Otherwise, export the root for the laptop, and for the kubectl
plugin, from any namespace's ConfigMap, and check it carries the name
constraints:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n default get configmap private-ca -o jsonpath='{.data.ca\.crt}' > "$root_ca"
openssl x509 -in "$root_ca" -noout -subject -dates -fingerprint -sha256
openssl x509 -in "$root_ca" -noout -text | grep -A7 'Name Constraints'
# macOS: trust it for TLS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain "$root_ca"
# Debian or Ubuntu
sudo cp "$root_ca" "/usr/local/share/ca-certificates/$cluster-root-ca.crt"
sudo update-ca-certificates
```

On treasury, the constraints read:

```text
        X509v3 Name Constraints: critical
            Permitted:
              DNS:treasury.bank.internal
              DNS:svc
              DNS:svc.cluster.local
            Excluded:
              IP:0.0.0.0/0.0.0.0
              IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0
```

Before replacing a trusted root, remove the old one: macOS's Keychain Access
lists it as `Bank of the Salish Sea $cluster root CA`, and from a shell:

```sh
security find-certificate -a -c "Bank of the Salish Sea $cluster root CA" -Z /Library/Keychains/System.keychain | grep SHA-1
sudo security delete-certificate -Z <sha1> /Library/Keychains/System.keychain   # for each old one
```

On Debian or Ubuntu the `cp` above overwrites the old file. curl takes the
root without installing it, `--cacert "$root_ca"`.

#### Renewing the root in place

A rebuild needs none of this: it restores the root, or it takes a new one by
the steps above. cert-manager does not reissue a certificate whose only
change is its name constraints, so a change to them reaches a running
cluster only when the root is renewed by hand. With `rotationPolicy` `Never`
the renew keeps the key and subject, so every certificate already issued
still verifies, but it makes a new root certificate. Never delete Secret
`private-ca-root` to force a reissue: that mints a new key, and every
existing certificate stops verifying.

Renew only once every `Certificate`'s names are within the new subtrees,
since a client that enforces them refuses one that is not. Renew the root
with cmctl, cert-manager's CLI (v2.6.2 is built against cert-manager
v1.21.3; the kubectl plugin form is `kubectl cert-manager renew`), wait for
the new revision and for trust-manager to copy it to the ConfigMap, check
what it carries, then renew every leaf the issuer signed, so each leaf
Secret's `ca.crt` is the new root too:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
cmctl() { go run github.com/cert-manager/cmctl/v2@v2.6.2 "$@"; }
fp() { kubectl -n default get configmap private-ca -o jsonpath='{.data.ca\.crt}' | openssl x509 -noout -fingerprint -sha256; }
old=$(fp)
rev=$(kubectl -n cert-manager get certificate private-ca-root -o jsonpath='{.status.revision}')
cmctl renew -n cert-manager private-ca-root
kubectl -n cert-manager wait certificate/private-ca-root \
  --for=jsonpath='{.status.revision}'=$((rev + 1)) --timeout=5m
until [ "$(fp)" != "$old" ]; do sleep 5; done
kubectl -n default get configmap private-ca -o jsonpath='{.data.ca\.crt}' \
  | openssl x509 -noout -text | grep -A7 'Name Constraints'
kubectl get certificates -A -o jsonpath='{range .items[?(@.spec.issuerRef.name=="private-ca")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
  | while read -r ns name; do cmctl renew -n "$ns" "$name"; done
```

The leaves are renewed by name, not with `renew --all -A`, which would
renew the root a second time and leave the export a revision behind. Each
leaf's `ca.crt` feeds CloudNativePG's `serverCASecret` for `substrate-db`,
the cnpg and External Secrets webhooks' `caBundle`s (cert-manager's
`inject-ca-from`) and Keycloak's `caBundle`. istiod reads the root once, at
start, so restart it (below), and give the workers the new root (Trusting
the root on the workers, below).

Off the cluster, every copy of the old root certificate stays trusted until
replaced, and with both trusted a client may build its path through the old
one, since both have the same subject and key, and enforce only its
constraints, or none. Replace each: export and trust `$root_ca` as above,
removing the old one first; re-run `kubectl config set-cluster
$cluster-oidc ... --embed-certs` (Logging in with kubectl, below); on the
claude VM, `/etc/docker/certs.d/quay.$domain/ca.crt` (Checking Quay, below);
`$DOCKER_CONFIG/root.pem` (Bringing Substrate up, below); and any `root.pem`
the curl checks use (Keycloak, below).

#### Approval

cert-manager signs nothing until a `CertificateRequest` is approved. A
`Certificate` makes a key and a `CertificateRequest` holding the CSR, in its
own namespace; cert-manager's mutating webhook stamps the request with who
created it, `spec.username` and `spec.groups`, which for a request made from
a `Certificate` is cert-manager's controller,
`system:serviceaccount:cert-manager:cert-manager`, whatever the namespace;
an approver sets `Approved` or `Denied`, either final; and the issuer signs
only an approved request. A denied request fails its `Certificate`, which
tries again with a new request after a back-off.

cert-manager's own approver approves every request for any issuer, so anyone
who may create a `Certificate` anywhere, such as a project owner with `admin`
in the project's namespace, could have `private-ca` sign
`keycloak.treasury.bank.internal`, or a CA, which laptops, pods,
the platform controller and the Talos nodes all trust. That approver is off
(`disableAutoApproval` in `components/cert-manager`), and approver-policy
(`components/approver-policy`) decides instead, by the
`CertificateRequestPolicy`s the `private-ca` component renders beside the
issuers they guard. A policy applies to a request when its `issuerRef`
selector matches the request's issuer, its namespace selector the request's
namespace, and the requester may `use` the policy, which approver-policy asks
the API server with a SubjectAccessReview for the request's user and groups
in its namespace. The request is approved if one policy that applies allows
everything it asks for, naming that policy, and denied otherwise, naming
every policy that applied and why each refused; with no policy that applies
it would be left unprocessed, with no condition, for good. A policy allows
only what its `allowed` lists: a request carrying a DNS name, usage, common
name or subject field the policy does not list is denied. No policy sets a
duration constraint, since one denies a request that names no duration, as
most of the platform's do not. `treasury` was rebuilt on 2026-11-02 with
approver-policy as the sole approver from its first sync: its root request,
`private-ca-root-1`, names cert-manager's ServiceAccount as its user and
was approved by policy `private-ca-root`.

| Policy | Issuer | Namespace | Allows | Bound to |
| --- | --- | --- | --- | --- |
| `private-ca-root` | `Issuer` `private-ca-bootstrap` | `cert-manager` | the root's common name and subject, a CA | cert-manager's controller |
| `trust-manager-webhook` | `Issuer` `trust-manager` | `cert-manager` | trust-manager's webhook's DNS name and common name | cert-manager's controller |
| `private-ca-<namespace>` | `ClusterIssuer` `private-ca` | that namespace | exactly the DNS names, usages and common name its `Certificate`s list, no CA | cert-manager's controller |
| `project-<name>` | `ClusterIssuer` `private-ca` | `substrate-shim` | exactly the claim's `*.<name>.ate.treasury.bank.internal`, no CA | cert-manager's controller |
| `deny-all` | any | any | nothing: it requires a DNS name from an empty list | `system:authenticated` |

The `private-ca-<namespace>` policies are `ate-system`, `cnpg-system`,
`external-secrets`, `seabank-authenticator`, `istio-ingress` and
`substrate-shim`, the first and last only on a cluster that names `substrate`
and `substrate-shim` respectively. A policy's `values` are patterns in which `*` matches any
string, so a namespace with a wildcard name, `istio-ingress`'s
`*.treasury.bank.internal` or `substrate-shim`'s atespace wildcards, also has
a CEL rule that each name be one of the listed ones exactly; without it
`*.treasury.bank.internal` would allow `keycloak.treasury.bank.internal`.

A ProjectClaim's wildcard is the one `Certificate` from `private-ca` with no
entry in `PrivateCA.requesters`. The claim renders the policy `project-<name>`
itself, with the `ClusterRole` and `ClusterRoleBinding`
`approver-policy:project-<name>` that let cert-manager's controller use it, at
sync wave -1, and Argo CD holds the wave until the policy is `Ready`. An entry
in `PrivateCA.requesters` would reach the cluster on `private-ca`'s own sync,
which nothing orders against the claim's, and a request denied first would
wait on cert-manager's back-off. `private-ca-substrate-shim` does not list the
claim's name, and need not: one policy that allows a request is enough.

So the namespace selector keeps out every namespace not listed, a project's
included: only `deny-all` applies there, and the request is denied. RBAC is
the second gate: the ClusterRole and ClusterRoleBinding
`approver-policy:platform` bind the platform policies only to cert-manager's
controller, so a `CertificateRequest` someone writes by hand, even in a
platform namespace and for a listed name, is bound only to `deny-all` and is
denied. A namespace's `admin` cannot grant itself `use` on a platform policy
with a `RoleBinding`, since RBAC refuses a binding to a permission its author
does not hold. `system:masters` is the exception: it passes every
SubjectAccessReview, so a request made by hand with the Talos admin
kubeconfig is approved wherever a policy's names and namespace allow it, as
such a user could approve it anyway.

`deny-all` applies to every issuer, not only `private-ca`, so an `Issuer` a
project makes in its own namespace, even a self-signed one, issues nothing:
its requests are denied like any other the platform's policies do not list.
A project gets certificates only once a policy names it, which is the
question in the tech-debt item on an issuer per project.

A component that adds a `Certificate` from `private-ca` adds one entry to
`PrivateCA.requesters` in `components/private-ca.cue`, under its namespace
and the `Certificate`'s name, with the DNS names and any usages or common
name. The `Certificate` takes those fields from the entry
(`spec: {PrivateCA.requesters[NS][Name], secretName: ...}`), so the names are
written once and the policy follows them. Without an entry its first request
is denied, by `deny-all`, the first time it syncs, not at a renewal months
later.

Check that each request is approved by its own policy:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl get certificaterequestpolicies   # every one READY True
kubectl get certificaterequests -A -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,USER:.spec.username,APPROVED:.status.conditions[?(@.type=="Approved")].message,DENIED:.status.conditions[?(@.type=="Denied")].message'
# ate-system  substrate-db-server-2  system:serviceaccount:cert-manager:cert-manager  Approved by CertificateRequestPolicy: "private-ca-ate-system"  <none>
```

A denied `Certificate` is `Ready=False`, and its `Issuing` condition and
events give the request's message; here one for
`keycloak.treasury.bank.internal` in a namespace outside the list:

```text
$ kubectl -n approver-test describe certificate keycloak
...
    Message:                 The certificate request has failed to complete and will be retried: No policy approved this request: [deny-all: spec.allowed.dnsNames.values: Invalid value: ["keycloak.treasury.bank.internal"]]
    Reason:                  policy.cert-manager.io
    Status:                  False
    Type:                    Issuing
```

The request, `kubectl describe certificaterequest keycloak-1`, has
`Denied=True` with the same message and reason `policy.cert-manager.io`, and
a `Denied` event from `policy.cert-manager.io`. The message lists, in
brackets, each policy that applied and the `allowed` fields it refused: here
`deny-all` alone, so no namespace policy applied and the namespace needs an
entry in `PrivateCA.requesters`. A platform namespace asking for a name
outside its list gets its own policy too, with the names it does allow:
`[private-ca-seabank-authenticator: spec.allowed.dnsNames.values: Invalid
value: ["keycloak.treasury.bank.internal"]: k8s.treasury.bank.internal]`. The
issuers' `WaitingForApproval` events on a request are normal. A request
pending with no condition and an `Unprocessed` event matched no policy, which
`deny-all` rules out for any request with a user.

istiod trusts the root when it fetches the JWKS for a RequestAuthentication
through `/cacerts/extra.pem`, which Istio's chart mounts from ConfigMap
`pilot-jwks-extra-cacerts`, not from the `cacerts` Secret. The `istiod`
component mounts this ConfigMap there instead:

```cue
// istiod chart values
volumes: [{name: "jwks-extra-cacerts", configMap: {name: PrivateCA.bundle, items: [{key: PrivateCA.bundleKey, path: "extra.pem"}]}}]
volumeMounts: [{name: "jwks-extra-cacerts", mountPath: "/cacerts", readOnly: true}]
```

The chart's own `jwksResolverExtraRootCA` value stays empty: setting it
mounts `pilot-jwks-extra-cacerts` at the same path. istiod reads the file
once, at start, so a new root needs an istiod restart.
No `cacerts` Secret is created: one holding any of `ca-cert.pem`,
`ca-key.pem`, `root-cert.pem`, `cert-chain.pem` or `tls.crt` switches istiod
to a plugged-in CA, or stops it starting if the set is incomplete.

### Argo CD

Argo CD syncs every component a cluster takes from its directory under
`holos/deploy/clusters/<cluster>/components/` on `main` of
https://github.com/holos-run/distro.git. The repository is public, so Argo CD
reads it anonymously: there is no deploy key and no repository Secret.
`argocd.cue` has the repository, the branch, the project and the signing
keys.

GitHub cannot reach the garage to deliver a webhook, so Argo CD polls:
`timeout.reconciliation` is 30 seconds with no jitter, and a merge to `main`
is synced in under a minute. `argocd app sync` syncs at once.

`argocd-apps` renders the `platform` `AppProject` and one `Application` per
entry its cluster takes, its list in `clusterRegistry` (The stack, above):

- `argocd-apps` is last; its own `Application` is the root, which syncs the
  directory the `Application`s are rendered to. A component added to the
  registry gets its `Application` from the merge alone, on each cluster that
  takes it. Each `Application`'s sync wave is the component's index in its
  cluster's own list, so an entry a cluster does not take never moves its
  waves, and `argocd-cm` has the health check for `Application`s that Argo CD
  dropped in 1.8. Argo CD's own health for an `Application` counts only the
  objects that exist, so one that has created only its namespace is `Healthy`;
  the check is `Healthy` only once the `Application` is also `Synced` to its
  spec's source. Until then, and while its sync runs or retries, it is
  `Progressing`, and a sync waits on a wave while anything in it is. It is
  `Degraded` once its sync has ended with the component `Degraded`, or has
  failed and left it `OutOfSync`, and a `Degraded` object fails the sync,
  which then retries from the first wave. A component that is done but never
  `Synced`, such as one with a diff that comes back after every sync, holds
  the root with no timeout. The waves order the root's own syncs: at bootstrap
  it creates one `Application`, waits for it to be `Synced` and `Healthy`,
  then creates the next, and every later sync of the root, such as a merge
  that adds a component, walks the same waves, so it creates the new
  `Application` only once every component ahead of it is `Synced` and
  `Healthy`. They do not order the components themselves: once created, each
  `Application` polls `main` and syncs on its own, so a later merge syncs the
  components it touches in parallel, and a component whose dependency is not
  ready yet relies on its retry. The `AppProject` is wave -1.
  `argocd-cm` also overrides Argo CD's health check for `ExternalSecret`,
  for generated secrets (External Secrets, below).
- Every `Application` syncs automatically, with `prune` and `selfHeal`: a
  change made by hand is reverted, and an object the render no longer has is
  deleted. Pruning considers only objects carrying the `Application`'s
  tracking annotation (`argocd.argoproj.io/tracking-id`), so taking over
  objects applied by hand deletes nothing. Label tracking would instead
  label every object `argocd.argoproj.io/instance`, a label an operator
  copying its owner's labels would spread to objects Argo CD would then
  count as its own. A failed sync is retried ten times, from 5 seconds
  doubling to 3 minutes, about 17 minutes in all.
- `ServerSideApply=true` everywhere: a client-side apply's last-applied
  annotation cannot hold the Gateway API's 429KB HTTPRoute CRD. Diffs are
  server-side too (`controller.diff.server.side`), so a field another
  manager owns, such as the `caBundle` cert-manager's cainjector writes into
  each webhook configuration, is not a difference. The one
  `ignoreDifferences`, a registry entry's (`registry.cue`), is
  `keycloak-realm`'s, for the `Instance`'s `caBundle`, which its `PostSync`
  Job writes under its own field manager: the server-side diff already
  leaves that field alone, and the entry says so where a reader looks.
- `cilium-resources` also has `SkipDryRunOnMissingResource=true`: its kinds
  exist once the Cilium operator has registered their CRDs, after `cilium`
  is synced.
- No `Application` has the resources finalizer, so deleting one, or the root
  pruning one whose component left the registry, leaves the component's
  objects in place. Delete them by hand once they are no longer wanted.

The `platform` `AppProject` lists two keys in `signatureKeys`, and Argo CD
syncs a commit only if it is signed by one of them:

- `7716CCA9F8F7BE25`, Jeff McCune's key, for commits pushed to `main`.
- `B5690EEEBB952194`, GitHub's web-flow key, which signs the merge commit
  when a pull request is merged in GitHub's UI.

Argo CD checks the commit at `main`'s head. Their public keys are in
`signing-keys/` and the `argocd` component puts them in Argo CD's keyring
(`argocd-gpg-keys-cm`). A head signed by any other key, or not signed, stops
every `Application` with a `ComparisonError`, and nothing syncs until a
commit signed by a listed key is on top. A key outside the keyring reports
`signed with key not in keyring (key_id=<long key ID>)`; one in the keyring
but not in `signatureKeys` reports `signed with unallowed key`.
To add a key, export it with `gpg --armor --export <long key ID>` into
`signing-keys/<long key ID>.asc` and add it to `ArgoCD.signingKeys`.

#### Developing with two signing keys

Sign every commit, and keep a second key that the platform does not trust.
GitHub shows both as Verified, because both are on the author's GitHub
account, but Argo CD syncs only the first. The second key makes the refusal
testable: a commit signed with it is a signed commit from a known author that
the platform must still refuse, which is a sharper test than an unsigned one,
and it leaves `commit.gpgsign` on for every other commit. It also keeps work
that must not reach the cluster, such as a commit to a branch that may later
be pushed to `main` by mistake, signed without it being deployable.

Jeff's test key is `8627879688494E44`, an ed25519 signing key with no
passphrase, on his GitHub account and deliberately not in `signing-keys/` or
`ArgoCD.signingKeys`. The trusted key stays the default
(`user.signingkey 7716CCA9F8F7BE25`), and a commit names the test key with
`-S`:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
# Make a passphrase-less signing key in gpg-agent's keyring; the private key
# never leaves it.
gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key \
  "Name (untrusted test key) <email>" ed25519 sign never
gpg --armor --export <long key ID>   # the public key, for GitHub's SSH and GPG keys

# Test the refusal, then recover with a commit signed by the trusted key.
git commit --allow-empty -S<test key ID> -m 'Test the refusal of an untrusted key'
git push origin main
kubectl -n argocd get applications   # every one reports a ComparisonError
git commit --allow-empty -S -m 'Recover from the untrusted key test'
git push origin main
```

Run the two pushes back to back, because the refusal stops GitOps for the
whole cluster until the second lands. This was run for the milestone's login
through Keycloak: all 25 `Application`s refused the test key's head within a
minute.

Nothing secret is rendered. On first start the server writes its session
signing key (`server.secretkey`), a self-signed TLS certificate and the
initial admin password into `argocd-secret` and
`argocd-initial-admin-secret`. Redis's password is made by the chart's
pre-install hook, a Job running `argocd admin redis-initial-password`, which
creates `argocd-redis` if it is missing; without it Redis does not start, and
rendering the password would put a new one into `deploy/` on every render.
This component therefore renders Helm hooks (`enableHooks`): Argo CD runs
them as `PreSync` hooks, and applied by hand the Job runs once and deletes
itself a minute after it finishes.

Login is through Keycloak, realm `default`, client `argocd`, or as the local
`admin`, which stays until the milestone's login through Keycloak has passed
(Logging in, below); Dex is off. Argo CD is at
https://argocd.treasury.bank.internal, `global.domain`, through the ingress
gateway, which terminates TLS with the private CA's wildcard and sends plain
HTTP to the server: `server.insecure` is set, so the server serves no TLS of
its own, on either of its Service's ports. The `HTTPRoute` is rendered by
`ingress-gateway`, not by this component, so this component still applies by
hand before the Gateway API CRDs exist. The `argocd` namespace is not in
ambient, so the hop from the gateway to the server is plain HTTP inside the
cluster; enrolling it would put ztunnel in the path Argo CD needs to repair
the platform. Argo CD runs Deployments and one StatefulSet, no DaemonSet, so
the control plane's `NoSchedule` taint keeps it on the workers. Its pods meet
the restricted Pod Security standard, so the `argocd` namespace needs no
label. The images are pinned by digest.

### Istio

Istio 1.31.4 in ambient mode (interview Q16), from the charts at
`oci://ghcr.io/istio/release/charts`, in four components applied in this
order: `istio-base` (the CRDs and the `istio-system` namespace), `istiod`,
`istio-cni` and `ztunnel`. `istio.cue` has the release, the images, pinned by
digest, and the trust domain, `cluster.local`. A workload's mesh identity is
`spiffe://cluster.local/ns/<namespace>/sa/<service account>`.

- `istio-system` is labeled `pod-security.kubernetes.io/enforce=privileged`:
  istio-cni and ztunnel run privileged pods on every node, which Talos's
  baseline enforcement refuses.
- istio-cni and ztunnel tolerate every taint, so both carry the affinity
  `node-role.kubernetes.io/control-plane DoesNotExist` and stay off the
  control plane, where istio-cni would rewrite the API server's host-network
  sockets. istiod is a Deployment and the control plane's taint keeps it off.
- istio-cni's default paths are Talos's (`/opt/cni/bin`, `/etc/cni/net.d`,
  `/var/run/netns`) and it chains after `05-cilium.conflist`; the Cilium
  values carry what Istio needs (see Cilium above) and
  `cilium-resources` admits the kubelet probes ambient SNATs to
  169.254.7.127.
- istiod runs one replica without the chart's `HorizontalPodAutoscaler`:
  there is no metrics server, and Argo CD reports an autoscaler that cannot
  read metrics as `Degraded`.
- `ENABLE_INGRESS_WAYPOINT_ROUTING` is set, Istio 1.31's default stated: a
  gateway sends a request for a Service labeled
  `istio.io/ingress-use-waypoint` through the Service's waypoint. It was
  turned on for the platform authenticator, which in the end runs on a Gateway of
  its own and needs no waypoint, so nothing relies on it yet.
- The mesh configuration lists one extension provider,
  `seabank-authenticator`: ext_authz over gRPC to
  `seabank-authenticator.seabank-authenticator.svc.cluster.local:9000`,
  two seconds, not failing open (holos-authenticator, below).
- A namespace joins the mesh with the label
  `istio.io/dataplane-mode=ambient` (`Istio.ambient`). Substrate's
  namespaces stay out: their port-scoped NetworkPolicies would have to admit
  the mesh port 15008, and with it every mesh identity.

istiod serves three configurations: the validator
`istio-validator-istio-system`, `istio-base`'s `istiod-default-validator`
and the sidecar injector (idle in ambient: it matches only pods or
namespaces that ask for a sidecar). Each keeps its chart's `service:`
reference to `istiod` (ADR 0003), and istiod's serving certificate carries
only the names istiod gives it. istiod manages these configurations itself,
which works with Argo CD:

- It writes its own CA's root into every webhook's `caBundle`. The render
  leaves `caBundle` out, and Argo CD diffs server-side, so the field istiod
  owns is no difference.
- It switches a validator's `failurePolicy` from `Ignore` to `Fail` once a
  dry-run create of a known-invalid Istio `Gateway` is refused by the
  webhook, and remembers that until it restarts, setting `Fail` again
  whenever the configuration changes. `helm template` cannot tell an install
  from an upgrade, so the charts render `Ignore`; left so, Argo CD's
  self-heal and istiod would take turns, `istio-base` and `istiod` would go
  `OutOfSync`, and every turn would bump the configurations'
  `resourceVersion`. Measured on the first garage cluster: about ten updates
  a configuration in the first 90 seconds with `Ignore` rendered; none in
  six minutes with `Fail` rendered.
- So both validators render `Fail` through the charts'
  `base.validationFailurePolicy`, which the charts offer for exactly this
  case, and the render agrees with istiod. The sidecar injector keeps the
  chart's `Fail`.

### The ingress gateway

One Gateway API `Gateway`, `istio-ingress/ingress` of class `istio`, for
every platform service (`IngressGateway` in `components/ingress.cue`). istiod
deploys it: a Deployment and a `LoadBalancer` Service both named
`ingress-istio`, which it owns; none is rendered.

- **Address.** `spec.addresses` requests 10.20.0.30, the cluster's
  `loadBalancer.gateway`, which the cluster's pool reserves for the gateway
  (see Clusters). istiod sets it as the Service's `loadBalancerIP`, LB IPAM
  allocates it from that pool, and one worker answers ARP for it. The private
  zone's `*.treasury.bank.internal` points there. The request is
  `spec.addresses`, not Cilium's `lbipam.cilium.io/ips` annotation
  (`io.cilium/lb-ipam-ips` is its older alias): it is the Gateway API's own
  field and the Gateway reports the address it was given beside it, and Cilium
  1.20 reads `loadBalancerIP` and the annotation alike, as one list of
  requested addresses. Kubernetes deprecated `loadBalancerIP`, but Cilium
  supports it until it is removed; if istiod or Cilium stops honoring it, the
  annotation can reach the Service through the Gateway's
  `spec.infrastructure.annotations`. The pool would hand the gateway the
  address without any request, since it is the only address its Service can
  take; the request makes a mismatch show as a Pending Service with a reason
  rather than a different address.
- **Hostnames.** Every service is `<service>.<ingressDomain>`, named in
  `IngressGateway.hosts`, one label under the cluster's `ingressDomain`
  (`clusters.cue`), which is `<cluster>.<privateDomain>` unless a cluster
  sets it (the Cluster_Qualified_Hostnames planning project): treasury's
  are `hello.treasury.bank.internal`, `argocd.treasury.bank.internal` and so
  on. Email addresses stay `<user>@<privateDomain>` on every cluster. The
  router answers NXDOMAIN for a name in no cluster's subdomain
  (`providers/proxmox/README.md`, "DNS"), so `Could not resolve host:
  <service>.bank.internal` from curl, or the like from docker or a browser,
  means a name from before the rename, in a kubeconfig, a Docker login or a
  bookmark.
- **Listeners.** `https` on 443 for `*.treasury.bank.internal`, terminating
  TLS with the `wildcard` `Certificate` from `ClusterIssuer` `private-ca`
  (Secret `istio-ingress/wildcard-tls`), open to routes from every namespace.
  `http` on 80 takes only the `https-redirect` route, which answers every
  request with a 301 to the same URL over HTTPS. A route attaches with
  `IngressGateway.parentRef`, which names the `https` listener.
- **Ate listener.** `ate` on 443 for `*.ate.<ingressDomain>`, protocol `TLS`
  in `Passthrough` mode, beside `https` on the same port: Envoy matches the
  SNI to the most specific name, so `echo.demo.ate.treasury.bank.internal`
  comes here and every other host under the zone to `https`. It accepts only
  `TLSRoute`s from `substrate-shim`, whose one route forwards the connection
  to the Substrate shim's own Gateway (The Substrate shim, below). `ingress`
  never terminates those connections, so none of the shim's policy runs on
  it.
- **K8s listener.** `k8s` on 443 for `k8s.<ingressDomain>`, protocol `TLS`
  in `Passthrough` mode, an exact name, so it wins over `https`'s wildcard.
  It accepts only `TLSRoute`s from `seabank-authenticator`, whose one
  route forwards the connection to the platform authenticator's own Gateway
  (holos-authenticator, below). The impersonator's token and the Lua that
  writes `Impersonate-Group` never run on `ingress`.
- **ServiceAccount.** The `gateway.istio.io/service-account` annotation names
  it `ingress-gateway`, so the gateway's mesh identity is
  `spiffe://cluster.local/ns/istio-ingress/sa/ingress-gateway`. Without the
  annotation it would be `ingress-istio`, a side effect of the class. The
  Substrate router does not admit it; only the shim's gateway reaches the
  router.
- **Deployment.** `infrastructure.parametersRef` names ConfigMap
  `istio-ingress/ingress-gateway`, whose `deployment` key istiod merges into
  the Deployment it generates: two replicas spread across nodes, so draining
  a worker does not drop the gateway.
- `istio-ingress` is not in ambient: the gateway is its own mesh proxy and
  reaches an ambient workload over HBONE through the workload's ztunnel.

### Storage

Ceph RBD is the default StorageClass and the answer for every volume.
`ceph-csi-rbd` runs ceph-csi's RBD driver against the Ceph cluster the
Proxmox hosts already run (Tentacle, three monitors on the hosts'
10.15.15.0/24 mesh, size-3 pools), so a volume is replicated across the
hosts, survives losing one, and follows its pod to any worker.
`clusters.cue` has the Ceph cluster as the site's (`ceph.fsid`,
`ceph.monitors`) and the pool and Ceph user as the cluster's (`ceph.pool`,
`ceph.user`). `cartography` uses pool `cartography-rbd` as
`client.cartography`, and `treasury` uses `k8s-rbd` as `client.k8s`, a recorded
exception to those names. A user's caps are `profile rbd`, limited to its own
pool on the OSDs and the manager. The driver creates no pool and no user, so
both are made by hand, once per cluster ([Ceph pool and
user](../providers/proxmox/README.md#ceph-pool-and-user)).

The `ceph-rbd` class is the cluster default: ext4, image features
`layering,exclusive-lock,object-map,fast-diff`, volume expansion on, reclaim
policy `Delete`, and `Immediate` binding, since an image attaches to any
node. Volumes are `ReadWriteOnce`. There is no CephFS, no snapshot controller
and no `VolumeSnapshotClass`; the provisioner's `csi-snapshotter` sidecar,
which the chart always renders, is patched out until CNPG backups need it.

- ceph-csi is 3.17.2, not the latest, 3.18.2: from 3.18.0 its image is built
  on Rocky Linux 10, whose glibc needs x86-64-v3, and the garage's Xeon
  E5-2670 hosts have no AVX2, so the plugin exits with `Fatal glibc error:
  CPU does not support x86-64-v3`. 3.17.2 is on CentOS Stream 9 with
  Tentacle's client libraries.
- The monitors are listed by their v1 addresses, port 6789, which the kernel
  RBD client maps with by default. RBD is built into the Talos kernel, so the
  node plugin loads no module; the chart's read-only `/lib/modules` mount is
  unused. kubelet's directory is Talos's `/var/lib/kubelet`, the chart's
  default.
- The node plugin runs privileged with host networking and kubelet's plugin
  paths, so the component labels `ceph-csi-rbd`
  `pod-security.kubernetes.io/enforce=privileged`. The node plugin's
  DaemonSet and the provisioner carry the affinity
  `node-role.kubernetes.io/control-plane DoesNotExist`, since storage has
  nothing to mount on the node that holds the cluster's secrets; the
  provisioner's three replicas take one worker each, by the chart's required
  pod anti-affinity.
- ceph-csi registers no admission webhook and no APIService.

The Ceph user's key is never in git, since the repository is public. Ceph
keeps it, outside the cluster, so `ceph auth get-key client.$ceph_user` reads
it again for a rebuilt cluster. It is a platform secret,
`ceph-client-$ceph_user` (`Cluster.ceph.secret`), with keys `userID`, the bare
name, and `userKey`, in the management
namespace, `seabank-prj-platform`, written there once per cluster at bootstrap
(Bootstrap Argo CD, below). It carries the label
`app.kubernetes.io/managed-by=holos.run` and the annotation
`holos.run/share-roles='[{"principal":"/platform/owners","role":"owner"}]'`,
so the Secrets Manager lists it under Platform/Platform and platform owners
can read it. No `Application` tracks it, so Argo CD neither prunes nor
reverts it, and the namespace carries `Prune=false,Delete=false`.

`ceph-csi-rbd` copies it into its namespace through its own store,
`SecretStore` `platform` (Per-namespace stores, under Secrets Manager), whose
Role may `get` that one Secret, and `ExternalSecret`
`ceph-client-$ceph_user`, with
`creationPolicy: Owner` and a `refreshInterval` of an hour. The copy is the
Secret the class's provisioner, controller-expand, controller-publish and
node-stage secret parameters name. Deleting and re-creating the
`ExternalSecret` copies the same key back. Without the management copy the
driver's pods run, but the `ExternalSecret` reports `SecretSyncedError`,
`Application` `ceph-csi-rbd` is `Degraded`, nothing later in the registry
syncs, and
every claim on `ceph-rbd` stays `Pending`.

Check that the copy is ESO's and matches Ceph, without the key reaching the
terminal:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n ceph-csi-rbd get secretstore,externalsecret   # Valid; SecretSynced
kubectl -n ceph-csi-rbd get secret ceph-client-$ceph_user -o jsonpath='{.metadata.labels.reconcile\.external-secrets\.io/managed} {.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'   # true ExternalSecret/ceph-client-$ceph_user
cmp -s <(kubectl -n ceph-csi-rbd get secret ceph-client-$ceph_user -o jsonpath='{.data.userKey}' | base64 -d) \
  <(ssh root@r620a ceph auth get-key client.$ceph_user) && echo same || echo differ
```

To rotate the key, give Ceph a new one, write it into the management copy,
and force a refresh rather than wait the hour. Rotating invalidates the old
key at once: provisioning and staging fail until the copy refreshes, and a
volume already mapped keeps the old key in the node's kernel client, which
fails the next time it authenticates, such as after a monitor or OSD
restart. So restart every pod with a `ceph-rbd` volume afterwards, which
stages its volume again with the new key:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
ssh root@r620a ceph auth rotate client.$ceph_user > /dev/null
key=$(ssh root@r620a ceph auth get-key client.$ceph_user) && [ -n "$key" ] &&
printf %s "$key" | jq -Rc '{data: {userKey: @base64}}' |
  kubectl -n seabank-prj-platform patch secret ceph-client-$ceph_user --type=merge --patch-file=/dev/stdin
unset key
kubectl -n ceph-csi-rbd annotate externalsecret ceph-client-$ceph_user force-sync=$(date +%s) --overwrite
```

A cluster that ran on a Secret made by hand in `ceph-csi-rbd`, as `treasury`
did, hands over in place. Write the management copy with the bootstrap
step's `key=$(ssh …)` pipeline alone, check that `seabank-prj-platform` holds
it, then merge; the `ExternalSecret` adopts the existing Secret. In
External Secrets 2.14.0 an `Owner` target that already exists is labelled
managed, its data replaced with the source's, and given the `ExternalSecret`
as its controller (`externalsecret_controller.go`, `applyOwnership`); it is
refused only when another `ExternalSecret` controls it. The key is the same,
so the driver sees no change. Check it as above.

local-path is installed beside it but not used without a compelling reason:
the garage models GKE and EKS, whose clusters provision network block
storage and ship no host-path provisioner. `local-path` vendors the v0.0.37
release manifest unmodified, and Kustomize patches put its volumes in
`/var/local-path-provisioner` (Talos's `/opt`, the release's default, is an
overlay), label `local-path-storage` privileged (its helper pods mount the
node's directory as a hostPath), and keep the provisioner off the control
plane. Its class is `WaitForFirstConsumer` and not the default: a volume is a
directory on one node, and its pod is pinned there.

### CloudNativePG

`cloudnative-pg` is the operator alone, 1.30.1 from the `cloudnative-pg`
chart 0.29.1, in `cnpg-system`, watching every namespace. It renders no
`Cluster`: each consumer writes its own, in its own namespace, and its
volume comes from the default class, `ceph-rbd`. The operator is a
Deployment with no tolerations, so the control plane's taint keeps it, and
every PostgreSQL pod it makes, on the workers. Its pods meet the restricted
Pod Security standard, so `cnpg-system` needs no label. The chart's
PodMonitor and Grafana dashboard are off, its defaults: there is no
Prometheus Operator.

Its webhooks follow the platform's model (Admission webhooks, above), but
not with the operator's own certificate. By default the operator makes a CA,
Secret `cnpg-ca-secret`, and a serving certificate, Secret
`cnpg-webhook-cert`, and every hour writes that CA into both
configurations' `caBundle`. `WEBHOOK_CERT_DIR`, set on the Deployment,
turns all of that off: the operator serves `apiserver.crt` and
`apiserver.key` from the directory and leaves the configurations alone. The
component mounts Secret `cnpg-system/cnpg-webhook-tls` there, from
`Certificate` `cnpg-webhook`, which `private-ca` issues for the Service's
`.svc` name. The configurations carry `cert-manager.io/inject-ca-from:
cnpg-system/cnpg-webhook`, so cainjector writes the private root into
their `caBundle`, and nothing else writes it. The root does not change when
the certificate is renewed, and the operator reloads the files when the
kubelet updates them. The operator reads the variable before its
ConfigMap, so it cannot go in `config.data`.

It needs only cert-manager and `private-ca` before it.

Check that a one-instance `Cluster` comes up on `ceph-rbd`, takes a
connection with its app credentials, and leaves no volume once deleted:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n cnpg-system get pods -o wide   # one operator, on a worker
kubectl -n cnpg-system get secrets        # cnpg-webhook-tls only
kubectl create ns cnpg-test
kubectl -n cnpg-test apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: pg}
spec:
  instances: 1
  storage: {size: 1Gi}
  bootstrap: {initdb: {database: app, owner: app}}
EOF
kubectl -n cnpg-test wait --for=condition=Ready --timeout=6m cluster/pg
img=ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie
kubectl -n cnpg-test run psql --image=$img --restart=Never --overrides='{"spec":{
  "securityContext":{"runAsNonRoot":true,"runAsUser":26,"seccompProfile":{"type":"RuntimeDefault"}},
  "containers":[{"name":"psql","image":"'$img'",
    "command":["sh","-c","psql \"$PGURI\" -Atc \"select current_user, current_database()\""],
    "env":[{"name":"PGURI","valueFrom":{"secretKeyRef":{"name":"pg-app","key":"uri"}}}],
    "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
kubectl -n cnpg-test wait --for=jsonpath='{.status.phase}'=Succeeded pod/psql
kubectl -n cnpg-test logs psql            # app|app
PV=$(kubectl -n cnpg-test get pvc pg-1 -o jsonpath='{.spec.volumeName}')
kubectl delete ns cnpg-test
kubectl wait --for=delete --timeout=2m pv/$PV
```

### External Secrets

`external-secrets` is the External Secrets operator, ESO, alone: v2.14.0
from the `external-secrets` chart 2.14.0, in `external-secrets`, watching
every namespace. It renders no `SecretStore` and no `ExternalSecret`: a
component generates its own secrets with `#GeneratedSecret`, below, and
copies a secret from another namespace through a per-namespace store,
`#ScopedSecretStore` (Secrets Manager, below). The
controller and the webhook are one replica each, Deployments with no
tolerations, so the control plane's taint keeps them on the workers. Their
pods meet the restricted Pod Security standard, so `external-secrets` needs
no label. The ServiceMonitor, the Grafana dashboard and the Bitwarden SDK
server are off, their defaults.

Its webhook validates `ExternalSecret`s, `SecretStore`s and
`ClusterSecretStore`s, on create, update and delete, and follows the
platform's model (Admission webhooks, above), but not with the chart's own
certificate. By default the chart deploys a cert-controller that makes a CA
and a serving certificate into Secret `external-secrets-webhook`, and
writes that CA into both configurations' `caBundle` and the CRDs'. The
component sets `certController.create: false` and
`webhook.certManager.enabled: true`, which drops the cert-controller and
that Secret from the output and puts `cert-manager.io/inject-ca-from:
external-secrets/external-secrets-webhook` on both configurations, so
cainjector writes the private root into their `caBundle` and nothing else
writes it. The chart's own `Certificate` is off too, and the component
renders `Certificate` `external-secrets-webhook`, which `private-ca` issues
for the Service's `.svc` name into the Secret the webhook mounts. The
webhook mints and rotates nothing: it serves the Secret's files,
reloads them when the kubelet updates them, and every five minutes checks
they chain to `ca.crt` and are valid for the `.svc` name at now plus
`--lookahead-interval`. Its default, 90 days, is longer than the
certificate's whole life, so the webhook would stop five minutes after it
started; the component sets one hour, the margin its readiness check
uses.

No CRD has a conversion webhook: since 2.0 each serves one version, and
the chart renders no `spec.conversion` (`crds.conversion.enabled` is
false, its default, which would only add an `inject-ca-from` annotation).
The chart puts `argocd.argoproj.io/sync-options: Prune=false,Delete=false`
on every CRD (`crds.annotations`): Argo CD ignores
`helm.sh/resource-policy: keep`, and deleting a CRD deletes every resource
of its kind, generated secrets' `ExternalSecret`s and generators with it.

It needs only cert-manager and `private-ca` before it.

#### Generated secrets

A secret the platform can mint for itself, such as a database or an admin
password, is generated in the cluster by an ESO generator, not made by hand
or by a Job (interview Q46). `#GeneratedSecret`
(`components/generated-secret.cue`) renders one from a name, a namespace
and, optionally, the generator's kind and spec:

```cue
resources: (#GeneratedSecret & {
	name:      "rustfs-root"
	namespace: "rustfs"
	// generator: spec: {length: 48, secretKeys: ["access-key", "secret-key"]}
	// generator: {kind: "UUID", spec: {}}
	// username: "keycloak"
}).resources
```

It renders a `Password` generator, by default 32 letters and digits under
the key `password`, and an `ExternalSecret` of the same name with
`refreshPolicy: CreatedOnce`, `target.creationPolicy: Orphan` and
`target.immutable: true`, which writes Secret `<name>` once. Both carry
`argocd.argoproj.io/sync-options: Prune=false,Delete=false`.

With `username` set, the Secret is a login for a consumer that reads a
`kubernetes.io/basic-auth` Secret, such as CloudNativePG's `initdb` or the
Keycloak Operator's bootstrap admin: the `ExternalSecret`'s
`target.template` gives it that type and the data `username`, as written,
and `password`, from the generator. The username is in git; the password is
not. It needs the default generator, a `Password` with the one key.

The rule (Q47): a generated secret survives a delete and re-create of its
`ExternalSecret` or its generator, by hand or by Argo CD, and is
regenerated only when the cluster is rebuilt, so nothing backs it up
outside the cluster. It lives in its consumer's namespace, which nothing
here protects: deleting the namespace deletes the Secret. Three layers hold
it (Q48):

- The Secret has no owner reference, so deleting the `ExternalSecret`
  leaves it, and it is immutable, so the API server refuses any change to
  its data. A re-created `ExternalSecret` finds it; ESO, seeing an
  immutable target, leaves its data alone and reports it synced. The new
  password the generator makes is discarded.
- Argo CD never prunes or deletes the `ExternalSecret` or the generator,
  so a rename or a deleted `Application` does not re-create them in the
  first place.
- Argo CD's health check for `ExternalSecret`, in the `argocd` component,
  is its built-in one except that the `Ready=False` ESO sets only because
  the target is immutable, reason `SecretImmutable` and message `could not
  update secret, target is immutable: unable to update secret <target>:
  secret is immutable`, is `Healthy`. ESO 2.14 sets it only for an
  `ExternalSecret` that would change an immutable Secret's data, such as
  one re-created without `target.immutable` onto an existing Secret. Every
  other `Ready=False` is `Degraded`, a missing generator's included.

To rotate a generated secret, first stop every pod that names it, on
every node, and wait until they are gone; then delete the Secret by hand,
then the `ExternalSecret`; then start the pods again.

- **Stop the pods first.** The kubelet does not watch an immutable Secret.
  It keeps the copy it fetched for as long as any pod on the node names
  the Secret, running or finished, and gives that copy to every new pod
  there. A pod started on such a node after the rotation gets the old
  value, while pods on other nodes get the new one. A rolling restart is
  not enough, and neither is a `Recreate` Deployment: its new pod can
  start before the kubelet has let go of the old one. Scale the
  workloads to 0, delete finished Job pods, and wait for the pods to be
  deleted.
- **Pause Argo CD first.** Self-heal puts a scaled-down workload back at
  once. Turn automation off on the root, `argocd-apps`, so it does not
  restore the next one, and then on the component's `Application`; a
  sync of `argocd-apps` turns both back on.
- **Delete the Secret, then the `ExternalSecret`.** Deleting the Secret
  alone writes nothing: with `Orphan` and `CreatedOnce`, an
  `ExternalSecret` that has synced never writes again. The
  `ExternalSecret` Argo CD re-creates (or `kubectl apply` does) has not
  synced, and writes a new Secret at once.

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
for a in argocd-apps <app>; do
  kubectl -n argocd patch application $a --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
done
kubectl -n <ns> scale deploy/<workload> --replicas=0
kubectl -n <ns> delete job --field-selector status.successful=1
kubectl -n <ns> wait --for=delete pod -l <workload's selector> --timeout=5m
kubectl get pods -A -o json | jq -r --arg s <name> '.items[] | select(
  ([.spec.containers[], .spec.initContainers[]? | (.env[]?.valueFrom.secretKeyRef.name,
    .envFrom[]?.secretRef.name)] + [.spec.volumes[]?.secret.secretName]) | index($s)) |
  "\(.metadata.namespace)/\(.metadata.name)"'   # nothing, in <ns>
kubectl -n <ns> delete secret <name>
kubectl -n <ns> delete externalsecret <name>
argocd app sync argocd-apps   # automation back on; <app> then syncs: a new ExternalSecret, and replicas back
```

Check the mechanism with a throwaway generated secret, rendered from the
definition:

```sh
cue export ./components --out text -e 'yaml.MarshalStream([for K, V in (#GeneratedSecret &
  {name: "eso-test", namespace: "eso-test"}).resources for R in V {R}])' > es.yaml
```

Then:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n external-secrets get pods -o wide     # controller and webhook, on workers
kubectl -n external-secrets get secrets          # external-secrets-webhook only
kubectl create ns eso-test
kubectl apply --server-side -f es.yaml
kubectl -n eso-test wait --for=condition=Ready externalsecret/eso-test
kubectl -n eso-test get secret eso-test -o jsonpath='{.immutable} {.metadata.ownerReferences}{"\n"}'   # true, no owner
kubectl -n eso-test get secret eso-test -o jsonpath='{.data.password}' | sha256sum
kubectl -n eso-test delete externalsecret eso-test
kubectl apply --server-side -f es.yaml           # Ready, SecretSynced; the same sha256sum
kubectl -n eso-test delete externalsecret,password --all
kubectl delete ns eso-test                       # the Secret, orphaned on purpose, goes with it
```

Check a health result with Argo CD's own Lua, from the server's Pod:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
P=$(kubectl -n argocd get pod -l app.kubernetes.io/name=argocd-server -o name)
kubectl -n eso-test get externalsecret eso-test -o yaml |
  kubectl -n argocd exec -i $P -- sh -c 'cat > /tmp/es.yaml'
kubectl -n argocd exec $P -- argocd admin settings resource-overrides health /tmp/es.yaml \
  --load-cluster-settings --namespace argocd                       # STATUS: Healthy
```

### RustFS

`rustfs` is the base's one S3 store: RustFS 1.0.4 from the `rustfs` chart
1.0.4 (https://charts.rustfs.com), in standalone mode, a Deployment of one
pod and one 50Gi claim on `ceph-rbd`, so the store follows its pod to any
worker. The image is pinned by tag. The S3 API is the ClusterIP Service
`rustfs-svc.rustfs.svc:9000`, path-style, region `us-east-1`; the console
listens on 9001 in the cluster only. No route reaches either from outside.
The claim carries `Prune=false,Delete=false`: `ceph-rbd` reclaims with
`Delete`, so pruning it would drop every bucket. Logs go to stdout, not to
a second volume, and RustFS's check for a newer release is off. RustFS
logs that its storage class has no parity, which is so for one drive: the
redundancy is Ceph's.

`rustfs` is in the mesh (`istio.io/dataplane-mode=ambient`), like `hello`:
a client in the mesh reaches it over HBONE, and one outside, such as
Substrate's `ate-system`, in plaintext through ztunnel.

Every key is generated in the cluster with `#GeneratedSecret` (Generated
secrets, above), each a `Password` generator with two `secretKeys`, 32
letters and digits each:

- `rustfs-root`, keys `RUSTFS_ACCESS_KEY` and `RUSTFS_SECRET_KEY`, the root
  user. The chart passes the Secret whole to RustFS (`secret.existingSecret`).
- `rustfs-substrate` and `rustfs-quay`, keys `access-key` and `secret-key`,
  one per consumer. The access key is the user's name in RustFS. `substrate`
  is a consumer only on a cluster that names it.

Job `rustfs-register` registers them with RustFS's own client, `rc`
(`rustfs/rc`), whose `admin` commands speak RustFS's IAM API. For each
consumer it creates the bucket, writes a policy of the same name, adds
the user with the Secret's keys (which resets the secret key of a user
that exists), attaches the policy, and removes any other user holding the
policy. The policy allows listing the bucket, its location and its
multipart uploads, and reading, writing and deleting its objects,
multipart included, and nothing else: a consumer cannot set the bucket's
policy, open it to anonymous access, or delete it. The Job mints nothing,
and every step converges. It is an Argo CD `PostSync` hook, so every sync
of `rustfs` creates it once RustFS is `Healthy`; on a rebuilt cluster,
whose keys are new, it makes users that match. Its delete policy is
`BeforeHookCreation,HookSucceeded`: it is deleted, with its pod, as soon
as it succeeds, so no finished pod keeps a node's copy of the Secrets
alive (below). A failed Job stays, for its logs, until the next sync. The consumers' copies, in their own namespaces, come
from the per-namespace stores, not from here.

To rotate a consumer's key, rotate its Secret as above; the example is
`rustfs-substrate`, which a cluster has if it names `substrate`, and
`rustfs-quay` works the same way. Only the Job's
pods name it, and they are gone once it succeeds, so there is nothing to
scale down or pause: check that no pod names it, rotate, and sync
`rustfs` (`argocd app sync rustfs`). The Job adds the new user and
removes the old one, whose access key no longer matches, so the old key
stops working at once; then rotate the consumer's copy.

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n rustfs get pods                      # rustfs only; no rustfs-register
kubectl -n rustfs delete secret rustfs-substrate
kubectl -n rustfs delete externalsecret rustfs-substrate
argocd app sync rustfs
```

To rotate the root, follow the whole procedure above for `rustfs-root`,
with the `rustfs` Application and `deploy/rustfs` scaled to 0. IAM and
the buckets live on the volume, not in the root's keys, so the users
survive it. Afterwards the pod's keys match the Secret's:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
for k in RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY; do
  [ "$(kubectl -n rustfs get secret rustfs-root -o jsonpath="{.data.$k}" | base64 -d)" = \
    "$(kubectl -n rustfs exec deploy/rustfs -c rustfs -- printenv $k)" ] && echo "$k matches"
done
```

Check the store, the Job and the policies, with a pod holding the
consumers' keys. On a cluster that does not name `substrate`, use `rustfs-quay`
and the bucket `quay`, with no second bucket to be denied:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n rustfs get pods,pvc          # rustfs Running; rustfs-data Bound on ceph-rbd
kubectl -n rustfs get secret -o custom-columns='NAME:.metadata.name,IMMUTABLE:.immutable,OWNER:.metadata.ownerReferences'
kubectl -n rustfs run s3-test --image=docker.io/rustfs/rc:v0.1.36 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"s3-test","image":"docker.io/rustfs/rc:v0.1.36",
    "command":["sleep","3600"],"env":[
      {"name":"AK","valueFrom":{"secretKeyRef":{"name":"rustfs-substrate","key":"access-key"}}},
      {"name":"SK","valueFrom":{"secretKeyRef":{"name":"rustfs-substrate","key":"secret-key"}}},
      {"name":"RC_HOST_s","value":"http://$(AK):$(SK)@rustfs-svc.rustfs.svc:9000"}]}]}}'
kubectl -n rustfs wait --for=condition=Ready pod/s3-test
kubectl -n rustfs exec s3-test -- sh -c 'echo hi > /tmp/x &&
  rc cp /tmp/x s/substrate/x && rc cat s/substrate/x && rc rm s/substrate/x
  rc ls s/quay/; rc anonymous set public s/substrate'   # hi, then AccessDenied twice
kubectl -n rustfs delete pod s3-test     # it names rustfs-substrate, so it must not outlive the check
```

### Keycloak

Keycloak is the platform's one identity provider (interview Q11), at
`https://keycloak.treasury.bank.internal`, which is also the issuer every token
carries: `https://keycloak.treasury.bank.internal/realms/<realm>`. Pods and the
laptop resolve the name alike, to the gateway, so a client in the cluster
calls the same URL a browser does. This is the server and its database; the
realm `default` is `keycloak-realm`'s (The realm, below), and the master realm
holds only the admin.

Two components, so Argo CD applies the CRDs before the resource that uses
them:

- `keycloak-operator` is the Keycloak Operator 26.8.2 from the release's
  manifests, `kubernetes/` at tag 26.8.2 of
  https://github.com/keycloak/keycloak-k8s-resources, vendored unmodified
  in `components/keycloak-operator/vendor/26.8.2/` and rendered with
  `#FileArtifact`, which gives the namespace-less manifests the namespace as
  `kubectl apply -n keycloak` would. It holds all four CRDs, `Keycloak`,
  `KeycloakRealmImport`, `KeycloakOIDCClient` and `KeycloakSAMLClient`: the
  operator starts a controller for each, and one without its CRD stops it.
  The CRDs carry `Prune=false,Delete=false`, since deleting one deletes
  every resource of its kind. The operator watches its own namespace only,
  registers no admission webhook, and gets a restricted security context
  the release leaves out, and its image and the server's by digest
  (`Keycloak.images`), where the release has tags. This component renders
  the namespace, `keycloak`,
  in the mesh (`istio.io/dataplane-mode=ambient`).
- `keycloak` is the `Keycloak` resource, its database, its credentials and
  its route. The operator runs the server as StatefulSet `keycloak`, one
  pod, with the `quay.io/keycloak/keycloak` image at the operator's own
  version: the resource names no image, so the two move together. With a
  database set it runs `start`, the production mode. The server listens on
  plain HTTP, 8080, behind the gateway, with its full URL set
  (`hostname.hostname`) and the gateway's `X-Forwarded` headers trusted
  (`proxy.headers: xforwarded`). From outside the cluster only the gateway
  reaches the server, but a pod can call `keycloak-service:8080` directly
  and forge `X-Forwarded-For`, which affects only the client address
  Keycloak logs, since the hostname is fixed. The operator's own Ingress
  is off, and
  `HTTPRoute` `keycloak` sends `keycloak.treasury.bank.internal` to Service
  `keycloak-service:8080`. Health is on the management port, 9000, which
  the kubelet probes from 169.254.7.127, admitted by `cilium-resources`'
  policy. The server's truststore adds the private root, from the
  `private-ca` ConfigMap trust-manager keeps in the namespace (the CR's
  `truststores` takes a ConfigMap), beside the image's public roots, so an
  outbound call to a `bank.internal` name, such as an identity broker's
  discovery through the gateway, verifies.

The database is CloudNativePG `Cluster` `keycloak-db`: one instance, a 10Gi
`ceph-rbd` volume, PostgreSQL 18.6 pinned by image
(`ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie`, CloudNativePG
1.30.1's default, stated), and a bootstrap `initdb` creating database
`keycloak` owned by `keycloak`. Keycloak connects as the owner to
`keycloak-db-rw`; the superuser stays disabled. Nothing stands in the way
of a `backup` stanza later. The `Cluster` carries `Prune=false,Delete=false`:
it owns its volume, which `ceph-rbd` reclaims with `Delete`, so pruning it
would drop every realm. It sets `enablePDB: false`: with one instance,
CloudNativePG's `keycloak-db-primary` budget allows no disruption, and a
drain or upgrade of the node holding the database would hang forever.
One instance means downtime on a drain anyway; a hang is worse. The database's pods are in the mesh too, so
Keycloak reaches PostgreSQL over HBONE.

The operator puts a `NetworkPolicy`, `keycloak-network-policy`, on the
server's pods, admitting 8080, 9000 and JGroups' ports alone. In the mesh,
ztunnel delivers a meshed client's connection, the gateway's included, to
the pod on 15008, HBONE, so that policy alone would drop every request
through the gateway; the CRD can narrow the policy's sources but not add a
port. `NetworkPolicy` `keycloak-allow-hbone` admits 15008 to the same pods
beside it. Should a meshed client get `Connection reset` from Keycloak while
the pod is Ready, check that it exists. Since 15008 is open to any source,
a meshed pod reaches every port in the Keycloak pod through ztunnel, so the
operator's per-port policy constrains only clients outside the mesh; an
Istio `AuthorizationPolicy` would be the control for meshed ones.

Both credentials are generated in the cluster with `#GeneratedSecret`
(Generated secrets, above), with a fixed username, so each is a
`kubernetes.io/basic-auth` Secret with `username` and `password`:

- `keycloak-admin`, username `admin`, the bootstrap admin. The operator
  gives it to the server, which creates the user in the master realm on its
  first start, against an empty database. Keycloak marks a bootstrap admin
  temporary and says so in the admin console; the mark changes nothing else.
- `keycloak-db`, username `keycloak`, the database's owner, which `initdb`
  creates and Keycloak connects as.

Read the admin's credential, to log in at
`https://keycloak.$domain/admin/`:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n keycloak get secret keycloak-admin -o json | jq '.data | map_values(@base64d)'
```

Both are immutable and written once, so rotating either follows the
procedure in Generated secrets, with the `keycloak` Application paused. The
operator owns StatefulSet `keycloak` and puts back any change to it, so
stop the server by setting the `Keycloak` resource's `spec.instances` to 0,
not by scaling the StatefulSet; the sync that turns automation back on sets
it to 1 again. Each Secret then needs one more thing:

- `keycloak-db`: nothing more by hand. CloudNativePG's instance manager
  reads the `initdb` Secret through the API, not a mount, and sets the
  owner's password in PostgreSQL to the new one when the Secret changes, so
  the database needs no restart; Keycloak, stopped, starts with the new one.
- `keycloak-admin`: the server reads it only to create the admin in an
  empty master realm, so a new Secret changes nothing in Keycloak by
  itself. Read the old password before deleting the Secret, and once the
  server is back, log in with it and set the admin's password to the new
  Secret's.

Neither rotation has been exercised on a cluster yet.

Check the server, the route and the admin, from the claude VM and from a
pod, without printing a credential:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n keycloak get cluster,keycloak,pods,pvc   # healthy, Ready, keycloak-db-1 Bound on ceph-rbd
kubectl -n keycloak get pod keycloak-0 -o jsonpath='{.spec.containers[0].args}'   # ends in start
kubectl -n keycloak get secret keycloak-admin keycloak-db \
  -o custom-columns='NAME:.metadata.name,TYPE:.type,IMMUTABLE:.immutable,OWNER:.metadata.ownerReferences'
kubectl -n keycloak get configmap private-ca -o jsonpath='{.data.ca\.crt}' > root.pem
curl -s --cacert root.pem https://keycloak.$domain/realms/master/.well-known/openid-configuration |
  jq -r .issuer                                     # https://keycloak.$domain/realms/master
u=$(kubectl -n keycloak get secret keycloak-admin -o jsonpath='{.data.username}' | base64 -d)
p=$(kubectl -n keycloak get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d)
curl -s --cacert root.pem https://keycloak.$domain/realms/master/protocol/openid-connect/token \
  -d grant_type=password -d client_id=admin-cli --data-urlencode "username=$u" \
  --data-urlencode "password=$p" | jq 'has("access_token")'   # true
unset u p
```

### The realm

The platform's realm is `default`, issuer
`https://keycloak.treasury.bank.internal/realms/default`. It is not part of
the brand: every distribution names its realm `default`, and the issuer's
host tells them apart (ADR 0002). holos-controller 0.22.0, the platform
controller, has no kind for a realm, a client scope or a protocol mapper, nor a
field for the device grant, so the realm comes in two halves (interview Q50):

- A `KeycloakRealmImport`, `default` in `keycloak`, creates the realm with
  what the controller cannot reconcile:
  - the `groups` client scope, whose `oidc-group-membership-mapper` writes
    each user's groups by full path (`/platform/owners`) into the claim
    `groups` of the ID token, the access token and userinfo (Q6). It is a
    realm default default scope, so every client gets it, the controller's
    included. An import that lists any client scope gets none of Keycloak's
    built-in ones, so those are listed too, as the master realm of a fresh
    26.8.2 has them (`components/keycloak-realm/client-scopes.json`).
  - the public client `kubectl`, with the device grant, and the standard
    flow for kubelogin's loopback redirects. PKCE is not required on it:
    Keycloak 26.8.1 then demands a `code_challenge` on the device grant too,
    which not every device-flow client sends.
  - the public client `argocd`, with PKCE S256 required (Q51), redirects
    `/auth/callback` and `/pkce/verify` on
    `https://argocd.treasury.bank.internal` and
    `http://localhost:8085/auth/callback` for the CLI.
  - the confidential client `svc-seabank-controller`, named
    `seabank-controller`, client credentials only, whose service account holds the `realm-management` roles
    `manage-clients`, `manage-users`, `query-clients` and `query-groups`.
    Not `manage-realm`: aavis-ops grants it only for a `Group`'s
    `custodians`, which need fine-grained admin permissions, and nothing
    here uses them, so the realm leaves `adminPermissionsEnabled` off.
    Keycloak 26.8.2 asks two more things of a client like this one (The
    Admin API since 26.8.2, below): `kc-admin-api` among its default scopes,
    and the realm attribute
    `allowedProtocolMapperTypesForClientAdministrators` naming the mapper
    the controller writes.
  - the user `jeff`, `jeff@bank.internal`, with the realm role
    `default-roles-default`. An imported user gets only the roles it lists, and
    without that role's `offline_access` Keycloak refuses the Secrets
    Manager's login, which asks for that scope.
  - the service user `svc-quay-controller`, `svc-quay-controller@bank.internal`,
    Quay's superuser, which `cmd/quay-bootstrap` logs in to Quay as (Quay,
    below). Its first and last name and its verified email are set, so
    Keycloak never interposes its `VERIFY_PROFILE` form, and it holds
    `default-roles-default` as `jeff` does. A realm imported before it was
    added has it only once it is created by hand (Quay, below).
- the platform controller's resources, in `keycloak` beside the import: the
  `Instance` `default`, the `Group` `platform-owners` at path
  `platform/owners`, and the `GroupMembership` `platform-owners` putting
  `jeff@bank.internal` in it. The controller finds a member by email among
  the realm's users, so the imported user needs no `User` resource. All three
  are in the `Instance`'s namespace, so there is no `ReferenceGrant`. The
  controller creates the parent group `/platform`, which it does not own.

Two components. `seabank-controller`, from `components/holos-controller`,
is the manager, holos-controller from aavis-ops at tag
`holos-controller-v0.22.0`: all eight CRDs (`keycloak.holos.run`,
`quay.holos.run`, `security.holos.run`; the manager starts a controller for
every kind) with `Prune=false,Delete=false`, its RBAC and its Deployment,
vendored unmodified in `components/holos-controller/vendor/0.22.0/`, with the
image set to `ghcr.io/holos-run/holos-controller:holos-controller-v0.22.0`
pinned by digest. The release names its namespace `holos-controller` and its
objects `holos-controller-<suffix>`; the component's Kustomize patches give
them the distribution's names, namespace `seabank-controller`,
`Deployment` and `ServiceAccount` `seabank-controller-manager` and so
on, and the vendored files stay as released. It registers no webhook. It mounts the namespace's
`private-ca` ConfigMap at `/etc/ssl/private-ca` and adds it to Go's system
trust with `SSL_CERT_DIR=/etc/ssl/certs:/etc/ssl/private-ca`, as
argocd-server does, so the Quay resources need no `caBundle` (Quay, below).
`keycloak-realm`, after it, is
everything above plus the credential, so the CRDs are established before
Argo CD applies the resources.

The realm's three secrets are generated in `keycloak` (Generated secrets,
above), because the import's placeholders read Secrets in the import's own
namespace: `svc-seabank-controller`, username the client ID, password the
client's secret, `seabank-user-jeff`, username `jeff`, and
`svc-quay-controller`, username `svc-quay-controller`. The import's
`spec.placeholders` hands their passwords to the import Job as environment
variables, which Keycloak puts in place of `${SVC_CONTROLLER_CLIENT_SECRET}`,
`${JEFF_PASSWORD}` and `${SVC_QUAY_CONTROLLER_PASSWORD}`, so no value is in
the resource or in git.

The controller reads its credential from its own namespace, from the
downward API's `POD_NAMESPACE`, whatever the `Instance`'s namespace. An
`ExternalSecret` there, `seabank-controller-keycloak-creds`, copies
`svc-seabank-controller` into the keys the controller reads, `clientId` and
`clientSecret`, through `SecretStore` `keycloak`, External Secrets'
`kubernetes` provider, which authenticates as ServiceAccount
`keycloak-secret-reader` and may `get` that one Secret in `keycloak`: a
per-namespace store, `#ScopedSecretStore` (Secrets Manager, below), with
`source: "keycloak"`. The
value is generated once, in one place; the copy is not immutable and follows
its source hourly, or at once with
`kubectl -n seabank-controller annotate externalsecret seabank-controller-keycloak-creds force-sync=$(date +%s) --overwrite`.

The `Instance` names `https://keycloak.treasury.bank.internal`, through the
gateway, whose certificate is the private CA's. The root is minted in the
cluster, so it is not rendered (Q52): the `PostSync` Job `instance-cabundle`, in
`keycloak`, base64-encodes `ca.crt` of the namespace's `private-ca`
ConfigMap into the `Instance`'s `spec.caBundle` with a merge patch, as field
manager `instance-cabundle`, after every sync of `keycloak-realm`. Its Role
may `get` and `patch` that one `Instance`. Argo CD's server-side apply does
not own the field and leaves it, and the `Application` ignores it. Until the
Job has run, as on the first sync, the `Instance` and everything naming it
report `x509: certificate signed by unknown authority`. To run it by hand,
`argocd app sync keycloak-realm`, or apply
`deploy/clusters/<cluster>/components/keycloak-realm/job-instance-cabundle.yaml`
and delete the Job once it completes.

**The import is one-shot.** The operator runs the import as Job `default`
with `--override false`, from the server's image straight into the
database; a realm that exists is left as it is, and the `KeycloakRealmImport`
reports `Done`. So a change to the realm in `keycloak-realm.cue` renders and
syncs, but changes nothing in Keycloak. To apply one, re-import, which
drops the realm: every session, the users' passwords other than the
imported ones, and every client and group the controller made, until it
makes them again. With automation paused on `keycloak-realm` (and on the
root, `argocd-apps`, which would turn it back on):

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
# 1. Let the controller remove what it made: its finalizers delete the
#    groups, memberships and clients in Keycloak. Deleting the realm first
#    would leave its resources reporting errors with finalizers stuck.
kubectl -n keycloak delete groupmembership,group --all     # and any Client or User in other namespaces
# 2. The import, then the realm, with the master admin's token.
kubectl -n keycloak delete keycloakrealmimport default
t=$(curl -s --cacert root.pem https://keycloak.$domain/realms/master/protocol/openid-connect/token \
  -d grant_type=password -d client_id=admin-cli --data-urlencode "username=$u" --data-urlencode "password=$p" | jq -r .access_token)
curl -s --cacert root.pem -X DELETE -H "Authorization: Bearer $t" https://keycloak.$domain/admin/realms/default -w '%{http_code}\n'  # 204
# 3. Turn automation back on; the sync re-creates the import, the groups and
#    the memberships, and its PostSync Job runs again.
```

`u` and `p` are the master admin's, as in the check under Keycloak, above.
The generated Secrets are kept, so the controller's credential and jeff's
password survive a re-import. This procedure was run once on treasury. The
import Job's completed pod names both Secrets, so rotating either (Generated
secrets, above) needs that pod gone first, and a re-import after, since the
realm holds the values it was imported with.

**The Admin API since 26.8.2.** Two security fixes in 26.8.2 change what the
controller's client needs, and the import carries both, so a realm imported
from 26.8.2 on has them:

- The Admin REST API refuses a token without the built-in `kc-admin-api`
  scope, and the audience it adds, with 401 (CVE-2026-19688). The migration
  creates the scope in every realm but gives it only to `admin-cli` and
  `security-admin-console`, so the master admin's calls in this README keep
  working and the controller's stop: each `keycloak.holos.run` resource
  reports the 401 at its next reconcile, and until then still reads Ready,
  so Ready alone does not show the realm is fixed. No realm default carries
  the scope, so `kubectl`'s and
  every other client's tokens do not get that audience.
- Only `manage-realm` may write a protocol mapper, unless the realm's
  `allowedProtocolMapperTypesForClientAdministrators` lists its type. The
  controller makes one `oidc-usermodel-client-role-mapper` on every `Client`
  it reconciles, before it delivers the client's secret. One that has the
  mapper is left alone, so a running Client does not notice, but a new one
  gets 403 and never its secret.

A realm imported before 26.8.2 needs both by hand, once, since the import is
one-shot: the operator does not run its Job again for the new render. Run
this after the server has started on 26.8.2, on each cluster; until then the
controller cannot write, and logins are unaffected. `u` and `p` as above,
with the restart's rollout finished before the check is read:

```sh
t=$(curl -s --cacert root.pem https://keycloak.$domain/realms/master/protocol/openid-connect/token \
  -d grant_type=password -d client_id=admin-cli --data-urlencode "username=$u" --data-urlencode "password=$p" | jq -r .access_token)
a=https://keycloak.$domain/admin/realms/default
sid=$(curl -s --cacert root.pem -H "Authorization: Bearer $t" "$a/client-scopes" | jq -r '.[] | select(.name=="kc-admin-api").id')
cid=$(curl -s --cacert root.pem -H "Authorization: Bearer $t" "$a/clients?clientId=svc-seabank-controller" | jq -r '.[0].id')
curl -s --cacert root.pem -X PUT -H "Authorization: Bearer $t" "$a/clients/$cid/default-client-scopes/$sid" -w '%{http_code}\n'  # 204
# A realm's PUT replaces its attributes, so the body keeps the ones it has.
curl -s --cacert root.pem -H "Authorization: Bearer $t" "$a" |
  jq '{attributes: (.attributes + {allowedProtocolMapperTypesForClientAdministrators: "oidc-usermodel-client-role-mapper"})}' |
  curl -s --cacert root.pem -X PUT -H "Authorization: Bearer $t" -H 'Content-Type: application/json' "$a" -d @- -w '%{http_code}\n'  # 204
kubectl -n seabank-controller rollout restart deploy/seabank-controller-manager   # clears the failed reconciles' backoff
kubectl -n seabank-controller rollout status deploy/seabank-controller-manager
kubectl get clients.keycloak.holos.run,users.keycloak.holos.run,groups.keycloak.holos.run,groupmemberships.keycloak.holos.run -A   # READY True
curl -s --cacert root.pem -H "Authorization: Bearer $t" "$a" | jq .attributes     # the mapper's type, beside the rest
```

jeff's password, to log in at
`https://keycloak.$domain/realms/default/account` or to Argo CD:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n keycloak get secret seabank-user-jeff -o jsonpath='{.data.password}' | base64 -d
```

Check the realm, the controller and a token, without printing a secret
(`root.pem`, `u` and `p` as under Keycloak, above):

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
curl -s --cacert root.pem https://keycloak.$domain/realms/default/.well-known/openid-configuration |
  jq -r .issuer                                  # https://keycloak.$domain/realms/default
kubectl -n keycloak get keycloakrealmimport default \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].status}'   # True
kubectl -n seabank-controller get deploy,externalsecret,secretstore   # 1/1, SecretSynced, Valid
kubectl -n keycloak get instance,group,groupmembership             # READY True
t=$(curl -s --cacert root.pem https://keycloak.$domain/realms/master/protocol/openid-connect/token \
  -d grant_type=password -d client_id=admin-cli --data-urlencode "username=$u" --data-urlencode "password=$p" | jq -r .access_token)
a=https://keycloak.$domain/admin/realms/default
uid=$(curl -s --cacert root.pem -H "Authorization: Bearer $t" "$a/users?email=jeff@bank.internal&exact=true" | jq -r '.[0].id')
cid=$(curl -s --cacert root.pem -H "Authorization: Bearer $t" "$a/clients?clientId=kubectl" | jq -r '.[0].id')
curl -s --cacert root.pem -H "Authorization: Bearer $t" \
  "$a/clients/$cid/evaluate-scopes/generate-example-id-token?userId=$uid&scope=openid" |
  jq -c '{aud, groups}'                          # {"aud":"kubectl","groups":["/platform/owners"]}
curl -s --cacert root.pem https://keycloak.$domain/realms/default/protocol/openid-connect/auth/device \
  -d client_id=kubectl -d scope=openid | jq 'has("device_code")'   # true
```

### holos-authenticator

`seabank-authenticator`, the platform authenticator from
`components/holos-authenticator`, puts the Kubernetes API at
`https://k8s.treasury.bank.internal` behind a Keycloak login (interview Q60 to
Q63): a person's kubeconfig carries the ID token kubelogin prints for the
`kubectl` client, and the API server sees the request as an impersonation of
them, `oidc:<username>` with their groups by full path, so Kubernetes RBAC
does the rest. `PlatformAuthenticator` (`components/holos-authenticator.cue`)
has the release, the names, built from the brand (namespace, `Deployment`,
`ServiceAccount` and `Service` `seabank-authenticator`), and the users and groups that may be impersonated.

holos-authenticator 0.21.0, from aavis-ops, is an Envoy external
authorization server, plaintext gRPC on 9000, and a controller of
`Backend` resources (`authenticator.holos.run/v1alpha1`) in its own
namespace. It is not a proxy: Envoy asks it about each request. A request
takes this path:

1. `ingress`'s `k8s` listener passes the connection through, on SNI, to the
   ClusterIP Service `k8s-istio` of the `Gateway` `seabank-authenticator/k8s`
   (`TLSRoute` `seabank-authenticator/k8s`).
2. That Gateway terminates TLS with the `Certificate` `k8s` from the
   `private-ca` ClusterIssuer.
3. The `CUSTOM` `AuthorizationPolicy` `k8s` sends every request to the
   extension provider `seabank-authenticator` (Istio, above). The manager
   refuses with 403 a request carrying any `Impersonate-*` header or
   `x-impersonate-groups`, and with 401 one with no bearer token or a token
   it cannot verify. A request for any other host gets 404 from the
   gateway, which has no route for it. It verifies the
   token as an ID token (ADR 0002): signature against the realm's JWKS,
   `iss`, `aud` holding `kubectl`, `exp` and `nbf`. It answers OK with
   three headers to overwrite: `Impersonate-User: oidc:<preferred_username>`,
   `x-impersonate-groups` with the forwarded groups joined by `|`, and
   `Authorization: Bearer <the impersonator's token>`.
4. The `TrafficExtension` `impersonate-groups`, a few lines of Lua, splits
   `x-impersonate-groups` into one `Impersonate-Group` per group and removes
   it. Envoy's ext_authz drops an appended header the request did not
   carry, which is why the groups come back as one header.
5. The `HTTPRoute` `seabank-authenticator/kubernetes` sends the request to the
   `kubernetes` Service in `default`, which the `ReferenceGrant`
   `default/seabank-authenticator-kubernetes` allows, and the
   `DestinationRule` `kubernetes` originates TLS to it, checking the API
   server's certificate against the cluster's CA at the ServiceAccount path
   for `kubernetes.default.svc`.
6. The API server authenticates the impersonator, checks that it may
   impersonate the user and each group, adds `system:authenticated`, and
   authorizes the request as the impersonated user.

- **Its own Gateway.** As the Substrate shim has (The Substrate shim,
  below), for a different reason: the Lua turns a header into
  `Impersonate-Group` lines and the gateway holds the impersonator's token,
  and neither should be on `ingress`, in front of every other backend. Two
  replicas, preferably on two nodes. Its pods carry
  `istio.io/dataplane-mode: none`, as every gateway istiod deploys does, so
  the ambient namespace does not capture them.
- **The filter order.** `TrafficExtension` has no phase, so istiod puts it
  after the authorization filters. The gateway's listener, from
  `pilot-agent request GET config_dump`, runs `istio.metadata_exchange`,
  `envoy.filters.http.rbac`, `envoy.filters.http.ext_authz`, the Lua, then
  the stats and CORS filters and the router: the Lua sees the manager's
  headers. Had it run first, a client's `x-impersonate-groups` would have
  reached the manager as `Impersonate-Group` and been refused, so the
  order fails closed either way.
- **The manager.** `Deployment` `seabank-authenticator`, two replicas, each
  answering ext_authz from its own copy of the Backends; leader election
  decides only which writes their status. It watches only its own namespace
  (`POD_NAMESPACE`), so a `Backend` anywhere else is never served, and a
  `Role` there is all its RBAC: Backends, their status, events, its
  `Lease`, and a token for the impersonator alone. It trusts the private
  root as the platform controller does, by `SSL_CERT_DIR` on a mount of the
  `private-ca` ConfigMap, so the `Backend`'s `oidc.caBundle`, base64 PEM,
  stays empty and out of git. Metrics are off.
- **Who may call it.** The Check response carries the impersonator's token,
  so `AuthorizationPolicy` `seabank-authenticator-grpc` admits port 9000 only
  from the gateway's mesh identity,
  `cluster.local/ns/seabank-authenticator/sa/k8s-gateway`. The namespace is in
  ambient, so ztunnel enforces it; any other pod gets its connection reset
  (`policy rejection: allow policies exist, but none allowed` in ztunnel's
  log). The gateway speaks HBONE to the manager itself. The exception is
  the node's own network namespace, which istio-cni lets through unchecked
  for the kubelet's probes: a hostNetwork pod on a manager's node can reach
  port 9000. Only cilium and the ceph-csi node plugin run there today.
- **The Backend.** `kubernetes`, for host `k8s.treasury.bank.internal`, matched
  exactly against `:authority`, so a client that sends `:443` in `Host` is
  refused as an unknown host. `oidc.clientID` is `kubectl` (Q61, ADR 0002):
  the audience kubelogin's token already has, so one login serves the API
  and the shim. The user is `oidc:` and `preferred_username` (Q62); the
  groups are the `groups` claim, forwarded only if in
  `groupMapping.anyOf`. The credential is a token for
  `seabank-authenticator-impersonator`, minted with the TokenRequest API for
  an hour and renewed.
- **The allowlist.** `PlatformAuthenticator.users` and `.groups`.
  The impersonator's `ClusterRole` may impersonate exactly those users, with
  the `oidc:` prefix, and those groups, and nothing else, so its token can
  become only them. `groups` is also the `Backend`'s `anyOf`, so a group in
  a token but not on the list is dropped, and logged, rather than refusing
  the whole request, which the API server would do for a group the
  impersonator may not impersonate. A user not on `users` is refused by the
  API server with 403. `users` is `jeff` (`Keycloak.users.jeff`, the one
  user the realm import creates) and the owners of every project on the
  cluster, and `groups` is `/platform/owners` and those projects' owner
  groups; the owners and their groups come from the ProjectClaim collection
  (Projects, below), so an owner on another cluster is on neither list here.
- **What a group may do** is a binding of its own: `ClusterRoleBinding`
  `platform-owners-cluster-admin` makes `/platform/owners` `cluster-admin`
  (Q63), as it is Argo CD's `role:admin`.
- **Streaming.** `get -w`, `logs -f`, `exec`, `exec -i` and
  `port-forward` work with kubectl 1.37, which upgrades to WebSocket
  (`v5.channel.k8s.io`): Envoy passes WebSocket upgrades and the route has
  no timeout. A client that speaks only SPDY, kubectl before 1.30 for
  `exec` or with `KUBECTL_REMOTE_COMMAND_WEBSOCKETS=false`, gets `unable to
  upgrade connection: empty server response`: Envoy does not pass the
  `SPDY/3.1` upgrade.
- **Client addresses.** `ingress` passes the connection through, so the
  API server's audit log has the gateway pod's address, not the client's.
  The route removes `X-Forwarded-For` and `X-Real-IP`, since the gateway
  appends to a client's own `X-Forwarded-For` and the API server records
  every entry in `sourceIPs`.

#### Logging in with kubectl

From a machine that trusts the private root (The private CA, above), with
kubelogin (`kubectl oidc-login`). `--grant-type=device-code` prints a URL to
open anywhere, for a machine without a browser; leave it out on a laptop,
and kubelogin opens the browser and listens on `localhost:8000`, a redirect
the `kubectl` client allows. The cluster, user and context are all
`$cluster-oidc`, so each cluster's login keeps its own issuer: on treasury
this renames the user from `oidc`, as earlier versions of this block named
it, to `treasury-oidc`, and running the block again adds it and repoints
the context. The block unsets `KUBECONFIG`, which an earlier block may have
pointed at the Talos admin kubeconfig, so the login goes in
`~/.kube/config`.

```sh
unset KUBECONFIG
kubectl config set-cluster $cluster-oidc --server=https://k8s.$domain \
  --certificate-authority="$root_ca" --embed-certs
kubectl config set-credentials $cluster-oidc --exec-api-version=client.authentication.k8s.io/v1 \
  --exec-interactive-mode=IfAvailable --exec-command=kubectl \
  --exec-arg=oidc-login --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://keycloak.$domain/realms/default \
  --exec-arg=--oidc-client-id=kubectl --exec-arg=--grant-type=device-code
kubectl config set-context $cluster-oidc --cluster=$cluster-oidc --user=$cluster-oidc
kubectl --context $cluster-oidc auth whoami   # oidc:jeff, [/platform/owners system:authenticated]
```

The ID token lasts five minutes; kubelogin renews it with its refresh token
from its cache, the same cache `kubectl oidc-login get-token` reads for the
Substrate shim.

#### Adding a person or a group

- **A person**: as the owner of a project, through its claim (Projects,
  below). Otherwise add them to `Keycloak.users` and their username to
  `PlatformAuthenticator.users`, and create them in the realm by hand, as
  `svc-quay-controller` was (Quay, below). The realm import creates only
  `jeff`; it does not read the rest of `Keycloak.users`.
- **A group**: add its full path to `PlatformAuthenticator.groups`, and bind
  it to what it may do, with a binding of its own.

Render and commit. The sync changes the impersonator's `ClusterRole` and the
`Backend`, which the manager reloads.

#### Rotation

- **The impersonator's token** is minted for an hour and renewed by the
  manager before it expires.
- **Keycloak's signing keys**: the manager fetches the JWKS itself and
  refreshes it when it sees an unknown key.
- **The private root**: Go reads the pool once, so a new root needs a
  restart of the manager (`kubectl -n seabank-authenticator rollout restart
  deploy/seabank-authenticator`).
- **The certificate** `k8s` is renewed by cert-manager, and istiod hands it
  to the gateway as it changes.

#### Checking holos-authenticator

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n seabank-authenticator get gateway,certificate,backend,pods -o wide
    # k8s PROGRAMMED True; k8s Ready; backend kubernetes READY True;
    # two seabank-authenticator and two k8s-istio pods, on two nodes each
kubectl -n istio-ingress get gateway ingress \
  -o jsonpath='{range .status.listeners[*]}{.name} {.attachedRoutes}{"\n"}{end}'   # k8s 1
# The Lua after ext_authz:
kubectl -n seabank-authenticator exec deploy/k8s-istio -c istio-proxy -- \
  pilot-agent request GET 'config_dump?resource=dynamic_listeners' \
  | jq -r '.. | .http_filters? // empty | [.[].name] | join(" -> ")'
# With $TOKEN a kubectl ID token for a member of /platform/owners (The Substrate shim):
kubectl --kubeconfig=/dev/null --server=https://k8s.$domain \
  --certificate-authority="$root_ca" --token="$TOKEN" auth whoami
curl --cacert "$root_ca" https://k8s.$domain/api                  # 401
curl --cacert "$root_ca" -H "Authorization: Bearer $TOKEN" \
  -H 'Impersonate-Group: system:masters' https://k8s.$domain/api            # 403
curl --cacert "$root_ca" -H "Authorization: Bearer $TOKEN" \
  -H 'x-impersonate-groups: system:masters' https://k8s.$domain/api         # 403
# An ID token for another client, such as argocd, gets 401. The impersonator
# may impersonate only the listed users and groups:
kubectl create -o jsonpath='{.status.allowed}{"\n"}' -f - <<'YAML'                 # false
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: system:serviceaccount:seabank-authenticator:seabank-authenticator-impersonator
  resourceAttributes: {verb: impersonate, resource: users, name: "oidc:svc-quay-controller"}
YAML
```

### Secrets Manager

The Bank of the Salish Sea Secrets Manager (holos-run/secrets-manager) is
where platform secrets are made (interview Q18): a Go server with a web UI,
at `https://secrets.treasury.bank.internal`, that manages Kubernetes Secrets
directly, with Keycloak login and grants, so there is no external store. A
secret is made in the management namespace through the UI, and an
`ExternalSecret` in the consumer's namespace copies it there through that
consumer's own store. `SecretsManager` (`components/secrets-manager.cue`)
holds the release, the names and the URL; the `secrets-manager` component
renders the rest.

- **The server.** One Deployment in the ambient namespace
  `secrets-manager`, the release's distroless nonroot image pinned by
  digest, restricted: non-root, a read-only root, all capabilities dropped.
  It serves plain HTTP on 8080 behind the gateway, which terminates TLS as
  it does for Keycloak (`--plain-http --listen=:8080`), and its public URL
  is `--origin=https://secrets.treasury.bank.internal`. It trusts the private
  root from the namespace's `private-ca` ConfigMap, mounted and named by
  `--ca-cert`, for its calls to the issuer. The kubelet probes `/healthz`
  and `/readyz`. It keeps no state beyond Namespaces and Secrets, and acts
  as its own ServiceAccount, `secrets-manager`, impersonating no one.
- **Its RBAC.** Two ClusterRoles, each `get`, `list`, `create`, `update`
  and `delete`. `secrets-manager`, on `namespaces`, is bound cluster wide,
  since organizations and projects are Namespaces the server may make at
  runtime. `secrets-manager-secrets`, on `secrets`, is bound only by a
  `RoleBinding` in each project namespace git renders, beside the
  namespace, so in `seabank-prj-platform` alone for now: the server reads and
  writes Secrets only in project namespaces, which in this distro come from
  git. The cost is that a project made in the UI has no access to its
  secrets until git adds its `RoleBinding`. A ProjectClaim renders no
  Secrets Manager project yet (interview Q64); rendering one for each claim
  is the tech debt item secrets-manager-project-for-each-projectclaim. The
  namespace writes are still cluster wide: the
  ServiceAccount may update or delete any Namespace, and deleting one
  deletes everything in it. A `ValidatingAdmissionPolicy` holding them to
  `seabank-` namespaces with the server's labels is open hardening.
- **Login.** OIDC against the realm `default` (`--issuer`, which must always
  be set: an empty issuer turns authentication off), through the public
  client `secrets-manager`, which a platform controller `Client` in
  `secrets-manager` creates, with the `ReferenceGrant`
  `secrets-manager-clients` in `keycloak` allowing it to name the
  `Instance` there. Its redirect is
  `https://secrets.treasury.bank.internal/pkce/verify` and its web origin the
  URL; the SPA runs the code flow with PKCE and asks for `openid profile email
  groups offline_access`. The server verifies the bearer as an ID token whose
  `aud` is `secrets-manager` (ADR 0002) and reads roles from `groups`
  (`--roles-claim`), full paths. The `Client` has no field for a post-logout
  redirect, so logging out ends on Keycloak's page.
- **Organizations.** Only `/platform/owners` may create one
  (`--disable-org-creation --org-creator-roles=/platform/owners`, Q55).
  Never `--enable-insecure-dex`.
- **Brand.** `--app-name=Bank of the Salish Sea Secrets Manager`
  (`SecretsManager.appName`, from `Brand.name`) is the page title and the
  name in the SPA's sidebar, and `--namespace-prefix=seabank-`
  (`SecretsManager.namespacePrefix`, from `Brand.slug`) puts every
  organization and project namespace under the brand, in place of the
  release's defaults, `Holos Secrets Manager` and `holos-`. The label and
  annotation keys keep the release's domain, `holos.run`
  (`--metadata-domain`), the software's.
- **The route.** `HTTPRoute` `secrets-manager` on the gateway's HTTPS
  listener. The server's `/metrics` is unauthenticated on the same port, so
  the route's first rule, path prefix `/metrics` with no backend, wins for
  it and everything under it, and the gateway answers 500 without reaching
  the server. The gateway normalizes paths before matching (`/%6Detrics`,
  `/a/../metrics`), and the server redirects `//metrics` to `/metrics`.

v0.19.0's SPA sends the access token, which the server refuses, so with it
the UI loads and login succeeds but every call after fails as
unauthenticated. The release that sends the ID token replaces it, a change
to `SecretsManager.version` and `image` alone.

#### The management namespaces

`seabank-prj-platform` (Q54) is a Secrets Manager project, `platform`,
under the server's prefixes, `seabank-` (`--namespace-prefix`) and
`prj-`, in the organization `platform`, `seabank-org-platform`. The SPA lists projects only within the
organization chosen, so the project needs one. The server lists a namespace
only when it carries its labels, so git renders both with them, in the
`management-namespaces` component, early in the registry:
`app.kubernetes.io/managed-by: holos.run`, `holos.run/resource-type`
(`organization` or `project`), and `holos.run/organization: platform`; the
project also carries `holos.run/project: platform`, and it is the
`organization` label the server's project list filters on. Both are shown
as Platform. Their annotations are the server's grants, JSON lists:

- `holos.run/share-roles`, on both:
  `[{"principal":"/platform/owners","role":"owner"}]`. On the organization
  it lets owners see it and make projects in it. On the project, owners may
  list, create, update and delete its secrets and change its grants. A
  project grant never lets anyone read a secret's data by itself, but an
  owner may share a secret to themselves, as a secret admin, and then read
  it.
- `holos.run/default-share-roles`, on the project, the same list, which the
  server puts on every secret made in the project, so platform owners may
  read and share each one. The person who makes a secret is always its
  owner too.

Beside the project is `RoleBinding` `secrets-manager-secrets`, which lets
the server work with its Secrets (Its RBAC, above).

Both namespaces carry `Prune=false,Delete=false`: the project's secrets are
not in git, and deleting it deletes them all. A platform owner can still
delete the project from the UI, which deletes the namespace; Argo CD would
re-create it empty. Git owns the rendered annotations: the server writes a
Namespace only when someone edits the organization or project in the UI,
and an edit there to the display name, the description or a role grant
shows as out of sync in Argo CD and is put back by self-heal. A grant to a
person (`share-users`) is not rendered and stays.

#### Per-namespace stores

A consumer reads platform secrets through a store of its own, in its own
namespace, that may read the named Secrets and nothing else (Q18).
`#ScopedSecretStore` (`components/secret-store.cue`) renders it from a
name, the consumer's namespace and the Secret names; the source defaults to
`seabank-prj-platform`:

```cue
resources: (#ScopedSecretStore & {
	name:      "platform"
	namespace: "ceph-csi-rbd"
	secrets: ["ceph-client-k8s"]
	// source: "keycloak"
}).resources
```

It renders four resources: ServiceAccount `<namespace>-<name>-reader` in
the consumer's namespace; a Role of the same name in the source namespace that
may `get` only the named Secrets (`resourceNames`, no `list`); its
RoleBinding there; and `SecretStore` `<name>` of the `kubernetes` provider
in the consumer's namespace, reading the source namespace as that
ServiceAccount and verifying the API server against `kube-root-ca.crt`.
There is no `ClusterSecretStore`: with one, a project Owner with admin in
their namespace could write an `ExternalSecret` copying the Keycloak admin
credential. The Role is in the source namespace, which no consumer
controls, and which every consumer of it shares, so its default name
carries the consumer's namespace. The store reports `ReadWrite`
capabilities, as every `kubernetes` provider store does, but its Role may
only `get`, so a `PushSecret` through it is refused. `keycloak-realm` uses
it for the platform controller's credential, with `source: "keycloak"` and
`reader: "keycloak-secret-reader"`, the name it had before.

The consumer then writes its own `ExternalSecret` against the store, with
`creationPolicy: Owner`, since the source is the truth and the copy follows
it within its `refreshInterval`:

```cue
ExternalSecret: "ceph-client-k8s": {
	metadata: namespace: "ceph-csi-rbd"
	spec: {
		refreshInterval: "1h"
		secretStoreRef: {kind: "SecretStore", name: "platform"}
		target: creationPolicy: "Owner"
		dataFrom: [{extract: key: "ceph-client-k8s"}]
	}
}
```

The consumer comes after `management-namespaces` in the registry, so the
namespace its Role and RoleBinding land in exists first. That is all the
order guarantees: the secret itself is made through the UI, so on a new
cluster a consumer's `ExternalSecret` reports `SecretSyncedError` until
someone makes it, and a component earlier than `secrets-manager` cannot
depend on a platform secret to come up. The Ceph key is the exception:
bootstrap writes it with `kubectl`, before Argo CD, so `ceph-csi-rbd` copies
it on its first sync (Storage, above).

#### Adding a platform secret

1. Log in at `https://secrets.$domain` as a member of
   `/platform/owners`, such as `jeff` (Logging in, under Bootstrap Argo
   CD: the same password), choose the `Platform` organization and open
   its `Platform` project.
2. Create the secret, with the name and keys the consumer expects. The
   server makes it in `seabank-prj-platform`, owned by you and, by the
   project's default grant, by `/platform/owners`.
3. To let someone else read it, share it with them, a user by email or a
   role by group path, as viewer: reading a secret's data needs a grant on
   the secret itself. External Secrets needs no grant in the Secrets
   Manager; it reads through Kubernetes RBAC, the consumer's Role.
4. Name the secret in the consumer's `#ScopedSecretStore`, add its
   `ExternalSecret`, render and merge. A store asked for any other Secret
   gets a 403 from the API server, and its `ExternalSecret` reports
   `SecretSyncedError`.

Check the server, the client and the route (`root.pem` as under Keycloak,
above):

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n secrets-manager get deploy,client               # 1/1, READY True
kubectl -n secrets-manager get httproute secrets-manager \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'   # True
kubectl -n keycloak get referencegrants.security.holos.run
kubectl get ns -L holos.run/resource-type,holos.run/organization -l app.kubernetes.io/managed-by=holos.run
kubectl -n seabank-prj-platform get rolebinding secrets-manager-secrets
curl -s --cacert root.pem -o /dev/null -w '%{http_code}\n' https://secrets.$domain/          # 200
curl -s --cacert root.pem -o /dev/null -w '%{http_code}\n' https://secrets.$domain/metrics   # 500
kubectl -n secrets-manager exec deploy/secrets-manager -- /bin/secrets-manager --version           # the pinned release
```

Check a store with a throwaway consumer, rendered from the definition, and a
secret `sm-test` made in the UI:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
cue export ./components --out text -e 'yaml.MarshalStream([for K, V in (#ScopedSecretStore &
  {name: "platform", namespace: "sm-test", secrets: ["sm-test"]}).resources for R in V {R}])' > store.yaml
kubectl create ns sm-test
kubectl apply --server-side -f store.yaml   # reader sm-test-platform-reader
for n in sm-test sm-test-other; do kubectl apply --server-side -f - <<YAML
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: $n, namespace: sm-test}
spec:
  refreshInterval: 1h
  secretStoreRef: {kind: SecretStore, name: platform}
  target: {creationPolicy: Owner}
  dataFrom: [{extract: {key: $n}}]
YAML
done
kubectl -n sm-test get secretstore,externalsecret   # Valid; sm-test SecretSynced, sm-test-other SecretSyncedError
kubectl -n sm-test describe externalsecret sm-test-other | grep -i forbidden
kubectl delete -f store.yaml   # its Role and RoleBinding in seabank-prj-platform, by name
kubectl delete ns sm-test
```

### Substrate

`substrate` is Agent Substrate's control plane, from the holos-run fork
(interview Q23, Q26 and Q27; [docs/forks.md](../docs/forks.md)). The fork is
vendored as a git submodule at `vendor/substrate`, checked out at the pin,
and the component renders upstream's own install tree from it, the files
`go run ./cmd/ate-setup deploy ate-system` would apply. `Substrate`
(`substrate.cue`) holds the fork's commit, every image's digest on
`ghcr.io/holos-run/substrate`, and the names other components dial;
`Kagent` (`kagent.cue`) holds the kagent controller's identity, which
Substrate trusts before kagent is installed. ate-setup needs a cluster to
render, so it is read, not run: `components/substrate/ATE-SETUP.md` maps
every step of its `deploy ate-system` to a stage here or to a step by hand
below, and is re-read on every bump.

A clone renders only with the submodule checked out
(`git submodule update --init holos/vendor/substrate` from the repository's
root, once); without it `kubectl kustomize` finds no files and the render
fails. The render reads nothing from the network.

The component is a pipeline, one artifact of four stages:

1. **Input.** A `Command` generator runs `kubectl kustomize
   --load-restrictor LoadRestrictionsNone` on
   `components/substrate/upstream/kustomization.yaml`, which lists
   `manifests/ate-install/base` and the files ate-setup applies on their
   own: the three CRDs and the controller's RBAC, the pod certificate
   controller, the SandboxConfig admission policy and `gvisor-default`, the
   egress gateway, and the Kubernetes Secrets credential provider and its
   namespace policy. It also makes ConfigMap `substrate-db-setup` from
   `pkg/postgressetup/setup.sql`. Upstream's bundled PostgreSQL is not
   listed.
2. **CUE.** A `Resources` generator makes what ate-setup creates
   imperatively, and the platform's additions (below).
3. **Patches.** A `Kustomize` transformer reproduces ate-setup's render: the
   router's allowed SPIFFE IDs, the IdP's issuer, the API server's bootstrap
   owners and config hash, the egress gateway's credential provider flags,
   which ate-setup splices over a YAML comment kustomize drops, the Envoy
   image in place of `${ENVOY_DATAPLANE_IMAGE}`, the GKE image credential
   provider removed from atelet, the private root added to its trust, the
   GKE PodMonitoring, the bundled database's NetworkPolicy and the
   credential provider's cluster-wide Secret reader binding dropped, the
   object store plugin on S3, `ate-system` privileged, and both namespaces
   `Delete=false`. Every container
   patch tests the container's name at its index first, so a reordered
   upstream manifest fails the render rather than patching the wrong
   container. Its `images` field rewrites every
   `ko://go.ate.dev/substrate/cmd/<path>` to
   `ghcr.io/holos-run/substrate/<name>@<digest>`.
4. **Slice.** `holos kubectl-slice` writes one file per resource.

Two validators fail the render if the submodule is not at
`Substrate.commit`, or if a `ko://` image, a `${...}` image placeholder, the GKE
collector address, a PodMonitoring or a `gcs` storage backend survives.

What it runs, in `ate-system` unless named:

- **The control plane.** The API server (two replicas), the IdP (two), the
  controller, the Envoy router, the egress gateway, the credential
  provider, and atelet on every worker; the pod certificate controller in
  `podcertificate-controller-system`, which publishes the three
  ClusterTrustBundles every Substrate pod projects. Every image is pulled
  anonymously from `ghcr.io/holos-run/substrate` by digest; no
  ServiceAccount has a pull secret. Substrate registers no admission
  webhook, only the CEL ValidatingAdmissionPolicy `sandboxconfig-assets`.
- **The namespace.** `ate-system` is privileged, since atelet mounts host
  paths under `/var` and `/dev`, and stays out of the mesh: Substrate runs
  its own mutual TLS on pod certificates, and upstream's default-deny
  NetworkPolicies hold at the application ports. It and
  `podcertificate-controller-system` carry
  `argocd.argoproj.io/sync-options: Delete=false`: they hold the key pools,
  which are not in git, and the database, so deleting the Application or
  pruning the namespace never takes them.
- **Its configuration.** `ate-api-authentication` trusts the cluster's
  ServiceAccount tokens for audience `api.ate-system.svc`, with the issuer
  from `Cluster.serviceAccountIssuer` (`https://10.20.0.50:6443` on
  treasury, the control plane endpoint, as the discovery document gives
  it) and the pod's own CA and token files, since Talos answers anonymous
  discovery with a 401. `ate-api-config` sets the log level `info`.
  `ate-api-server-envvars` has the roles, the actor JWT issuer
  `https://idp.ate-system.svc` and the snapshot location `s3://substrate/`.
  `ate-otel-config` sets every exporter to `none` and logs to `console`:
  there is no collector. Each workload's pod template carries
  `holos.run/config-hash`, a short digest of what it reads of these: the API
  server's of its four ConfigMaps, the connection strings' template and the
  OpenTelemetry settings; ate-controller's, atelet's, the router's and the
  egress gateway's of the OpenTelemetry settings; the credential provider's
  of its namespace policy. A change in git to any of them rolls its readers.
  It does not cover the generated passwords, nor the router's and the egress
  gateway's Envoy ConfigMaps, which come from upstream's tree (Bumping the
  pin, below).
- **The database.** CloudNativePG `Cluster` `substrate-db`, which kagent
  shares with roles and a schema of its own: one instance, 10Gi on
  `ceph-rbd`, PostgreSQL 18.6 pinned by image, `enablePDB: false`,
  `Prune=false,Delete=false`, superuser access on with the generated
  `substrate-db-superuser` (username `postgres`), and `initdb` making
  database `substrate` owned by `substrate`, a login nothing uses. Its
  serving certificate is `Certificate` `substrate-db-server` from the
  `private-ca` ClusterIssuer, so clients verify it against the private root
  every namespace has, which lasts as long as the cluster; CloudNativePG's
  own CA would be renewed every three months under clients that load it
  once. The API server mounts the `private-ca` ConfigMap where upstream
  mounts Secret `postgres-server-ca`.
- **Its roles.** Job `substrate-db-setup` runs upstream's `setup.sql` with
  psql as the superuser, in one transaction, with the role names, schema
  and passwords as psql variables, as ate-setup does for its bundled
  database: roles `substrate_owner` and `substrate_readwrite`, login users
  `substrate_owner_user` and `substrate_readwrite_user` with the passwords
  in the generated `substrate-db-users`, and schema `substrate`. Every
  statement converges, so it is an Argo CD `Sync` hook, run on every sync
  and deleted once it succeeds; not `PostSync`, which waits for the API
  server to be Healthy, which it cannot be without its roles. It waits for
  the database itself. The API server runs its migrations through the
  owner's connection.
- **The connection strings.** `ExternalSecret`
  `ate-api-server-secret-envvars` templates both DSNs and the schema from
  `substrate-db-users`, through `SecretStore` `substrate-db-users`
  (`#ScopedSecretStore` with `source: "ate-system"`), `sslmode=verify-full`
  against the private root. It follows its source within the hour.
- **Snapshots.** In RustFS's bucket `substrate`, at
  `rustfs-svc.rustfs.svc:9000`, path-style, region `us-east-1`, plain HTTP:
  `rustfs` is in the mesh and `ate-system` is not, so ztunnel takes the
  connection in plaintext. Both object store plugin sidecars, the API
  server's and atelet's, read the keys from `rustfs-substrate`, copied from
  `rustfs` by `SecretStore` `rustfs`.
- **The router.** Mutual TLS on 8443 (Service `atenet-router:443`), which
  accepts a client certificate from the pod identity signer whose SPIFFE ID
  is on `--ingress-allowed-spiffe-ids`, exactly: the Substrate shim's
  gateway's, `AteGateway.spiffeID`
  (`spiffe://cluster.local/ns/substrate-shim/sa/ate-gateway`), and kagent's
  controller's, `Kagent.controller.spiffeID`. The shared `ingress` gateway is
  not on the list. A client with no
  certificate, or one not on the list, fails the handshake. The router
  strips `ate-target-actor` before the actor sees the request.
- **Owners.** The API server's bootstrap owners are the `ate-client` ksa,
  the Kubernetes service account `ate-system/ate-client`
  (`system:serviceaccount:ate-system:ate-client`), and kagent's controller.
  The ate-client ksa token is a standard Kubernetes service account token
  for that ksa, with the audience `api.ate-system.svc`; it is what `kubectl
  ate` authenticates with when it is given no `--token-file`. Anyone who can
  mint an ate-client ksa token, which takes `create` on
  `serviceaccounts/token` in `ate-system`, is a global owner of Substrate:
  only cluster admins, from the laptop. To mint one for `--token-file`:

  ```sh
  export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
  kubectl -n ate-system create token ate-client --duration=1h --audience=api.ate-system.svc > ate-client.token
  ```

  A token with any other audience is refused with `invalid bearer token`.
  The [glossary](../docs/glossary.md) defines these terms.
- **Egress.** The egress gateway's ext-proc names the bundled provider,
  `k8s.io` at `k8s-credential-provider.ate-system.svc:50051`, whose
  namespace policy, in git, lets atespace `kagent` resolve Secrets in
  namespace `kagent`, and no other atespace any. Upstream binds the
  provider's Secret reader ClusterRole cluster wide, so it could read every
  Secret in the cluster; the component drops that ClusterRoleBinding and
  keeps the ClusterRole. Each namespace in the policy's `allowedNamespaces`
  gets a RoleBinding of that ClusterRole to ServiceAccount
  `ate-system/k8s-credential-provider`, rendered by the component that owns
  the namespace (`kagent` for `kagent`), so the provider reads Secrets only
  where an atespace may resolve them.
- **The worker pool.** `WorkerPool` `gvisor` in the privileged namespace
  `ate-workers`: three workers of `ateworker-gvisor` by digest, on the
  nodes labeled `holos.run/nodepool: general`, with the class default
  `gvisor-default`, whose gVisor build atelet fetches from `gs://gvisor`
  anonymously. It carries `kagent.dev/worker-pool-namespace: kagent` and
  `kagent.dev/worker-pool-name: gvisor`, which kagent's generated
  ActorTemplates select on. ate-controller creates its ServiceAccount,
  `ateworker`.

#### Bringing Substrate up

Three things have no declarative form and are done by hand, in this order. A
cluster that does not name `substrate` skips all three (Adding a cluster,
above).

**The key pools**, once per cluster, after Argo CD has synced the
namespaces. They are the root of every pod identity, actor token and MITM
certificate: ate-setup creates them as Secrets that Argo CD does not track,
so it never prunes them, and that never pass through the Secrets Manager.
Until they exist the pods that project them wait in ContainerCreating and
the Application is Progressing, and `Degraded` once its Deployments pass
their ten-minute progress deadline; the kubelet retries within about two
minutes of their creation. Each command creates only what is missing, so a
second run changes nothing. ate-setup uses `KUBECONFIG`'s current context
(`--context` to choose), and `go run` builds it, about a minute the first
time.

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl get ns ate-system podcertificate-controller-system   # synced
cd holos/vendor/substrate                                    # from the repository's root
go run ./cmd/ate-setup create podcertificate-controller-cas  # service-dns-, pod-identity-, postgres-ca-pool
go run ./cmd/ate-setup create jwt-authority-pool             # actor-id-jwt-pool
go run ./cmd/ate-setup create actor-id-ca-pool
go run ./cmd/ate-setup create actor-id-ca-certs              # from actor-id-ca-pool, so after it
go run ./cmd/ate-setup create egress-mitm-ca-pool
kubectl get clustertrustbundles -l podcert.ate.dev/canarying=live   # podidentity, postgres, servicedns
kubectl -n ate-system rollout status deploy/ate-api-server
```

**The demo atespace** and **its actors**, through the API with `kubectl
ate`, built from the same commit. Atespaces, actor templates and actors are
API objects in Substrate's database, not Kubernetes resources. `kubectl
ate` port-forwards to Service `api` and, without `--token-file`, mints an
ate-client ksa token itself (Owners, above). The demo has two templates, `echo` and `other`,
which differ only in `WHOAMI_NAME`, and an actor of each: the router strips
`ate-target-actor` and an actor has no variable naming it, so each answers
with its template's name, as `Name:`, above the request headers it
received. Templates are immutable; to change one, delete and re-create it.

The image is `traefik/whoami` v1.12.0, copied by digest into the public
`demo/echo` repository in Quay, which keeps the digest, so a rebuilt Quay
is refilled with the same pin. atelet pulls actor images itself, with
go-containerregistry, not through containerd, so the workers' Talos trust
store does not reach it: the component mounts the namespace's `private-ca`
ConfigMap into atelet at `/etc/ssl/private-ca` and sets `SSL_CERT_DIR` to
`/etc/ssl/certs:/etc/ssl/private-ca`, as argocd-server and the platform controller
do, which keeps the image's public roots. Go reads them once, at start, so
after a rebuild with a new root, restart atelet
(`kubectl -n ate-system rollout restart ds/atelet`).

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
go build -o ~/bin/kubectl-ate ./cmd/kubectl-ate   # from holos/vendor/substrate; ~/bin on PATH
kubectl ate create atespace demo

# Into Quay, with the controller's token. buildx copies from the client, so
# neither the daemon nor docker login is involved: the credential goes
# straight into a throwaway config, and the cluster's root is trusted through
# SSL_CERT_DIR.
digest=sha256:c4717a8d1f0134a7444e24f881160e033991f23027c6c5a9a3f8fd22e70d1d44
export DOCKER_CONFIG=$(mktemp -d)
kubectl -n default get configmap private-ca -o jsonpath='{.data.ca\.crt}' > $DOCKER_CONFIG/root.pem
tok=$(kubectl -n seabank-prj-platform get secret quay-controller-token -o jsonpath='{.data.token}' | base64 -d)
printf '{"auths":{"%s":{"auth":"%s"}}}' "quay.$domain" \
  "$(printf '%s' "\$oauthtoken:$tok" | base64 -w0)" > $DOCKER_CONFIG/config.json
unset tok
SSL_CERT_DIR=$DOCKER_CONFIG docker buildx imagetools create \
  -t quay.$domain/demo/echo:v1.12.0 docker.io/traefik/whoami:v1.12.0@$digest
rm -rf $DOCKER_CONFIG; unset DOCKER_CONFIG

image=quay.$domain/demo/echo@$digest
for a in echo other; do
  kubectl ate create actor-template -f - <<EOF
metadata: {atespace: demo, name: $a}
containers:
- name: whoami
  image: $image
  env: [{name: WHOAMI_NAME, value: $a}]
  wakeupProbe: {httpGet: {path: /health, port: 80}}
resources:
  limits: {cpuMillicores: 250, memoryBytes: 134217728}
EOF
done
kubectl ate get actor-templates -a demo   # a GOLDEN TAG for each, within a minute
for a in echo other; do kubectl ate create actor $a -a demo --template $a; done
kubectl ate get actors -a demo            # both SUSPENDED until a request wakes them
```

#### Bumping the pin

A new pin is a fork commit whose images `publish-images.yaml` has published to ghcr.io
([docs/forks.md](../docs/forks.md)). From `holos/`:

```sh
git -C vendor/substrate fetch origin
git -C vendor/substrate checkout <commit>
# substrate.cue: commit, version, and every digest from the publish run's references
# components/substrate/ATE-SETUP.md: walk steps/deploy.go again, change what moved,
# then the line numbers and the pin at its top
cue vet ./... && rm -rf deploy/clusters && holos render platform
git diff deploy/clusters/*/components/substrate   # what the bump changes, on every cluster that takes it
git add vendor/substrate substrate.cue components/substrate deploy
```

A kagent bump goes with it, since kagent's replace names the Substrate
pin ([docs/forks.md](../docs/forks.md), Rebasing on upstream):

```sh
# kagent.cue: commit, version, the two chart digests and the two image digests,
# and upstream.release with the harness and guest images, from that release's chart
# components/kagent/setup.sql: re-copy go/core/pkg/postgressetup/setup.sql if it changed
rm -rf components/kagent/vendor components/kagent-crds/vendor   # the render pulls both charts at Kagent.version
cue vet ./... && rm -rf deploy/clusters && holos render platform
git diff deploy/clusters/*/components/kagent deploy/clusters/*/components/kagent-crds
git add kagent.cue components/kagent components/kagent-crds deploy
```

If the bump's diff changes ConfigMap `atenet-router-envoy-config` or
`atenet-egress`, the Envoy bootstrap upstream ships, restart their readers
once Argo CD has synced it, since no hash covers them:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n ate-system rollout restart deploy/atenet-router deploy/atenet-egress
```

Test the bump on `$cluster` before it merges with automation paused on the
root `argocd-apps` **and** on `substrate`, `kagent-crds` and `kagent`, and
keep the root paused until the merge: the root renders the children's
`syncPolicy`, so restoring it alone re-applies `automated` to the three and
`selfHeal` puts the old pins back within a poll. Apply the three renders
server-side as `argocd-controller` with Argo CD's tracking-id annotations,
then restore all four after the merge. Substrate's skew policy
(`docs/reference/version-skew-policy.md`) fixes the order within its render,
which one Argo CD sync does not keep: the pod certificate controller, then
`ds/atelet` and its rollout, then `WorkerPool` `gvisor` and its workers, then
ate-controller and everything else, and `kagent-crds` and `kagent` after that.
A worker must not be newer than its node's atelet, and ate-api-server not
newer than any worker. The two role Jobs are Sync hooks, so a hand apply leaves
them out and they run at the first sync after the merge. While it is paused,
each Application reads `OutOfSync`. One whose last sync operation failed reads
`Degraded` as well, and the root with it, however long ago that failure was:
`kagent`'s stale one did this on the 2026-11-06 bump, from the moment the
placeholder `WorkerPool` moved. It clears with that Application's next
successful sync.

The workers roll twice when a bump changes their pod template: once on the
image, and again when ate-controller is upgraded, since ate-controller renders
the template. The 2026-11-06 bump does, with new capability sets (upstream
#2428), so the pools, `kagent/gvisor` included, move to the new image before
ate-controller. Anything that checks a worker or touches an actor waits for the
second roll. `rollout status` says done until ate-controller reaches the pool,
so read the pods. A gVisor worker then lists 9 capabilities, with no `MKNOD`,
`SETPCAP`, `SYS_CHROOT` or `SYS_PTRACE`:

```sh
kubectl -n ate-workers get pod <worker> \
  -o jsonpath='{.spec.containers[0].securityContext.capabilities.add}'
```

A Substrate bump rolls every worker, and an actor whose worker goes away is
`ACTOR_STATE_CRASHED`, which the router does not resume. On a bump that keeps
old snapshots restorable, `kubectl ate revert actor <name> -a <atespace>` puts
it back to its latest snapshot, suspended, and the next request resumes it, so
suspend what matters first.

A bump can break that, which its upstream `Breaking change` notes say. The
2026-11-06 bump does: upstream #3533 and #3457 change a gVisor sandbox's mounts,
so a MEMORY snapshot taken before them, a golden included, does not restore.
`runsc restore` fails, the actor goes `CRASHED`, and no API restores such a
snapshot without its memory. So `revert actor` only returns to the same
snapshot, suspending first only writes another, and a new actor from an old
template restores the old golden and crashes. Recut instead, after the last
worker roll: delete the actors and their templates, re-create the templates,
wait for each one's golden, and re-create the actors. Whatever an actor held
is lost. Moving back to `holos-2026-10-30` needs the same recut, since a
snapshot taken on the new workers does not restore on the old ones. For the
demo actors, which Substrate, above, then re-creates:

```sh
for a in echo other; do
  kubectl ate delete actor $a -a demo
  kubectl ate delete actor-template $a -a demo
done
```

atelet keeps an image cache under `/var/lib/ate/image-cache` on each node
with a layout version, and refuses to start on an older layout ("image
cache ... has layout version "2" and this atelet supports "3", so delete it
once no actor runs on this node"). The 2026-10-30 bump moved it from 2 to
3 (upstream #2392), and the 2026-11-06 bump left it there. When it moves, the
DaemonSet stalls, one node at a time, on a crash-looping atelet. On each such
node, with no actor running there,
delete the directory from a privileged pod with the host path mounted and
delete the atelet pod; atelet re-creates the cache and pulls what it needs:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n ate-system apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: cache-reset, namespace: ate-system}
spec:
  nodeName: <node>
  restartPolicy: Never
  containers:
  - name: rm
    image: curlimages/curl:8.14.1
    securityContext: {privileged: true, runAsUser: 0}
    command: [sh, -c, 'cat /host/image-cache/version; rm -rf /host/image-cache && echo deleted']
    volumeMounts: [{name: ate, mountPath: /host}]
  volumes: [{name: ate, hostPath: {path: /var/lib/ate, type: Directory}}]
EOF
kubectl -n ate-system wait pod/cache-reset --for=jsonpath='{.status.phase}'=Succeeded
kubectl -n ate-system logs cache-reset && kubectl -n ate-system delete pod cache-reset
kubectl -n ate-system delete pod -l app=atelet --field-selector spec.nodeName=<node>
```

The render refuses a `Substrate.commit` that is not the submodule's, and a
`ko://` image the `images` field does not know, which is what a new
component in upstream's tree looks like: add its name and digest. A new
flag ate-setup appends, a new file it applies on its own or a new
ConfigMap key does not fail the render; only the re-read finds it. A
schema change is migrated by ate-api-server on start, through the owner's
connection.

kagent's schema is not always. A new file under
`go/core/pkg/migrations/core/` is migrated by the controller on start, as
`000002_runtime_bootstrap.sql` is on the 2026-11-06 bump, but kagent has also
changed `000001_initial.sql` in place: the 2026-10-30 bump added four columns
to `runtime_revision` there (`actor_template_spec_digest`, `golden_retries`,
`golden_failure_uid`, `golden_failed_at`). A schema migrated by the old
controller is at version 1 already, so the new controller runs nothing and
the columns stay missing. Compare the fork's `000001_initial.sql` with the old
pin's on every kagent bump; when it changed, drop and re-create the
`kagent` schema and sync `kagent`: the `kagent-db-setup` Job, a Sync hook,
re-creates the roles and the schema (every statement converges), and the
controller migrates on start. Every session, memory and revision kagent
holds in the schema is lost; the `Agent`, `Harness` and `ModelConfig`
objects in `kagent` are not, and the controller reconciles them again.

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n ate-system exec substrate-db-1 -c postgres -- psql -d substrate \
  -c 'drop schema kagent cascade'
argocd app sync kagent
```

The old controller keeps running until the sync rolls it; a pod of it
started between the drop and the sync fails on the missing schema and is
restarted.

#### Rotation

- **The database passwords**, `substrate-db-users`. Rotate the Secret as
  any generated one (External Secrets, above); only the role Job's pods
  name it, and they are gone once it succeeds. Then sync `substrate`
  (`argocd app sync substrate`): the ExternalSecret Argo CD re-creates
  generates new passwords, and the role Job, a Sync hook, sets them with
  `ALTER ROLE`; until then the API server keeps the connections it has.
  Force the connection strings to follow with `kubectl -n ate-system
  annotate externalsecret ate-api-server-secret-envvars
  force-sync=$(date +%s) --overwrite`, then roll the API server, which
  reads them at start: `kubectl -n ate-system rollout restart
  deploy/ate-api-server`. New connections fail between the sync and the
  restart.
- **The superuser and the initdb owner**, `substrate-db-superuser` and
  `substrate-db`: as `keycloak-db` (Keycloak, above). The instance manager
  sets the new password when the Secret changes. Only the role Job uses the
  superuser, and nothing uses the owner.
- **The key pools**: not yet; their rotation is
  Holos_Distro/substrate-bank-hardening. Deleting one makes every
  certificate or token it issued unverifiable.

None of these has been exercised on a cluster yet.

#### Checking Substrate

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
# 1. Running, migrated, its database and secrets in place.
kubectl -n ate-system get pods,cluster.postgresql.cnpg.io   # every pod Running; substrate-db healthy
kubectl -n ate-system get externalsecret,secretstore        # every one SecretSynced, every store Valid
kubectl -n podcertificate-controller-system get pods
kubectl get clustertrustbundles -l podcert.ate.dev/canarying=live
    # podidentity, postgres and servicedns from the pod certificate controller,
    # and egress-mitm from ate-controller once the MITM pool exists
kubectl -n ate-system logs deploy/ate-api-server -c ate-api-server | grep -m1 'migrations ready'
kubectl -n ate-workers get workerpool,pods                  # gvisor 3/3, RESOLVED True

# 2. The router: refused without a certificate, and each actor answering an
#    allowed client by name. The client is a pod with the shim gateway's
#    identity and a pod certificate of its own, deleted afterwards.
kubectl -n substrate-shim apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: router-test}
spec:
  serviceAccountName: ate-gateway
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 100, runAsGroup: 101, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: curl
    image: docker.io/curlimages/curl:8.11.1
    command: [sleep, "600"]
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    volumeMounts: [{name: router-client, mountPath: /run/router-client, readOnly: true}]
  volumes:
  - name: router-client
    projected:
      sources:
      - podCertificate: {signerName: podidentity.podcert.ate.dev/identity, keyType: ECDSAP256, credentialBundlePath: credential-bundle.pem}
      - clusterTrustBundle:
          signerName: servicedns.podcert.ate.dev/identity
          labelSelector: {matchLabels: {podcert.ate.dev/canarying: live}}
          path: router-ca.pem
EOF
kubectl -n substrate-shim wait --for=condition=Ready pod/router-test
c='--cacert /run/router-client/router-ca.pem'
id='--cert /run/router-client/credential-bundle.pem --key /run/router-client/credential-bundle.pem'
kubectl -n substrate-shim exec router-test -- sh -c "curl -sS $c https://atenet-router.ate-system.svc/"
                                                   # alert certificate required
for a in echo other; do
  kubectl -n substrate-shim exec router-test -- sh -c \
    "curl -sS $c $id -H 'ate-target-actor: demo/$a' https://atenet-router.ate-system.svc/" | head -1
done                                               # Name: echo, then Name: other
kubectl ate get actors -a demo                     # both RUNNING
kubectl -n substrate-shim delete pod router-test

# 3. A durable snapshot in RustFS.
kubectl ate suspend actor echo -a demo --mode sync
kubectl ate get actor echo -a demo -o yaml | grep -A1 'snapshotUri: s3://substrate/atespaces/demo/actors'
                                                   # state: SNAPSHOT_STORAGE_STATE_COMPLETED

# 4. A clean render reproduces deploy/ (Render, below).
```

The same pod under ServiceAccount `default` fails the handshake with
`alert certificate unknown`. On a new cluster Argo CD reports the
`substrate` Application Progressing until the key pools exist, and
`Degraded` if they still do not after ten minutes.

### The Substrate shim

`substrate-shim` is how a person reaches an actor: at
`https://<actor>.<atespace>.ate.treasury.bank.internal`, with a Keycloak ID
token (interview Q7 to Q9). It is plain Istio, with no controller of its own.
`AteGateway` (`components/substrate-shim.cue`) names it, and the substrate
component reads the same definition for the router's allowed list.

- **Its own Gateway.** A `RequestAuthentication` applies to every request
  its gateway sees, and refuses a bearer JWT from an issuer it does not know
  with 401 `Jwt issuer is not configured`. On `ingress` that would break
  `docker pull` from Quay, whose registry tokens are Quay's JWTs, and the
  argocd CLI. So the shim is the `Gateway` `substrate-shim/ate`, class
  `istio`, annotated `networking.istio.io/service-type: ClusterIP`: istiod
  gives it the Service `ate-istio` and no address. `ingress`'s `ate`
  listener passes every `*.ate.treasury.bank.internal` connection through to
  that Service, by SNI, with the `TLSRoute` `substrate-shim/ate` (The ingress
  gateway, above). There is no new address and no DNS change: the private
  zone's `*.treasury.bank.internal` already resolves the hosts to 10.20.0.30.
  Two replicas, preferably on two nodes, as `ingress` has.
- **Listeners.** One per atespace, named after it, for
  `*.<atespace>.ate.treasury.bank.internal`, terminating TLS with the
  `Certificate` `<atespace>-wildcard` from the `private-ca` ClusterIssuer:
  `demo` and `kagent` today. Each admits only `HTTPRoute`s from `ate-system`,
  where `ate-<atespace>` routes to the router's Service on 443. Being in the
  router's namespace, those routes need no `ReferenceGrant`, and no
  `ReferenceGrant` into `ate-system` exists, so no other route can reach the
  router through the gateway. A host under an atespace with no listener,
  such as `foo.nope.ate.treasury.bank.internal`, matches no filter chain and the
  connection is reset during the TLS handshake (curl exits 35). The Gateway
  sets `allowedListeners` to its own namespace, so a `ListenerSet` there can
  add an atespace, as each ProjectClaim does (Adding an atespace, below).
- **Authentication.** `RequestAuthentication` `keycloak` accepts an ID token
  from the realm's issuer for the `kubectl` client (ADR 0002), the token
  `kubectl oidc-login get-token` prints; any other bearer token gets 401.
  `forwardOriginalToken` is false, so Envoy removes the `Authorization`
  header once the token is verified and the actor never holds it. A request
  with no token passes this step.
- **Authorization.** `AuthorizationPolicy` `ate` allows a request only if
  the host is under an atespace with a rule, a token from the realm was
  verified, and the token's `groups` claim holds one of the atespace's
  `groups` (`AteGateway.atespaces`), `/platform/owners` for both today
  (`Keycloak.groups.owners`). A claimed atespace has an `AuthorizationPolicy`
  `project-<name>` of its own, with the same rule, and a request is allowed
  if any `ALLOW` policy on the Gateway allows it. Istio matches `hosts` as a
  plain suffix of `:authority`, so each rule lists the host with and without
  `:443`, for a client that puts the port in `Host`. Everything else, a
  request with no token included, gets 403 `RBAC: access denied`.
- **The actor.** `TrafficExtension` `ate-target-actor` is a few lines of
  Lua. It splits the host, `<actor>.<atespace>.ate.treasury.bank.internal`, and
  replaces `ate-target-actor` with `<atespace>/<actor>`, which drops any
  value the client sent. It has no phase, so istiod puts it after
  `jwt_authn` and `rbac` in the filter chain, and a refused request never
  gets the header. A host of any other shape, such as
  `a.echo.demo.ate.treasury.bank.internal`, gets 400. The router strips the
  header before the actor sees the request, so the proof of routing is which
  actor answers.
- **Mutual TLS to the router.** `DestinationRule` `atenet-router` in
  `substrate-shim`, exported to that namespace only, originates mutual TLS
  to `atenet-router.ate-system.svc.cluster.local`. The client certificate is
  a pod certificate from `podidentity.podcert.ate.dev/identity`, which the
  `ate-gateway` ConfigMap (the Gateway's `parametersRef`) projects into the
  `istio-proxy` container with `keyPath` and `certificateChainPath`, since
  the DestinationRule takes the key and the chain as two files. The router's
  serving certificate is checked against the servicedns signer's live
  ClusterTrustBundles, projected beside it, for the name
  `atenet-router.ate-system.svc`, which is also the SNI. The certificate
  carries `spiffe://cluster.local/ns/substrate-shim/sa/ate-gateway`, the
  `AteGateway.spiffeID` the router's allowed list is rendered from, for the
  ServiceAccount the Gateway's `gateway.istio.io/service-account` annotation
  names. Every replica gets its own key and certificate. The gateway's pods
  start only once the pod identity signer issues, so on a new cluster they
  wait for Substrate's key pools (Bringing Substrate up, above).
- **The namespace.** `substrate-shim` is not in ambient: the gateway is its
  own proxy, and the router is outside the mesh.
- **Client addresses.** `ingress` passes the connection through, so the
  shim, and the actor in `X-Forwarded-For`, see the `ingress` pod's address,
  not the client's.

#### Reaching an actor

From a machine that trusts the private root (The private CA, above), as a
member of `/platform/owners`. kubelogin prints the `kubectl` client's ID
token, which lasts five minutes:

```sh
TOKEN=$(kubectl oidc-login get-token --oidc-issuer-url=https://keycloak.$domain/realms/default \
  --oidc-client-id=kubectl --grant-type=device-code | jq -r .status.token)
curl https://echo.demo.ate.$domain/                                       # 403 RBAC: access denied
curl -H "Authorization: Bearer $TOKEN" https://echo.demo.ate.$domain/     # Name: echo
curl -H "Authorization: Bearer $TOKEN" https://other.demo.ate.$domain/    # Name: other
```

The actor wakes on the request, if it was suspended, before it answers.

#### Adding an atespace

1. Create the atespace in Substrate with `kubectl ate create atespace
   <name>`, as for `demo` (Substrate, above). Its name is a DNS label, the
   hosts' second label and the listener's name.
2. Add it to `AteGateway.atespaces` in `components/substrate-shim.cue`, with
   the groups, by full path, that may reach its actors:
   `<name>: groups: ["/<group path>"]`.
3. Render and commit. The sync adds its `Certificate`, its listener, its
   `HTTPRoute` and its `AuthorizationPolicy` rule. Neither the router's
   allowed list nor DNS changes.

A project's atespace takes none of these steps: its claim makes the atespace
and brings the shim's half with it, in the claim's own `Application` (Projects,
below). Between `Application`s that already exist, a broken claim holds back
only its own. A root sync, as at a bootstrap, walks the waves, and waits on a
broken claim as on any component, so it holds back the ones after it. In
`substrate-shim` that half is the `ListenerSet` `project-<name>`, which the
Gateway's `allowedListeners` admits, the `Certificate` `<name>-wildcard` and
the `AuthorizationPolicy` `project-<name>`; in `ate-system`, the `HTTPRoute`
`ate-<name>`, whose parent is the `ListenerSet`. The certificate has its own
`CertificateRequestPolicy` `project-<name>` (Approval, in The private CA,
above). The listener, the certificate and the rule are the same as a listed
atespace's, from `AteGateway.#Atespace`, and `AteGateway.claimed` lists them.
A claim may not take the name of an atespace listed in `AteGateway.atespaces`
(`Projects.reserved`).

#### Rotation

- **The gateway's client certificate** is a pod certificate, valid for 24
  hours, the signer's default, since `maxExpirationSeconds` is unset. The
  kubelet renews it before it expires and rewrites the two files; Istio's
  agent watches the files a DestinationRule names and hands Envoy the new
  pair. This has not been observed yet. To observe it, set
  `maxExpirationSeconds: 3600`, the minimum, on the `podCertificate` in the
  `ate-gateway` ConfigMap, which rolls the gateway, and repeat a request
  after an hour.
- **The router's trust bundle** is the servicedns signer's live
  ClusterTrustBundles, which the kubelet keeps current in the projected
  file. Rotating the key pools themselves is
  Holos_Distro/substrate-bank-hardening.
- **The wildcards** are renewed by cert-manager, and istiod hands them to the
  gateway as they change.
- **Keycloak's signing keys**: istiod fetches the realm's JWKS itself, with
  the private root (Istio, above), and refreshes it periodically, so a new
  realm key is picked up without a restart; a new private root needs an
  istiod restart.

#### Checking the shim

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n substrate-shim get gateway,listenerset,certificate,pods -o wide
    # ate PROGRAMMED True; a ListenerSet per claim, ACCEPTED and PROGRAMMED True;
    # every wildcard Ready; two ate-istio pods on two nodes
kubectl -n istio-ingress get gateway ingress \
  -o jsonpath='{range .status.listeners[*]}{.name} {.attachedRoutes}{"\n"}{end}'   # ate 1
# With $TOKEN as above:
curl -H "Authorization: Bearer $TOKEN" -H 'ate-target-actor: demo/other' \
  https://echo.demo.ate.$domain/ | head -1                     # still Name: echo
curl https://foo.nope.ate.$domain/                             # exit 35, no listener
# A token for a user outside the atespace's groups, such as
# svc-quay-controller, gets 403. The router refuses any other identity:
# Checking Substrate, above, step 2, under ServiceAccount default.
docker pull quay.$domain/demo/echo@sha256:c4717a8d1f0134a7444e24f881160e033991f23027c6c5a9a3f8fd22e70d1d44
    # ingress still passes Quay's own bearer tokens
```

A 401 with `Jwt verification fails` for a token that `k8s.$domain`
accepts means istiod holds no signing key for the realm. istiod fetches the
JWKS when it starts, and if Keycloak does not answer then, it keeps a key
that matches nothing until its next refresh, 20 minutes later by default
(`PILOT_JWT_PUB_KEY_REFRESH_INTERVAL`). Its log says `JWKS fetch failed for
issuer`. A bootstrap meets this when `talosvm restart` moves istiod while
Keycloak is down. On treasury's rebuild of 2026-11-02 the shim answered
again 20 minutes after the failed fetch, with no restart. To skip the wait,
restart istiod once Keycloak answers:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n istio-system logs deploy/istiod | grep 'JWKS fetch failed' | tail -1
kubectl -n istio-system rollout restart deploy/istiod
```

### kagent

kagent runs agents as Substrate actors (interview Q26), from the holos-run
fork ([docs/forks.md](../docs/forks.md)), at
`https://kagent.treasury.bank.internal` behind a Keycloak login. `Kagent`
(`kagent.cue`, and `components/kagent.cue` for the names that need the Gateway
or Keycloak) holds the pins and the names, and the substrate component reads
the same definition for the router's allowed list, the bootstrap owners and
the credential provider's namespace policy. Two components: `kagent-crds`, the
CRD chart, and `kagent`, the main chart with the CUE-made objects beside it.

- **Pins.** The charts and the controller and UI images are the fork's, on
  `ghcr.io/holos-run/kagent`, by digest. The fork builds nothing else, so
  `config.harnessImages` (`kagent`, `claude`, `codex`) and
  `config.sandboxes.guestImage` are upstream kagent-dev's
  `v1.0.0-rc3`, the release the fork is cut from: the harnesses by
  the index digests that release's chart lists in
  `files/builtin-harness-images.json`, and the guest, which that file does
  not list, by the index digest of its `sandbox-guest:1.0.0-rc3` tag.
  The catalog's fourth key, `release`, stays unset: the controller refuses to
  start when it is set and differs from its own version, which is the
  fork's tag. The tool server and oauth2-proxy images are the subcharts'
  defaults, by digest.
- **Substrate.** `controller.substrateClientCertificate` mounts the pod
  identity certificate and the servicedns trust bundle; the controller dials
  `api.ate-system.svc:443` and `https://atenet-router.ate-system.svc:443`
  with them, and the router admits it by
  `spiffe://cluster.local/ns/kagent/sa/kagent-controller`. The namespace
  carries `ate.dev/api-access: "true"`, which the API server's NetworkPolicy
  admits. kagent creates its atespace, `kagent`, itself, on its first agent
  or sandbox, and writes each actor's egress policy itself, through the API,
  from the agent's model and `EgressPolicy` references: the model's origin
  with its key as an `ate-secret://k8s.io/default/kagent/<secret>/<key>`
  reference, and the controller's URL with an actor JWT. The platform writes
  no egress policy. The credential provider resolves the reference through
  the `Role` `k8s-credential-provider-model-keys` here, which lets it get
  `kagent-anthropic` by name and no other Secret: a ModelConfig names its
  key Secret and may name its own base URL, so with the whole namespace an
  agent's author could have the egress gateway send the OIDC client secret
  or a database password to a server of theirs. A model key added through
  the UI, or any other, must be added to `modelKeys` in
  `components/kagent/kagent.cue` before an agent can use it.
- **The database.** kagent shares `substrate-db`, with its own schema
  `kagent`, roles `kagent_owner` and `kagent_readwrite` and logins
  `kagent_owner_user` and `kagent_readwrite_user`. The `kagent-db-setup`
  Job, a Sync hook in `ate-system` beside Substrate's own, runs kagent's
  `setup.sql`, copied from the fork into `components/kagent/`, as the
  superuser. The two passwords are generated once in `ate-system`, as
  `kagent-db-users`, the one copy the Job reads; the connection strings in
  `kagent`, `kagent-postgres-owner` and `kagent-postgres-readwrite`, are
  templated from it through a store that may read that Secret alone, with
  `sslmode=verify-full` against the private root. The `kagent-db`
  NetworkPolicy in `ate-system` admits the controller and the Job on 5432.
  The controller runs its migrations as the owner at start; a bump that
  changes kagent's one migration in place needs the schema dropped first
  (Substrate, Bumping the pin, above).
- **Login.** The chart's oauth2-proxy, with the confidential client
  `kagent`, which a platform controller `Client` creates, and a generated
  cookie secret, combined into `kagent-oidc` by an `ExternalSecret`. A
  visitor with no session gets kagent's sign-in page, whose button goes to
  `/oauth2/start` and from there to Keycloak. oauth2-proxy forwards the ID
  token to the UI, whose nginx proxies `/api/`, `/a2a/` and `/mcp` to the
  controller, which runs in `trusted-proxy` mode and takes the user from the
  token's `email` claim without verifying it. `skip-jwt-bearer-tokens`
  admits a bearer ID token for the `kagent` client from the realm, which
  oauth2-proxy verifies itself; a `kubectl` token is refused for its
  audience, a forged one for its signature. The ID token lasts five minutes
  and the controller refuses an expired one, so `cookie-refresh` is `1m`:
  on a request to a session older than that, oauth2-proxy redeems the
  session's refresh token for a new ID token, for as long as the realm's
  SSO session lasts. `reverse-proxy` is off. The ingress Gateway passes a
  client's `X-Forwarded-*` headers through, and with `reverse-proxy`
  oauth2-proxy matches its skip-auth rules against `X-Forwarded-Uri`, so a
  request claiming `/login` would skip the login.
- **Isolation.** The controller accepts any well-formed token it is handed,
  so the network keeps everyone but the proxy out. The namespace is not in
  the mesh, and each pod's NetworkPolicy admits only the hop before it: the
  controller, the UI and Substrate's egress gateway; the UI, oauth2-proxy;
  oauth2-proxy, the ingress Gateway's pods; the tool server, the controller
  and the egress gateway. Anyone who may port-forward or exec into `kagent`
  bypasses this.
- **The controller's RBAC** is `Role`s in `kagent` alone (the chart's
  `rbac.namespaces`), and it watches only `kagent`: whoever reaches it acts
  with its rights, so the chart's `ClusterRole`s, which read and write
  Secrets and ConfigMaps in every namespace, would be theirs. Agents, Harnesses, ModelConfigs, Secrets and the placeholder pool
  are all in `kagent`. The tool server's subchart is not scoped: its
  read-only role covers the cluster, so agents can read it.
- **Exposure.** `kagent.treasury.bank.internal` is under the Gateway's
  wildcard. The `HTTPRoute` `kagent` sends every path to oauth2-proxy on 4180,
  never to the UI or the controller; the chart's own route is off.
- **The tool server** runs with `--read-only`, which leaves out every tool
  that writes, and binds a read-only `ClusterRole`, get, list and watch
  without Secrets, in place of `cluster-admin`.

#### Adding the Anthropic key

A cluster that does not name `kagent` skips this (Adding a cluster, above), and
so does a rebuild whose `state restore` put the key back, which happens before
`kagent` exists (Rebuilding a cluster, under Bootstrap Argo CD, below). A
rebuild that skipped the key enters it here. The model key is the platform
secret `anthropic-api-key`, key
`ANTHROPIC_API_KEY` (Adding a platform secret, under Secrets Manager,
above). The `ExternalSecret` `kagent/kagent-anthropic` copies it within the
hour, or at once with:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n kagent annotate externalsecret kagent-anthropic force-sync=$(date +%s) --overwrite
kubectl -n kagent get externalsecret kagent-anthropic   # SecretSynced
```

Until then that `ExternalSecret`, and so the `kagent` Application, is
`Degraded`, and an agent's `ResolvedRefs` is False with `secret
kagent-anthropic not found`. kagent is the last component before
`argocd-apps` (`registry.cue`), so on a new cluster no other component waits
on the key, but the root Application's own sync does, as it does on Quay's
step.

#### Agents and the worker pool

A Harness's `workerPoolRef` names a `WorkerPool` in the Harness's own
namespace, and the controller reads the pool's sandbox class from it, but
places the actors only by the two `kagent.dev/worker-pool-*` labels, which
Substrate matches against every worker in the cluster. The platform's pool,
`ate-workers/gvisor`, carries those labels, so a Harness in `kagent` naming
`gvisor` gets its actors on that pool's workers. The kagent component renders
a placeholder `WorkerPool` `kagent/gvisor` for the controller to find: the
same name and sandbox class, `replicas: 0`, and no `kagent.dev` labels.
`kagent` enforces baseline Pod Security, which refuses a worker pod, so the
placeholder cannot run one even if scaled up. ate-controller still makes its
worker `Deployment`, at 0, and an unused `ateworker` ServiceAccount.

A Harness for the platform pool, with snapshots in RustFS's `substrate`
bucket:

```yaml
apiVersion: api.kagent.dev/v1alpha3
kind: Harness
metadata: {name: kagent, namespace: kagent}
spec:
  kagent: {}
  substrate:
    workerPoolRef: {name: gvisor}
    snapshotPolicy: {location: "s3://substrate/kagent/"}
```

`snapshotPolicy.location` is required by the CRD. The controller passes it
to Substrate as the ActorTemplate's `snapshotConfig.storageLocation`, which
ate-api-server accepts only with its `PerTemplateSnapshotLocation` preview
gate; the substrate component enables it (`PreviewGates` in
`components/substrate/substrate.cue`), and an agent's snapshots then go
under this location instead of the cluster's `s3://substrate/`.

The controller keeps an agent's configuration in a bootstrap bundle in its
database, and every ActorTemplate names that bundle. A golden actor fetches
it from the controller over the egress gateway and saves it under `/data`,
so a session and a restart never fetch it again. The template carries a
`golden_egress_policy` that allows the controller alone, which
ate-api-server accepts only with its `GoldenEgressPolicy` preview gate, which
the substrate component enables too. There is no fallback: a harness image
older than v1.0.0-rc3 cannot start, so `Kagent.upstream.release` follows
the fork's base.

#### Checking kagent

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n kagent get pods,client,externalsecret   # four pods 1/1; Client READY True; all SecretSynced but kagent-anthropic
kubectl -n ate-system exec substrate-db-1 -c postgres -- psql -d substrate -At \
  -c "select version_id from kagent.schema_migrations" \
  -c "select usename, ssl from pg_stat_activity join pg_stat_ssl using (pid) where usename like 'kagent%'"
    # the migrations; kagent_readwrite_user connections with ssl t
curl -s --cacert root.pem -o /dev/null -w '%{http_code} %{redirect_url}\n' https://kagent.$domain/oauth2/start
    # 302 to https://keycloak.$domain/realms/default/protocol/openid-connect/auth?...client_id=kagent...
curl -s --cacert root.pem -o /dev/null -w '%{http_code}\n' https://kagent.$domain/api/   # 403 without a session
curl -s --cacert root.pem -o /dev/null -w '%{http_code}\n' -H 'X-Forwarded-Uri: /login' https://kagent.$domain/api/   # 403 too
kubectl auth can-i get secrets -n keycloak --as=system:serviceaccount:kagent:kagent-controller   # no
# From a pod outside kagent, every kagent port times out:
kubectl -n default run np-test --image=curlimages/curl:8.11.1 --restart=Never --command -- sleep 600
kubectl -n default exec np-test -- curl -s -m 5 http://kagent-controller.kagent.svc:8083/health   # exit 28
kubectl -n default delete pod np-test
```

### ToolHive

ToolHive is Stacklok's MCP server operator (interview Q3, last and best
effort), with one MCP server at `https://toolhive.treasury.bank.internal/mcp`
behind a Keycloak ID token and Cedar. `ToolHive` (`components/toolhive.cue`)
holds the pins and the names. Three components, in registry order:
`toolhive-crds`, the CRD chart, which Argo CD neither prunes nor deletes;
`toolhive-operator`, the operator chart in `toolhive-system`, with the
`toolhive` namespace it manages; and `toolhive`, the MCP server and its
policies.

- **Pins.** Release 0.59.0: both charts from `oci://ghcr.io/stacklok/toolhive`,
  and the operator, proxy runner, vMCP and registry API images by index
  digest. The MCP server is the MCP reference server `everything`, as
  Stacklok's dockyard packages it for the ToolHive catalog
  (`ghcr.io/stacklok/dockyard/npx/server-everything:2026.8.31`, by digest).
  It needs no network, and its `streamableHttp` argument serves MCP over
  HTTP on port 3001.
- **The operator** watches `toolhive` alone (`operator.rbac.scope:
  namespace`): RoleBindings there to its ClusterRole, no ClusterRoleBinding.
  So the storage version migrator, which needs the whole cluster, is off: a
  CRD version bump that drops a stored version must re-store the objects by
  hand. Update checks are off too.
- **The MCP server** is two workloads. The operator runs a proxy runner,
  Deployment `everything` and Service `mcp-everything-proxy:8080`, and the
  proxy runner creates the MCP server, StatefulSet `everything` and Service
  `mcp-everything:3001`. Over HTTP, not stdio, so the proxy never attaches to
  a pod through the API server and its Role has no `pods/attach`.
- **Tokens.** `MCPOIDCConfig keycloak` is the realm, by its discovery
  document and keys, fetched through the ingress Gateway trusting the
  `private-ca` bundle alone, with `jwksAllowPrivateIP`, since
  `keycloak.treasury.bank.internal` is a private address. The MCPServer sets the
  audience: `kubectl`, ID tokens of the client every platform service behind
  a person's token checks (ADR 0002, interview Q61). No Keycloak client is
  made. The proxy answers a request without a valid token with 401 and a
  `WWW-Authenticate` naming its protected resource metadata, at
  `/.well-known/oauth-protected-resource`. That metadata sends an MCP
  client to Keycloak's OAuth flow, whose access tokens carry no `kubectl`
  audience and are refused, so today a client must be given an ID token.
  The proxy forwards the `Authorization` header to the MCP server
  unchanged, so the server holds the caller's `kubectl` ID token, which
  the platform authenticator and the Substrate shim also accept, for the token's
  life. That is safe only because the server may send nothing (Isolation,
  below); a server that needs egress must not be given this audience.
- **Cedar.** `MCPAuthzConfig everything`: `/platform/owners` may call every
  tool, get every prompt and read every resource, but nobody may call
  `get-env`, which returns the server's environment. Anyone else with a
  valid token can open a session, but is denied every tool, prompt and
  resource. The proxy filters `tools/list` to what the caller may call, so
  `get-env` is not listed. The principal is `Client::"<sub>"` with a parent
  `THVGroup::"<path>"` for each entry of the `groups` claim. The audit log,
  every MCP request's outcome and caller, is in the proxy runner's log.
- **Isolation.** The operator creates no route and no NetworkPolicy
  (stacklok/toolhive issue 1129), so both are CUE. The HTTPRoute sends every
  path to the proxy. The MCP server checks no token, so it admits only the
  proxy, at 3001, and may send nothing. The proxy admits only the ingress
  Gateway's pods, and may send only to the cluster's DNS, the MCP server,
  the ingress Gateway's pods at 443 (Keycloak) and the API server, which it
  reaches by address (`Cluster.apiServer`), because the API server is a
  host-network static pod; Cilium's `policyCIDRMatchMode: nodes` lets the
  `ipBlock` match the control plane's node address. Both namespaces are
  outside the mesh, so the policies hold at the application ports, and Pod
  Security restricted.
- **Health.** Argo CD's check for `MCPServer` (components/argocd) is Healthy
  once the operator reports the current generation Ready, so the root
  waits for the proxy runner, not for the object.

#### Checking ToolHive

From a machine that trusts the private root, `$TOKEN` a member of
`/platform/owners`'s `kubectl` ID token, as under Reaching an actor, above.
`mcp` makes one call in a fresh session: `initialize`, then
`notifications/initialized`, then the method.

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n toolhive get mcpserver,mcpoidcconfig,mcpauthzconfig,pods
    # everything Ready; keycloak and everything VALID True; two pods 1/1
U=https://toolhive.$domain/mcp
function mcp {
  local t=$1 m=$2 p=$3 h s
  h=$(mktemp)
  curl -s -D "$h" -o /dev/null "$U" -H "Authorization: Bearer $t" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
  s=$(awk 'tolower($1)=="mcp-session-id:" {print $2}' "$h" | tr -d '\r')
  curl -s -o /dev/null "$U" -H "Authorization: Bearer $t" -H "Mcp-Session-Id: $s" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  curl -s -w '\nHTTP %{http_code}\n' "$U" -H "Authorization: Bearer $t" -H "Mcp-Session-Id: $s" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"$m\",\"params\":$p}"
  rm -f "$h"
}
mcp "$TOKEN" tools/list '{}' | sed -n 's/^data: //p' | jq -r '.result.tools[].name'
    # twelve tools, echo and get-sum among them, and no get-env
mcp "$TOKEN" tools/call '{"name":"echo","arguments":{"message":"hello"}}'
    # data: ... "Echo: hello" ... HTTP 200
mcp "$TOKEN" tools/call '{"name":"get-env","arguments":{}}'
    # {"jsonrpc":"2.0","id":2,"error":{"code":403,"message":"Unauthorized"}} HTTP 403
curl -s -o /dev/null -w '%{http_code}\n' "$U" -d '{}'                                 # 401
curl -s -o /dev/null -w '%{http_code}\n' "$U" -H 'Authorization: Bearer x.y.z' -d '{}' # 401
# A token of another audience, such as kagent's oauth2-proxy client's, gets
# 401 too. A user outside /platform/owners, such as alice, gets an empty
# tools/list and 403 for every call. The proxy's log has an AUDIT line for
# each request, its outcome denied for the refused calls:
kubectl -n toolhive logs deploy/everything | grep '"outcome":"denied"' | tail -1
# From a pod other than the proxy and the ingress Gateway, in toolhive or
# out of it, both ports time out; from the MCP server, every address does.
kubectl -n default run np-test --image=curlimages/curl:8.14.1 --restart=Never --command -- sleep 600
kubectl -n default exec np-test -- curl -s -m 5 http://mcp-everything.toolhive.svc:3001/mcp         # exit 28
kubectl -n default exec np-test -- curl -s -m 5 http://mcp-everything-proxy.toolhive.svc:8080/mcp   # exit 28
kubectl -n default delete pod np-test
kubectl -n toolhive exec everything-0 -c mcp -- node -e \
  'fetch("https://registry.npmjs.org/",{signal:AbortSignal.timeout(5000)}).then(r=>console.log(r.status),e=>console.log(e.name))'
    # TimeoutError
```

### Quay

Quay is the platform's registry (interview Q13, Q56, Q57 and Q59), at
`https://quay.treasury.bank.internal`: the demo actor's image, public. The
Substrate and kagent images and charts are on `ghcr.io/holos-run`, pulled
anonymously ([docs/forks.md](../docs/forks.md)). `Quay`
(`components/quay.cue`) holds the release, the names and the URL; the `quay`
component renders the rest. It is aavis-ops' Quay component ported, plain
manifests rather than the Quay Operator, which off OpenShift still expects
OLM and adds nothing once the database is CloudNativePG.

- **The server.** One Deployment, `quay`, in the ambient namespace `quay`,
  one replica, `strategy: Recreate`, `quay.io/projectquay/quay:3.17.6`
  pinned by index digest (the tag has no leading `v`). No Clair, no mirror
  worker, no config editor. The gunicorn pools are pinned with
  `WORKER_COUNT_WEB=2`, `WORKER_COUNT_REGISTRY=2`, `WORKER_COUNT_SECSCAN=1`
  and `WORKER_COUNT_UNSUPPORTED_MINIMUM=1`; without the last, upstream's
  minimum of eight registry workers overrides the pins. Memory is
  requested at 4Gi with a 6Gi limit: with the pools pinned, treasury
  measured Quay at 3.6Gi idle, as aavis-ops had, and 3.8Gi after the
  check's push; aavis-ops saw 2Gi and 4Gi limits OOMKilled. The
  first start runs the schema migrations, so the startup probe on
  `/health/instance` allows ten minutes. The ServiceAccount token stays
  mounted, because Quay's `KubernetesConfigProvider` will not start without
  one (it is bound to no role), and the root stays writable, because the
  entrypoint writes supervisord's state and the trust store.
- **Its config.** Quay reads `/conf/stack/config.yaml` and substitutes no
  environment, so ConfigMap `quay-config-template` holds the config with
  placeholders, and the init container `config`, from the same image,
  writes the real one into an `emptyDir` at `/conf/stack` from the Secrets
  below. The pod template carries `holos.run/config-hash`, a hash of the
  template, so a config change rolls the pod.
- **The database.** CloudNativePG `Cluster` `quay-db`, as `keycloak-db`: one
  instance, 10Gi on `ceph-rbd`, PostgreSQL 18.6 pinned by image,
  `enablePDB: false`, `Prune=false,Delete=false`, and `initdb` creating
  database `quay` owned by `quay` with the password from the generated
  `quay-db`. Quay needs `pg_trgm`, which `postInitApplicationSQL` creates
  once, as the superuser, when the database is made.
- **Its keys.** `quay-secret-keys`, `SECRET_KEY` and `DATABASE_SECRET_KEY`,
  generated (Generated secrets, above). `DATABASE_SECRET_KEY` encrypts
  fields in the database, so it must never change while the database
  lives, which the immutable Secret gives; a rebuilt cluster makes both
  anew with the database.
- **Blobs.** In RustFS's bucket `quay` (RustFS, above), through Quay's
  `RadosGWStorage` driver to `rustfs-svc.rustfs.svc.cluster.local:9000`,
  plain HTTP over HBONE, region `us-east-1`, SigV4, under `/registry`. The
  keys are `rustfs-quay`, copied from `rustfs` by `SecretStore` `rustfs`
  (`#ScopedSecretStore` with `source: "rustfs"`, reader
  `quay-rustfs-reader`). `FEATURE_PROXY_STORAGE` is on: without it Quay
  answers a blob pull with a redirect to a presigned URL on `rustfs-svc`,
  which neither the laptop nor a worker's containerd can resolve. With it
  the redirect is to `/_storage_proxy/` on Quay's own host, and Quay's
  nginx fetches the blob. nginx resolves through the pod's dnsmasq without
  the search path, hence the fully qualified name.
- **Redis.** `quay-redis`, Redis 8.6.8 pinned by digest, which Quay
  requires for build logs and user events even with builds off: no
  persistence (`--save "" --appendonly no`), no password, and an
  `AuthorizationPolicy` admitting only Quay's ServiceAccount by its mesh
  identity, which ztunnel enforces.
- **Login.** OIDC against the realm `default`, Keycloak being Quay's only
  identity store (`AUTHENTICATION_TYPE: OIDC`, `FEATURE_DIRECT_LOGIN:
  false`), through the confidential client `quay`, which a platform
  controller `Client` in `quay` creates, with `ReferenceGrant` `quay-clients` in
  `keycloak`. The controller generates the secret and delivers it to Secret
  `quay-oidc`, key `client-secret`; the realm needs no re-import. Redirects:
  `/oauth2/keycloak/callback`, `/callback/attach` and `/callback/cli`.
  `OIDC_SERVER` is the issuer with a trailing slash, which Quay requires.
  The login scopes are `openid profile email groups`, so teams sync from
  full paths such as `/platform/owners`. PKCE stays off: Quay 3.17 keeps its
  state in the CSRF cookie and does not clear it on logout, so the next login
  fails with a 400 on the code exchange (aavis-ops ADR-15). Quay checks the
  ID token at login (ADR 0002). It trusts the private root from the
  namespace's `private-ca` ConfigMap, mounted at
  `/conf/stack/extra_ca_certs/private-ca.crt`; it has no option to skip
  verification. `SUPER_USERS` is `svc-quay-controller` and `jeff`, with
  `FEATURE_SUPERUSERS_FULL_ACCESS`, so they administer organizations they
  did not make. A user's Quay name is their `preferred_username`.
- **The route.** `HTTPRoute` `quay`, every path to `quay:8080`, plain HTTP
  behind the gateway, as Keycloak. Pods resolve `quay.treasury.bank.internal`
  to the gateway already, so aavis-ops' ServiceEntries are not ported.
- **Organizations.** One platform controller `Organization` in `quay`, `demo`,
  on a cluster that names `substrate`, which holds the public `Repository`
  `echo` for the demo actor. The name is reserved on every cluster. It syncs
  team `platformowners` from `/platform/owners` as admin, not `owners`, the
  team Quay makes in every new organization, which the controller would
  report as a conflict. Both are `deletionPolicy: Orphan`, so a deleted or
  pruned resource leaves the organization and its images, which are not in
  git. Neither carries a `caBundle`: the controller trusts the
  private root through `SSL_CERT_DIR`, as argocd-server does, from the
  `private-ca` ConfigMap mounted at `/etc/ssl/private-ca`; Go reads it at
  start, so a new root needs `kubectl -n seabank-controller rollout restart
  deploy/seabank-controller-manager`.
- **The platform controller's credential.** The controller reads its Quay
  token from `seabank-controller/seabank-controller-quay-creds`
  (`url`, `token`, `username`), which each `Organization` and `Repository`
  names in `credentialsSecretRef`, since the CRDs' default is the release's
  name, `holos-controller-quay-creds`, and which `ExternalSecret`
  `seabank-controller-quay-creds`, in this component, copies from the platform secret `quay-controller-token`
  through `SecretStore` `platform` there (reader
  `seabank-controller-platform-reader`). It is here rather than in
  `seabank-controller`, which syncs long before Quay exists: its Application
  would stay `Degraded` and the root would never reach Quay.

#### Bringing Quay up

The irreducible part, which no CRD models, is `cmd/quay-bootstrap`, a Go
program ported from aavis-ops' `hack/quay-bootstrap`, run by hand from the
repository's root after Quay is up, at bootstrap and after a rebuild.

`quay-bootstrap token` logs in to Quay as `svc-quay-controller` through
Keycloak's login form, with the password from Secret
`keycloak/svc-quay-controller`, makes the organization `platform-automation`
and its OAuth Application `seabank-controller` if they are missing, mints a
token through the implicit grant the UI's Generate Token drives, and writes
Secret `quay-controller-token` (`url`, `token`, `username`) in
`seabank-prj-platform`. A stored token is probed first, on endpoints that need
its `super:user` and `org:admin` scopes, and replaced only when Quay refuses
it with a 401 or 403: a token stays live until it is revoked, so minting on
any other fault would leave another live superuser token behind.

The Secret is a platform secret, with `app.kubernetes.io/managed-by=holos.run`
and the platform owners' grant, so it shows under Platform in the Secrets
Manager. The command converges: a second run prints `no change` and writes
nothing. It uses `kubectl`'s current context (or `-context`) and trusts the
private root from the cluster's `private-ca` ConfigMap (or `-ca-file`)
beside the system's; `-h` lists the rest. Every run passes `-quay-url`, which
says which cluster's Quay it logs in to and is the `url` the controller gets.
Its default is treasury's, compiled into the program, so a run on another
cluster without the flag goes to treasury's Quay.

On a new cluster the root reaches `quay` ahead of the projects and kagent
and waits there: the credential's `ExternalSecret` reports
`SecretSyncedError`, and the Application `Degraded`, until the steps below,
so the root's sync fails at `quay` and retries (Bootstrap Argo CD,
below). Quay itself comes up once the `Client` has delivered `quay-oidc`,
`quay-db` is healthy and `rustfs-quay` is copied.

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n quay rollout status deploy/quay --timeout=15m
kubectl -n quay get client quay                     # READY True

# 1. Only on a realm imported before svc-quay-controller was added, as on
#    treasury: create the user once through the admin API, with the import's
#    fields and the generated password, read from stdin rather than argv.
#    A user made this way gets the realm's default role. t and a as in the
#    check under The realm, above.
kubectl -n keycloak get secret svc-quay-controller -o jsonpath='{.data.password}' | base64 -d |
  jq -Rn --rawfile p /dev/stdin '{username: "svc-quay-controller", email: "svc-quay-controller@bank.internal",
    firstName: "Quay", lastName: "Controller", enabled: true, emailVerified: true,
    credentials: [{type: "password", value: $p, temporary: false}]}' |
  curl -s --cacert root.pem -X POST -H "Authorization: Bearer $t" -H 'Content-Type: application/json' \
    --data-binary @- "$a/users" -o /dev/null -w '%{http_code}\n'      # 201; 409 if it exists

# 2. The controller's token, then its copy.
cd ..   # the repository's root
go run ./cmd/quay-bootstrap token -quay-url https://quay.$domain
kubectl -n seabank-controller annotate externalsecret seabank-controller-quay-creds force-sync=$(date +%s) --overwrite

# 3. Only on a cluster with substrate: nothing else renders an organization or
#    repository in quay, and a wait on none is an error, not a pass. A claim's
#    organization is in its own namespace, once the root reaches its
#    Application: Checking a project, below.
kubectl -n quay wait --for=condition=Ready organization --all --timeout=5m
kubectl -n quay wait --for=condition=Ready repository --all --timeout=5m
```

#### Trusting the root on the workers

The kubelet pulls through containerd, which checks Quay's certificate
against the node's trust store. The root is minted in the cluster (Q52), so
Talos gets it by hand, as a `TrustedRootsConfig` document patched onto
every worker, at bootstrap and again after a rebuild (Q59). Talos 1.14
rewrites `/etc/ssl/certs/ca-certificates.crt` with it, under a header of
the document's name, without a reboot:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
export TALOSCONFIG=~/.config/holos/talos/$cluster/talosconfig
kubectl -n default get configmap private-ca -o jsonpath='{.data.ca\.crt}' > root.pem
{ printf 'apiVersion: v1alpha1\nkind: TrustedRootsConfig\nname: private-ca\ncertificates: |\n'
  sed 's/^/  /' root.pem; } > trusted-roots.yaml
for n in $(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'); do
  talosctl -n $n patch mc --mode no-reboot -p @trusted-roots.yaml --dry-run   # the diff, "without a reboot"
  talosctl -n $n patch mc --mode no-reboot -p @trusted-roots.yaml
  talosctl -n $n read /etc/ssl/certs/ca-certificates.crt | grep -A1 '^private-ca:$'   # private-ca: then ====
done
```

`certificates` is a string, so patching again replaces it: after a rebuild,
run the same loop, even with a restored root, since the new nodes do not have
it. containerd reads the trust store once, when it starts, so the
patch alone does not reach it: restart the workers with `talosvm restart`,
after the first patch and after every rebuild's. It reboots them one at a
time, each cordoned while it goes down, and moves to the next only once the
last is back `Ready` with its Cilium and ztunnel pods and every Deployment
and StatefulSet that ran on it, Keycloak and Quay among them, is available
again; it deletes the Failed pods a reboot leaves behind, those the
kubelet's node shutdown `Terminated` and those it refused with
`NodeShutdown`. A
reboot inside the guest is enough for the trust store, so the default
`-mode reboot`
([Restarting nodes](../providers/talos/README.md#restarting-nodes) has the
rest):

```sh
# From the repository's root.
set -a; . ~/.config/holos/proxmox.env; set +a
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
export TALOSCONFIG=~/.config/holos/talos/$cluster/talosconfig
go run ./providers/talos/cmd/talosvm restart -cluster "${cluster:?set cluster first}" -dry-run     # the steps of each worker
go run ./providers/talos/cmd/talosvm restart -cluster "${cluster:?set cluster first}"
kubectl -n argocd get applications                                          # every one Synced and Healthy
```

#### Rotation

- **The controller's token.** Delete `quay-controller-token` in
  `seabank-prj-platform` and run `quay-bootstrap token -quay-url
  https://quay.$domain`; the copy follows within the hour, or at once with the `force-sync` above. The old token stays live
  in Quay until the Application is deleted (organization
  `platform-automation`, Applications), which deletes every token it issued;
  the next `token` run makes a new one.
- **`quay-db`.** As `keycloak-db` (Keycloak, above), with `deploy/quay`
  scaled to 0 and the `quay` Application paused: the init container builds
  the database URL from the Secret at each start.
- **`quay-secret-keys`.** Never while the database lives: a new
  `DATABASE_SECRET_KEY` makes the encrypted fields unreadable. A rebuilt
  cluster makes both with its new database.
- **`svc-quay-controller`'s password.** The import set it once. Rotate the
  Secret (Generated secrets, above), then set the user's password to it
  through the admin API (`PUT $a/users/<id>/reset-password`), then run
  `quay-bootstrap token -quay-url https://quay.$domain` only if the token must
  be replaced too.

None of these has been exercised on a cluster yet.

#### Checking Quay

What Quay uses, once it has run a while (no metrics server here), to check
its memory request against:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n quay exec deploy/quay -c quay -- cat /sys/fs/cgroup/memory.current   # bytes
```

From the repository's root on the claude VM, with `root.pem` as above,
docker trusting the root
(`sudo install -D root.pem
/etc/docker/certs.d/quay.$domain/ca.crt`). A machine set up
before the rename to cluster-qualified names also drops the old directory, the
old root in it and the old login: `sudo rm -rf
/etc/docker/certs.d/quay.bank.internal; docker logout quay.bank.internal`.

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
# 1. Running, migrated, Synced and Healthy.
kubectl -n quay get cluster,deploy,pods                 # quay-db healthy; quay and quay-redis 1/1
kubectl -n argocd get application quay -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'   # Synced Healthy
kubectl -n quay logs deploy/quay -c quay | grep -i -m3 'migrat'

# 2. By hand, in a browser: log in at https://quay.$domain as jeff
#    through Keycloak, log out, and log in again (no 400 on the code exchange).

# 3. The command converges, and the secret is listed under Platform.
go run ./cmd/quay-bootstrap token -quay-url https://quay.$domain | tail -1   # ... no change
kubectl -n seabank-prj-platform get secret -l app.kubernetes.io/managed-by=holos.run
  # ceph-client-$ceph_user, quay-controller-token

# 4. The organization and the repository are Ready, and jeff is in the platformowners team.
kubectl -n quay get organization,repository             # READY True
tok=$(kubectl -n seabank-prj-platform get secret quay-controller-token -o jsonpath='{.data.token}' | base64 -d)
curl -s --cacert root.pem -H "Authorization: Bearer $tok" \
  https://quay.$domain/api/v1/organization/demo/team/platformowners/members | jq -c '[.members[].name]'
                                                        # lists jeff, once jeff has logged in

# 5. A multi-layer image, one layer large, pushed to the public repository
#    with the controller's token, which docker login takes as $oauthtoken,
#    and its blobs in RustFS.
printf %s "$tok" | docker login quay.$domain -u '$oauthtoken' --password-stdin
d=$(mktemp -d)
printf 'FROM docker.io/library/busybox:1.37.0\nRUN head -c 300000000 /dev/urandom > /big\nRUN echo one > /one\nRUN echo two > /two\n' > $d/Dockerfile
docker build -t quay.$domain/demo/echo:check $d
docker push quay.$domain/demo/echo:check
docker logout quay.$domain
kubectl -n quay run s3-test --image=docker.io/rustfs/rc:v0.1.36 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"s3-test","image":"docker.io/rustfs/rc:v0.1.36",
    "command":["sleep","600"],"env":[
      {"name":"AK","valueFrom":{"secretKeyRef":{"name":"rustfs-quay","key":"access-key"}}},
      {"name":"SK","valueFrom":{"secretKeyRef":{"name":"rustfs-quay","key":"secret-key"}}},
      {"name":"RC_HOST_s","value":"http://$(AK):$(SK)@rustfs-svc.rustfs.svc:9000"}]}]}}'
kubectl -n quay wait --for=condition=Ready pod/s3-test
kubectl -n quay exec s3-test -- rc ls -r s/quay/registry/ | tail -5   # the blobs, the large one ~300MB
kubectl -n quay delete pod s3-test
unset tok

# 6. An anonymous pull of the public image, by a worker and from the laptop.
kubectl create ns quay-test
kubectl -n quay-test run anonymous --image=quay.$domain/demo/echo:check --image-pull-policy=Always \
  --restart=Never --command -- sleep 600
kubectl -n quay-test get pods                           # anonymous Running, with no pull secret
kubectl delete ns quay-test
#   on the laptop, logged out: docker pull quay.$domain/demo/echo:check

# 7. A clean render reproduces deploy/ (Render, below).
```

Step 6 is what the Talos patch is for, and a pull that fails with a
certificate error points there. The check's tag, `demo/echo:check`, is
deleted in the UI afterwards.

The `demo` organization and repository in steps 4 to 6 render with
`substrate`. A cluster that does not take it has neither, so those steps do
not run there as written, and this check leaves its workers' trust unproved.

## Projects

A product engineer gets a project, a namespace they own, with a
ProjectClaim: one small CUE file in `projects/`, in a pull request with the
manifests it renders. The ProjectClaim collection is a pure CUE collection,
not a CRD (overview §4), ported from aavis-ops' Project collection, which
names the same thing. `projects/projects.cue` is its schema,
`collections.cue` binds it into the platform, and `components/project`
renders each claim.

The collection is the platform's, and each claim selects its clusters, by the
clusters' labels (Clusters, above), with a required `clusterSelector`. Every
cluster carries `holos.run/cluster-name` and `holos.run/site`, set from its
data, beside any labels of its own. The schema is Kubernetes' LabelSelector: `matchLabels` and `matchExpressions`, all
of whose requirements hold together, with the operators `In`, `NotIn`, `Exists`
and `DoesNotExist`. `NotIn` holds of a cluster without the key, and `{}`
selects every cluster, as in Kubernetes. One cluster takes a line:

```cue
clusterSelector: matchLabels: "holos.run/cluster-name": "treasury"
```

Several take `matchExpressions`, since `matchLabels` cannot list two values:

```cue
clusterSelector: matchExpressions: [{
	key:      "holos.run/cluster-name"
	operator: "In"
	values: ["treasury", "cartography"]
}]
```

The field has no default, because a forgotten one that defaulted to `{}` would
land the claim on every cluster. A claim without one, or whose selector
selects no cluster, fails `cue vet` with `claimClusters.<name>: incompatible
list lengths (0 and 1)`, and a misspelled operator or a bad label key fails it
at the claim's own field. `holos render platform` reports none of these and
exits 0: it drops a claim that selects nothing, and a malformed selector leaves
it rendering nothing at all, for any cluster, which is why `cue vet` goes first,
as CI runs it. A selector left incomplete, such as an expression with no
operator, fails both, and names every claim in that same error rather than its
cause. Selection is open to tenants: nothing yet lets a cluster refuse a claim
that selects it.

On each cluster it selects, a claim renders, as the component `project-<name>`
with an `Application` of its own in the `platform` `AppProject` (interview
Q66), and on any other cluster it renders nothing:

- **The namespace** `<name>`, in ambient, labeled `holos.run/project: <name>`.
- **Keycloak**: the groups `/projects/<name>/roles/owner`, `editor` and
  `viewer`; a `User` for each owner who is not already one of the realm's
  people (`Keycloak.users`, such as `jeff`); the owners' membership in the
  owner group; and the `ReferenceGrant` `project-<name>` in `keycloak` that
  lets these resources name the `Instance` there. The controller makes the
  parent groups `/projects`, `/projects/<name>` and `/projects/<name>/roles`
  itself. No client (Q65): Quay syncs its teams from the groups claim.
- **Quay**: the `Organization` `<name>`, with the teams `projectowners`
  (admin), `projecteditors` (creator, write) and `projectviewers` (member,
  read), each synced from its group, and `platformowners`, as every
  organization has.
- **RBAC**: the `RoleBinding` `<name>-owners` in `<name>`, the owner group
  bound to the `admin` `ClusterRole` (`ownerAccess`), in that namespace and
  no other. Its subject is the group's full path, with the leading slash
  the groups claim carries: the bare path matches nothing.
- **Argo CD**: the `AppProject` `<name>`, which may sync only from this
  repository, at signed commits, into `<name>`, no cluster-scoped kind, and
  neither RBAC nor the platform controller's kinds; and the `Application` `<name>`
  in it, which syncs `deploy/clusters/<cluster>/projects/<name>/`. That
  directory holds only what the claim renders, one `ConfigMap`, `project`,
  describing it. Every render removes `deploy/clusters` first, so a file
  added there by hand is gone at the next render and fails CI; a project's
  own manifests are future work, to be rendered from CUE or kept outside
  `deploy/clusters`.
- **The platform authenticator**: the owners' usernames and the owner group join
  `PlatformAuthenticator.users` and `.groups` on that cluster, so the
  authenticator forwards the group and may impersonate the owners. The
  `RoleBinding`'s subject and the allowlist entry are the same definition,
  `#ProjectRoleGroupPath`, so `grep -r /projects/<name>/roles/owner deploy/`
  finds both.
- **Substrate**, on a cluster that names `substrate` and `substrate-shim`, and
  nowhere else: the atespace `<name>`, reached at
  `https://<actor>.<name>.ate.treasury.bank.internal` by the project's owner
  group and `/platform/owners`. An atespace is an object in Substrate's API,
  not in Kubernetes, so a Job makes it: `atespace-<name>`, an Argo CD Sync
  hook, which calls `CreateAtespace`, then `CreateAtespaceAccessPolicy`
  binding `owner` to `system:serviceaccount:<name>:ate-client`, each with
  `grpcurl` over the server's gRPC reflection, since no published image has
  `kubectl ate`. Each treats `AlreadyExists` as success, so a sync changes
  nothing once they have been made, and a policy changed through the API
  stays as it was. It goes by name alone: a claim on the name of an atespace
  Substrate already has, one made by hand or left by a removed claim, inherits
  it, with its actors and any old policy, and `<name>/ate-client` may not be
  bound. `kubectl ate get access-policy -a <name>` shows which it got
  (Checking a project, below). The Job is in `ate-system`, as the
  `ate-client` ksa, with a projected token, never in `<name>`: only a global
  owner may create an
  atespace, and the claim's owner is `admin` in `<name>`, who could read any
  token kept there. `substrate`'s `NetworkPolicy` `atespace-setup` admits
  the Job to the API server. The claim also labels `<name>`
  `ate.dev/api-access: "true"`, so its pods may reach the API, and makes a
  ServiceAccount `ate-client` there, which owns this atespace and nothing else:
  an owner who mints its token gets what the claim gave them already. It is
  not the `ate-client` ksa (`docs/glossary.md`). The route through the shim,
  a `ListenerSet`, a `Certificate` with its own `CertificateRequestPolicy`,
  an `HTTPRoute` and an `AuthorizationPolicy`, is in Adding an atespace,
  above. No worker pool: an
  actor runs on the platform's `ate-workers/gvisor` with no pool named on its
  template, and a project cannot have a pool of its own, whose workers need
  the privileged Pod Security level.

No Secrets Manager project (Q64), no `ResourceQuota`, and no RBAC for the
editor and viewer groups. `projects/` holds four claims: `payments`, `ledger`
and `checkout`, each selecting `treasury`, and `splunk`, selecting
`cartography`.

### Adding a project

1. Write `projects/<name>.cue`, with its `clusterSelector` (Projects, above)
   and one owner or more, keyed by email in lower case:

   ```cue
   package projects

   projects: "my-project": {
   	clusterSelector: matchLabels: "holos.run/cluster-name": "treasury"
   	owners: "alice@bank.internal": _
   }
   ```

   `<name>` is the project's one name: lower case letters, digits and single
   dashes, 2 to 54 characters. It may not be a name the platform uses: a
   component's, a platform namespace, Argo CD's `platform` or `default`, a
   Quay organization, a person's username, a Substrate atespace, or anything
   starting `kube-`, `seabank-` or `project-` (`Projects.reserved`,
   `components/project.cue`). A claim that takes one fails the render.

   An owner's Keycloak username, which their tokens carry as
   `preferred_username` and which the authenticator impersonates as
   `oidc:<username>`, is the email's local part, lower-cased, with each run
   of anything outside `[a-z0-9]` turned to a dash and any dash at either
   end trimmed: `alice.smith@` is `alice-smith`, `-alice-@` is `alice`. Set
   it when it is something else:
   `owners: "alice@bank.internal": username: "asmith"`; a username is runs
   of lower-case letters and digits joined by single dashes or dots. An
   owner who is one of the realm's people must have the username they have
   there, one username is one person on a cluster, and no owner may be a
   platform service user (`svc-quay-controller`, or a client's
   `service-account-*`): each mistake fails the render of the clusters the
   claim selects, and so `holos render platform` as a whole, and CI for every
   cluster. Each cluster has its own Keycloak, so the same username on two
   clusters may be two people. `cue vet` reports a conflict over a person for
   treasury alone, or for another cluster with `-t clusterName=<cluster>`, and
   a service user as an owner not at all, so the render is what reports those.
   `ownerAccess: "edit"` or `"view"` gives the owners less than `admin`.

2. Render, from this directory, and check what changed. The changes below are
   each selected cluster's, and a cluster the claim does not select stays as
   it was, byte for byte:

   ```sh
   cue vet ./... && rm -rf deploy/clusters && holos render platform
   git status deploy/
     # new: components/project-<name>/, projects/<name>/ and
     #      components/argocd-apps/application-project-<name>.yaml
     # changed: seabank-authenticator's Backend and impersonator ClusterRole,
     #      and the sync wave, its index in the cluster's own list, of every
     #      Application after the new one: argocd-apps' always, kagent-crds'
     #      and kagent's on a cluster that takes them, and any other
     #      project-* Application that sorts after it
   ```

3. Commit the claim and `deploy/` together, signed (`git commit -S`, Argo
   CD, above), and open a pull request. CI renders the platform again and
   fails if `deploy/` differs from what the claim renders. Merge it in
   GitHub's UI.

4. Argo CD syncs the merge within a minute: the root creates `project-<name>`,
   which makes everything above and the project's `Application`, and
   `seabank-authenticator` syncs its allowlist.

5. **For an owner Keycloak did not already have**, set their first and last
   name and a password in Keycloak's admin console (realm `default`, Users),
   or send them a reset. The claim makes the user with neither: a password
   is not for git, and the realm requires a name, which Keycloak otherwise
   asks for on first login.

6. **The owner logs in again.** The groups claim is written when a token is
   minted, so a token from before the merge has no
   `/projects/<name>/roles/owner`; kubelogin's cache must be cleared
   (`kubectl oidc-login clean`) or left to expire. Quay team membership too
   follows the groups claim at each Quay login, so the owner joins
   `projectowners` when they next log in to Quay. Then, as in Logging in
   with kubectl:

   ```sh
   unset KUBECONFIG                                  # the login's ~/.kube/config
   kubectl --context $cluster-oidc auth whoami       # oidc:alice, [/projects/my-project/roles/owner system:authenticated]
   kubectl --context $cluster-oidc auth can-i create deployments -n my-project   # yes
   kubectl --context $cluster-oidc auth can-i create deployments -n default      # no
   ```

### Checking a project

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n argocd get application project-my-project my-project   # Synced Healthy
kubectl -n my-project get groups.keycloak.holos.run,users.keycloak.holos.run,groupmemberships.keycloak.holos.run,organizations.quay.holos.run
    # every READY True
grep -r /projects/my-project/roles/owner deploy/   # the RoleBinding, the Backend, the impersonator, the Organization, the ConfigMap, and with the atespace the AuthorizationPolicy
kubectl -n argocd get application project-my-project -o jsonpath='{.status.operationState.phase}'   # Succeeded
kubectl -n ate-system get job atespace-my-project -o jsonpath='{.status.conditions[*].type}'         # Complete, not Failed
kubectl -n ate-system logs job/atespace-my-project   # CreateAtespace and CreateAtespaceAccessPolicy: created, or already exists
kubectl get certificaterequestpolicy project-my-project        # READY True
kubectl -n substrate-shim get listenerset project-my-project   # ACCEPTED, PROGRAMMED True
kubectl -n substrate-shim get certificate my-project-wildcard  # READY True
kubectl ate get access-policy -a my-project        # owner user:system:serviceaccount:my-project:ate-client
```

The lines from `ate-system` on are for a cluster with the atespace (Substrate,
above).

Read the first two lines, not the `Application`'s status: a hook is outside an
`Application`'s health and comparison. A failed Job fails the sync, Argo CD
retries it ten times, each with a new Job, and stops. The `Application` then
reads `Synced` and `Healthy` with `operationState.phase` `Failed`, the root's
health check passes it, and no automated sync runs the Job again, so the
atespace is missing with nothing saying so. A sync by hand runs it again, once
what failed it is fixed:

```sh
argocd app sync project-my-project
```

If `access-policy` shows another policy, or none, the atespace was there before
the claim (Projects, above), and is the operator's to fix with `kubectl ate`.

### An actor in a project's atespace

A platform operator puts an actor in a project's atespace with `kubectl ate`,
as in the demo atespace (Substrate, above). The claim's owner can reach the
actor, but not the API from a laptop, since `kubectl ate` port-forwards in
`ate-system`; a pod in the project's namespace can use the API as
`<project>/ate-client`, whose token the owner may mint.

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
project=my-project a=echo
image=quay.$domain/demo/echo@sha256:c4717a8d1f0134a7444e24f881160e033991f23027c6c5a9a3f8fd22e70d1d44
kubectl ate create actor-template -f - <<EOF
metadata: {atespace: $project, name: $a}
containers:
- name: whoami
  image: $image
  env: [{name: WHOAMI_NAME, value: $a}]
  wakeupProbe: {httpGet: {path: /health, port: 80}}
resources:
  limits: {cpuMillicores: 250, memoryBytes: 134217728}
EOF
kubectl ate get actor-templates -a $project   # a GOLDEN TAG, within a minute
kubectl ate create actor $a -a $project --template $a
```

The template names no pool, so the actor runs on `ate-workers/gvisor`, which
`kubectl ate get actors -a $project` shows once it is awake. Then, with an ID
token (Reaching an actor, above), an owner of the project or a member of
`/platform/owners` gets `Name: echo`, and anyone else 403:

```sh
curl -H "Authorization: Bearer $TOKEN" https://$a.$project.ate.$domain/
```

The project's own ServiceAccount can do the same in its atespace and is
denied everywhere else:

```sh
kubectl -n $project create token ate-client --audience=api.ate-system.svc --duration=1h > project.token
kubectl ate --token-file project.token get actors -a $project   # the actor
kubectl ate --token-file project.token get actors -a demo       # PermissionDenied
rm project.token
```

### Removing a project

Removing the claim and rendering removes its files, and the root prunes
`project-<name>`'s `Application`; but no `Application` has the resources
finalizer (Argo CD, above), so everything it made stays. Narrowing a selector
is the same on the cluster it stops selecting. Remove it by hand, in this
order, after the merge, on each cluster it left. Everything down to
`approver-policy:project-<name>` is the atespace, so a cluster without one
(Substrate, above) starts at the `Application`:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
# The actors, templates and tags first: Substrate refuses to delete an atespace
# that holds any. A tag blocks it like the rest (tags_atespace_fk, RESTRICT).
kubectl ate get actors -a <name>
kubectl ate suspend actor <actor> -a <name> --mode sync
kubectl ate delete actor <actor> -a <name>
kubectl ate get actor-templates -a <name>
kubectl ate delete actor-template <template> -a <name>
kubectl ate get tags -a <name>
kubectl ate delete tag <tag> -a <name>
kubectl ate delete atespace <name>     # its access policy goes with it
kubectl -n ate-system delete httproute ate-<name>
kubectl -n ate-system delete job atespace-<name>
kubectl -n substrate-shim delete listenerset,authorizationpolicy project-<name>
kubectl -n substrate-shim delete certificate <name>-wildcard
kubectl -n substrate-shim delete secret <name>-wildcard-tls
kubectl delete certificaterequestpolicy project-<name>
kubectl delete clusterrolebinding,clusterrole approver-policy:project-<name>
kubectl -n argocd delete application <name>
kubectl -n argocd delete appproject <name>
kubectl delete namespace <name>        # wait: the controller's finalizers delete the groups and the membership
kubectl -n keycloak delete referencegrant.security.holos.run project-<name>
```

The `ReferenceGrant` goes last: without it the finalizers of the namespace's
`Group` and `GroupMembership` cannot reach the `Instance`, report
`ReferenceNotGranted` and hold the namespace in `Terminating` until the
grant is back. Three things stay, by design, and are removed in Keycloak's
admin console or Quay's API once nobody needs them:

- the parent groups `/projects/<name>` and `/projects/<name>/roles`, which
  the platform controller made and does not own, and `/projects` once no project
  is left;
- each owner's user, `Orphan`, since a person may own another project and
  their password was set by hand;
- the Quay organization and its images, `Orphan`, as `demo` is. Delete it
  before a claim of the same name is added again: the new `Organization`
  does not adopt, so the controller reports a `Conflict` on an
  organization it did not create, and the project's never becomes Ready.

## Render

From this directory, in a clone or worktree with the Substrate submodule
checked out (Substrate, above), which a fresh one is not:

```sh
git submodule update --init vendor/substrate
cue vet ./...
rm -rf deploy/clusters
holos render platform
git status deploy/
```

`holos render platform` writes files but never removes one a component no
longer renders, such as the Hubble certgen Job whose name changes with the
Cilium values, so remove `deploy/clusters` first. Commit the result;
`deploy/` must be clean after a render. CI's Render job
(`.github/workflows/ci.yaml`) runs the same steps, with holos 0.106.0 and
the helm v3.17.3, kubectl v1.37.1 and cue v0.17.1 it runs, and fails a
pull request whose committed tree differs from its render. Argo CD syncs
what is committed on `main`, so a change reaches a cluster only with its
render. Render one
component with `holos render platform --selector component=cilium`.

Then check the render against ADR 0003's Service contract, as CI's Render
job does next:

```sh
go run ../cmd/contract-check deploy
```

It reads each cluster's tree under `deploy/clusters` and fails a webhook
configuration, conversion webhook or APIService that reaches its webhook by
`url:`, names a Service the tree does not hold, or one without a selector or
headless, or one whose selector matches no pod template or a pod template on
`hostNetwork`. A configuration with the `holos.run/contract-exception`
annotation is listed as an exception instead; none has one.

## Bootstrap Argo CD

A cluster is built with its webhooks failing closed from the start
(Admission webhooks, above). To rebuild one, follow Rebuilding a cluster, below,
which saves its state, tears it down and restores the state in this section.
Argo CD needs pod networking, and DNS to
reach GitHub, before it can sync anything, so a new cluster gets four
components by hand: `cilium`, `coredns`, `argocd` and the root
`Application` with its `AppProject`. It also gets `management-namespaces`
and the Ceph key in it (Storage, above), which no component renders. The
root then creates the `Application` of every component the cluster takes,
in registry order, waiting for each to be `Synced` and `Healthy` before the
next, and takes over the hand-applied components as it goes. Apply from a
checkout of `main`, since that is what Argo CD will sync, and from this
directory:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
export TALOSCONFIG=~/.config/holos/talos/$cluster/talosconfig
d=deploy/clusters/$cluster/components

kubectl apply --server-side --field-manager=argocd-controller -f $d/cilium/
kubectl -n kube-system rollout status ds/cilium
kubectl -n kube-system rollout status deploy/cilium-operator

kubectl apply --server-side --field-manager=argocd-controller -f $d/coredns/
kubectl -n kube-system rollout status deploy/coredns

# The namespace first: kubectl applies a directory's files in name order.
kubectl apply --server-side --field-manager=argocd-controller -f $d/argocd/namespace-argocd.yaml
kubectl apply --server-side --field-manager=argocd-controller -f $d/argocd/
kubectl wait --for=condition=Established crd/applications.argoproj.io crd/appprojects.argoproj.io
kubectl -n argocd rollout status deploy/argocd-repo-server
kubectl -n argocd rollout status sts/argocd-application-controller

# The management namespaces, which need nothing before them, and the Ceph
# key in the project, which nothing renders (Storage, above). The namespace
# files sort before the RoleBinding. The Secret is made, not applied: it is
# not in git, so no field manager of Argo CD's should own it. The key is
# read into a variable first, so a failed ssh writes nothing rather than an
# empty key.
kubectl apply --server-side --field-manager=argocd-controller -f $d/management-namespaces/
key=$(ssh root@r620a ceph auth get-key client.$ceph_user) && [ -n "$key" ] &&
printf %s "$key" |
  kubectl -n seabank-prj-platform create secret generic ceph-client-$ceph_user \
    --from-literal=userID=$ceph_user --from-file=userKey=/dev/stdin --dry-run=client -o yaml |
  kubectl label --local -f - app.kubernetes.io/managed-by=holos.run -o yaml |
  kubectl annotate --local -f - \
    'holos.run/share-roles=[{"principal":"/platform/owners","role":"owner"}]' -o yaml |
  kubectl create -f -
unset key
```

On a rebuild, restore the cluster's state now (Rebuilding a cluster, below). A
new cluster has none and skips this block. The command takes the cluster's own
kubeconfig, and creates any namespace it needs, `cert-manager` among them. On
a cluster without `kagent`, add `-skip seabank-prj-platform/anthropic-api-key`.

```sh
go run ../cmd/state restore -cluster "${cluster:?set cluster first}"
```

**Do not go on until it has exited cleanly, printing `Restored`, or `Nothing
restored` if you skipped every resource on purpose. The next block starts
cert-manager's path to a new root, so a restore that comes after it finds a
different root on the cluster and refuses.** Once that has happened, see What
goes wrong, under Rebuilding a cluster, below.

```sh
# The AppProject and the root alone: the root creates the other
# Applications wave by wave. Applying the whole directory would create them
# all at once, and they would sync in parallel.
kubectl apply --server-side --field-manager=argocd-controller \
  -f $d/argocd-apps/appproject-platform.yaml -f $d/argocd-apps/application-argocd-apps.yaml
kubectl -n argocd get applications -w
```

The `Application`s appear one at a time in registry order, and each reaches
`Synced` and `Healthy` within a few minutes. Every node, the control plane
included, turns `Ready` once its Cilium agent is up. Once
`private-ca-bundle` is `Healthy`, restart the server so it reads the private
root, which it needs to log in through Keycloak (Logging in, below): its
`private-ca` mount is optional because the server starts before
trust-manager writes the ConfigMap, and Go reads the trust pool only at
start.

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n argocd rollout restart deploy/argocd-server
```

On a cluster that takes `substrate`, the root then waits on it until its
key pools exist: once its namespaces are synced, run the key pool commands
under Bringing Substrate up (Substrate, above). Its pods that project the
pools wait in ContainerCreating until then, so the Application stays
Progressing, and the root holds there without spending a retry. Run them
within ten minutes: a Deployment that has not progressed by then passes its
progress deadline and reports `Degraded`, and once `substrate`'s own sync
has ended, that fails the root's sync and starts its retries (below).

The root then waits on `quay`, ahead of the projects and any kagent, whose
credential is a platform secret made by `cmd/quay-bootstrap` against the
running Quay: once Quay's pod is up, run the steps under Bringing Quay up,
and patch the workers' trust and restart them with `talosvm restart`
(Trusting the root on the workers), both under Quay, above. Until then the
credential's `ExternalSecret`, and so `quay`, is `Degraded`: the root's sync
fails at `quay` and retries, and creates nothing after it until `quay` is
`Healthy`.

Last, on a cluster that takes it, comes `kagent`, which stays `Degraded`
until the Anthropic key is in (Adding the Anthropic key, under kagent,
above); the platform secret can be written before `kagent` exists. The
root's sync retries 10 times, backing off from 5 seconds to 3 minutes. That
is about 17 minutes for the whole bootstrap, shared by every hand step that
leaves an `Application` `Degraded`: Quay's, the workers' trust, then kagent's
key. The early waves can spend some too: on cartography `gateway-api` read
`Degraded` for a few seconds after its first sync, and the root's count was
already 2 at `cert-manager`. A step that leaves one `Progressing`, as the key pools do for their
first ten minutes, spends none. Quay takes minutes to come up before its
steps can start, so the retries often run out at `quay`. If they run out,
the root stays `OutOfSync` until the next commit to `main`, and the
`Application`s after the one it stopped at are not created. Once the hand
steps are done, kagent's key included on a cluster that takes it, sync the
root again with the automated policy's prune and retry. This needs no `argocd` CLI:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n argocd patch app argocd-apps --type merge -p '{"operation":{
  "initiatedBy":{"username":"bootstrap"},
  "sync":{"prune":true,"syncOptions":["ServerSideApply=true"]},
  "retry":{"limit":10,"backoff":{"duration":"5s","factor":2,"maxDuration":"3m"}}}}'
kubectl -n argocd get app argocd-apps   # Synced Healthy
```

The hand applies use Argo CD's own field manager, `argocd-controller`, so
Argo CD's first sync finds itself the objects' only manager. Under any other
name the hand applies would go on co-owning every field, and a field later
removed from a manifest would stay on the cluster. Applying another
component by hand, while Argo CD cannot sync, works the same way: its
namespace file first, then its directory, in registry order (`registry.cue`
says what each needs before it).

Argo CD manages itself, `cilium` and `coredns`, so a bad commit to any of the
three can cut its own path to GitHub; recover by applying them by hand as
above from a fixed checkout.

### Rebuilding a cluster

A rebuild destroys a cluster's VMs and brings up a new cluster with the same
name. Git brings nearly everything back. What it cannot bring back is the
cluster's state, the things the cluster holds that a rebuild cannot make again
or read from somewhere else. Today that is two Secrets:

| State | Why it needs saving |
| --- | --- |
| `cert-manager/private-ca-root` | The private root is generated in the cluster and never enters git. A new one means trusting it again on the laptop and the claude VM. |
| `seabank-prj-platform/anthropic-api-key` | A person typed it into the Secrets Manager. |

The Ceph key is not state, since Ceph keeps it and the bootstrap reads it
again. Every other generated Secret, the Keycloak passwords among them, is
made anew, so `jeff`'s password changes (Logging in, below).

`cmd/state` carries the state across. `state save` writes it, encrypted, to
`~/$cluster-state.json.gpg`, and `state restore` puts it on the new cluster.
A rebuild is these steps, in this order, from the repository's root on the
claude VM unless a step says otherwise:

1. **Open an `attach-gpg` tmux pane, and set the variables.** Both verbs need
   the secret key unlocked: `state save` decrypts what it wrote before it
   installs the file, and `state restore` decrypts it. Set all five variables
   under Before you start. The file is encrypted to the key that signs your
   commits, `git config user.signingkey`, or to `-recipient`.
2. **Save, as the last step before destroying the cluster.** Tearing a cluster
   down, below, has the command at the point it belongs: after everything else
   that needs the cluster, right before `talosvm destroy -yes`. Anything that
   changes on the cluster after it is lost. Do not destroy anything until it
   has printed `Saved`.
3. **Destroy the cluster.** The rest of Tearing a cluster down, below.
4. **Bring the cluster up.** Adding a cluster, above, steps 8 and 9, in the
   order they are written.
5. **Restore, inside step 9.** Bootstrap Argo CD, above, has the command at the
   point it belongs: after the management namespaces and the Ceph key, and
   before the root `Application`. Do not apply the root until it has exited
   cleanly, printing `Restored`, or `Nothing restored` if you skipped every
   resource on purpose.
6. **Check the root came through.** Once `private-ca-bundle` is `Healthy`,
   compare the root the cluster serves with `$root_ca`, the copy exported the
   last time the root was new (The private CA, above). Neither verb writes that
   file, so the two agreeing means the cluster has the root your clients trust.

   ```sh
   export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
   kubectl -n default get configmap private-ca -o jsonpath='{.data.ca\.crt}' |
     openssl x509 -noout -subject -fingerprint -sha256
   openssl x509 -in "$root_ca" -noout -subject -fingerprint -sha256
   ```

   Different means cert-manager made a new root, or the state file held the
   wrong one (What goes wrong, below). Comparing with the fingerprint
   `state restore` printed proves less: that came from the file, so it shows
   the restore took effect, not that the file held the right root.

7. **Finish Adding a cluster, from step 10.** The restore changes three of its
   steps:

   | Step | With the state restored |
   | --- | --- |
   | 10, Trust the new root | Restart `argocd-server`. Export nothing: the laptop and the claude VM keep the root they trust. |
   | 13, The workers' trust | Still needed. The patch went with the old nodes. |
   | 15, The Anthropic key | Skipped if `state restore` listed the key as created or left as is: `kagent/kagent-anthropic` copies it. If it skipped the key, enter it here. |

8. **Keep the file.** `~/$cluster-state.json.gpg` holds the cluster's root key.
   It stays on the claude VM beside the only secret key that opens it, so
   losing the VM loses both: a copy of the file and an export of the key
   somewhere else are yours to make.

Every resource is required, and a missing one fails the verb and writes
nothing. `-skip <namespace>/<name>`, repeatable, on both verbs, is the only way
past that, and each verb prints what it skipped:

- A cluster without `kagent`, such as `cartography`, has no Anthropic key, so
  it passes `-skip seabank-prj-platform/anthropic-api-key` to both verbs.
- A rebuild that changes the cluster's domain wants a new root, since the
  root's subject and name constraints come from it. Pass `-skip
  cert-manager/private-ca-root` to `state restore`, and do steps 10 and 13 of
  Adding a cluster as for a new cluster.
- A rebuild that changes the brand wants a new root for the same reason, and
  moves the platform namespace too, so the saved key belongs to a namespace
  nothing reads. Name the old namespace as saved, and skip both: `state restore
  -platform-namespace seabank-prj-platform -skip cert-manager/private-ca-root
  -skip seabank-prj-platform/anthropic-api-key`. It prints `Nothing restored`,
  which here is right. Do steps 10 and 13 as for a new cluster, and enter the
  key by hand at step 15.

After either, the file holds the old root, so the next `state save -force`
refuses: move the file aside yourself first.

#### What goes wrong

- **The save says the file exists.** On a cluster that was restored from that
  file, or saved to it before, pass `-force`. No save deletes a file: the old
  one stays as `~/$cluster-state.json.gpg.<UTC timestamp>`. `-force` refuses if
  the file cannot be decrypted, or if it holds a different root from the
  cluster's. That refusal means the cluster was rebuilt without a restore, and
  the file holds the root your clients trust: do not save, and follow the root
  recovery below. To take the cluster's new root on purpose, move the file
  aside yourself, then save.
- **The save cannot decrypt what it wrote.** The key is locked or the file is
  encrypted to a key that is not yours. It installs nothing. Run it in an
  `attach-gpg` pane, and check `-recipient`.
- **A resource is missing.** The save names it and writes nothing. Fix it, such
  as by entering the Anthropic key, or skip it by name if the cluster really
  does not have it.
- **The root was applied before the restore. Tear down WITHOUT saving.** The
  existing file holds the good root, and this cluster holds a new one, so there
  is nothing here to keep. cert-manager has signed certificates from the new
  root, and `state restore` refuses. Follow Tearing a cluster down, below, and
  leave out its save block. Then bring the cluster up from step 8 of Adding a
  cluster, and restore the existing file inside step 9. Do not reach for
  `state restore -force`: it swaps the root under certificates already signed
  by the other one, and cert-manager does not reissue them.
- **Someone entered the key before the restore.** `state restore` refuses a
  Secret with different data. Delete it to restore the saved one, or skip it to
  keep the one on the cluster. A rerun leaves identical Secrets alone.

### Tearing a cluster down

Destroying the VMs leaves two things behind. `cluster.sh gen` reuses a
`secrets.yaml` it finds, so the state directory must move aside for the new
cluster to get new secrets. Its RBD images also stay in the cluster's Ceph
pool, because nothing deletes the PersistentVolumes. Each image is named in
its PV, so list the images while the cluster still answers, then remove them
once the VMs are gone. From the repository's root:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
images=$(kubectl get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeAttributes.imageName}{"\n"}{end}')
echo "$images"   # csi-vol-..., one per volume

set -a; . ~/.config/holos/proxmox.env; set +a
go run ./providers/talos/cmd/talosvm destroy -cluster "${cluster:?set cluster first}"   # prints the calls only
```

The cluster still answers here, and this is the last time it will. Save its
state now, as the last step before destroying it, in an `attach-gpg` pane
(Rebuilding a cluster, above). A cluster that is going for good, with nothing
to carry over, skips this block. On a cluster without `kagent`, add `-skip
seabank-prj-platform/anthropic-api-key`.

```sh
go run ./cmd/state save -cluster "${cluster:?set cluster first}"
```

**Do not go on until it has printed `Saved`. Anything it did not save is lost
with the VMs.**

```sh
go run ./providers/talos/cmd/talosvm destroy -cluster "${cluster:?set cluster first}" -yes
mv ~/.config/holos/talos/$cluster ~/.config/holos/talos/$cluster.old-$(date +%FT%H%M)

# printf, so zsh splits the list too.
for i in $(printf '%s\n' "$images"); do ssh root@r620a rbd rm --no-progress "${ceph_pool:?set ceph_pool first}/$i"; done
ssh root@r620a rbd ls "${ceph_pool:?set ceph_pool first}"   # empty: the pool is the cluster's alone
```

`rbd rm` refuses an image that still has a watcher. A destroyed VM's watch
expires within about 30 seconds, so retry once if it refuses. Keep the old
state directory until the new cluster is up, then delete it, since it holds
the old cluster's secrets. The new cluster comes up by Adding a cluster, above,
from step 8, with `state restore` inside step 9 (Rebuilding a cluster, above),
which brings the private root back. Without it the root is new (The private
CA, above). The pool and the Ceph user stay, so a rebuild keeps both, and the
key.

### Logging in

Through Keycloak, as a member of `/platform/owners`, which the `argocd-rbac-cm`
policy makes `role:admin`: in a browser at
`https://argocd.$domain`, **Log in via Keycloak**, or with the
CLI, `argocd login argocd.$domain --grpc-web --sso`, which
opens a browser and listens on `localhost:8085`. Argo CD's `oidc.config` names
the realm's issuer, the public client `argocd` with PKCE and the scopes
`openid profile email groups`, and no secret (The realm, above). The server
checks Keycloak's certificate against the private root without it being in
git: it mounts the namespace's `private-ca` ConfigMap and adds it to Go's
system trust with `SSL_CERT_DIR`, so `oidc.config` has no `rootCA`. Groups are
matched by full path, leading slash included. Nobody else from Keycloak gets a
role.

That member is the realm's one user, `jeff` (`jeff@bank.internal`), imported
with the realm and put in `/platform/owners` by the platform controller (The realm,
above). Log in as `jeff`, with the generated password from the `keycloak`
namespace:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n keycloak get secret seabank-user-jeff -o jsonpath='{.data.password}' | base64 -d; echo
```

Argo CD's **User Info** page, or `argocd account get-user-info`, then shows
`/platform/owners` under Groups, with the leading slash.

Or as the local `admin`, kept until the milestone's login through Keycloak
has passed, once the laptop trusts the private root (The private CA,
above). The gateway serves HTTP/1.1 to the server, so the CLI needs
`--grpc-web`; without it the CLI warns and falls back to it.

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
argocd login argocd.$domain --grpc-web --username admin --password \
  "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
argocd app list
```

Without the gateway, as during a bootstrap, a port-forward reaches the
server, which serves plain HTTP:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
argocd login localhost:8080 --plaintext --username admin --password ...
```

### Syncing

From then on a cluster changes through `main`. Within 30 seconds of a merge
Argo CD sees the new head, checks its signature, and syncs every
`Application` whose directory changed; the root creates the `Application` of
a component new to the registry. A change made on the cluster by hand is
reverted. To sync at once, or to see why something did not:

```sh
argocd app sync argocd-apps    # the root: new and changed Applications
argocd app sync cert-manager   # one component
argocd app get cert-manager    # conditions, and the last sync's result
```

A manual sync checks the signature too.

### Taking objects over from the hand applies

A cluster built before Argo CD, as the first garage cluster was, had every
component applied by hand with field manager `holos`. A cluster built from
scratch with Argo CD, as `treasury` is, has nothing to take over. Argo CD
takes those objects over without a conflict: its server-side apply forces conflicts, and its manifests are
the hand applies' manifests, so the two managers share each field. The
exceptions are atomic fields the API server fills in, such as a
NetworkPolicy's `ingress` rules or a `fieldRef`, which pass to
`argocd-controller` alone. The only change Argo CD makes is its tracking
annotation, which bumps each Deployment's `generation` without a rollout.

`holos` would still co-own the rest, so once every `Application` is
`Synced`, remove `holos` from each object's managed fields. This changes
ownership only, never a value; the `test` refuses the patch if the entry
moved, and objects Argo CD has not applied are skipped:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
for f in $d/*/*.yaml; do
  i=$(kubectl get -f $f --show-managed-fields -o json 2>/dev/null | jq '
    if any(.metadata.managedFields[]; .manager == "argocd-controller")
    then .metadata.managedFields | map(.manager == "holos") | index(true)
    else null end')
  [ -n "$i" ] && [ "$i" != null ] || continue
  kubectl patch -f $f --type=json -p "[
    {\"op\": \"test\", \"path\": \"/metadata/managedFields/$i/manager\", \"value\": \"holos\"},
    {\"op\": \"remove\", \"path\": \"/metadata/managedFields/$i\"}]"
done
```

### Taking CoreDNS over from Talos

A cluster created before `KubeCoreDNSConfig` was disabled still has Talos's
CoreDNS, recorded in Talos's manifest inventory
(`kube-system/talos-bootstrap-manifests-inventory`). Applying this component
over it fails on the Deployment's immutable selector, and a later
`talosctl upgrade-k8s` would prune the platform's objects of the same names:
it deletes any object in its inventory that carries no inventory annotation.
Switch over once, before applying the `coredns` component, from the
repository root:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
export TALOSCONFIG=~/.config/holos/talos/$cluster/talosconfig
# 1. Disable Talos's CoreDNS (the patch is already in controlplane.yaml).
set -a; . ~/.config/holos/proxmox.env; set +a
providers/talos/cluster.sh gen $cluster
providers/talos/cluster.sh apply $cluster

# 2. Remove Talos's objects and their inventory entries. This is what
#    `talosctl upgrade-k8s` would do, without touching the control plane.
kubectl -n kube-system delete deployment/coredns configmap/coredns \
  serviceaccount/coredns service/kube-dns
kubectl delete clusterrole/system:coredns clusterrolebinding/system:coredns
kubectl -n kube-system patch configmap talos-bootstrap-manifests-inventory --type=json -p '[
  {"op":"remove","path":"/data/_system__coredns_rbac.authorization.k8s.io_ClusterRole"},
  {"op":"remove","path":"/data/_system__coredns_rbac.authorization.k8s.io_ClusterRoleBinding"},
  {"op":"remove","path":"/data/kube-system_coredns__ConfigMap"},
  {"op":"remove","path":"/data/kube-system_coredns__ServiceAccount"},
  {"op":"remove","path":"/data/kube-system_coredns_apps_Deployment"},
  {"op":"remove","path":"/data/kube-system_kube-dns__Service"}]'

# 3. Check that upgrade-k8s no longer touches CoreDNS.
talosctl upgrade-k8s --to 1.37.1 --dry-run 2>&1 | grep -iE 'coredns|kube-dns' || echo clean
```

Running `talosctl upgrade-k8s` for real in place of step 2 also works: it
prunes Talos's CoreDNS objects and their inventory entries itself, but it
also restarts the control plane components. A cluster created with the patch
in place never has Talos's CoreDNS and needs none of this.

## Check

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n argocd get applications   # every one Synced and Healthy
kubectl get nodes
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status
kubectl get ciliumloadbalancerippools

kubectl create ns $cluster-test
kubectl -n $cluster-test run dnstest --image=docker.io/nicolaka/netshoot:v0.14 \
  --restart=Never --command -- sleep 3600
kubectl -n $cluster-test exec dnstest -- dig +search kubernetes.default A
kubectl -n $cluster-test exec dnstest -- dig +short @10.96.0.10 test.$domain A   # the gateway's address, 10.20.0.30
kubectl -n $cluster-test exec dnstest -- dig @10.96.0.10 test.bank.internal A | grep status       # NXDOMAIN, in no cluster's subdomain
kubectl -n $cluster-test create deployment echo \
  --image=registry.k8s.io/e2e-test-images/agnhost:2.53 -- /agnhost netexec --http-port=8080
kubectl -n $cluster-test expose deployment echo --type=LoadBalancer --port=80 --target-port=8080
kubectl -n $cluster-test get svc echo   # EXTERNAL-IP from 10.20.0.31-.33, never the gateway's .30
curl http://<external-ip>/hostname   # from the garage network
kubectl delete ns $cluster-test
```

CoreDNS's metrics show which upstream answered: a `bank.internal` query is
counted against `to="192.168.2.1:53"`, anything else against host DNS,
`to="169.254.116.108:53"`:

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n $cluster-test exec dnstest -- curl -s http://<coredns pod IP>:9153/metrics |
  grep proxy_request_duration_seconds_count
```

The private CA: a `Certificate` in a namespace outside `PrivateCA.requesters`
is denied by `deny-all` (Approval, above), and a certificate the issuer did sign
chains to the root in the namespace's bundle, within its name constraints.

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl create ns ca-test
kubectl -n ca-test get configmap private-ca   # trust-manager's copy of the root
kubectl -n ca-test apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: test}
spec:
  secretName: test-tls
  dnsNames: [test.ca-test.$domain]
  issuerRef: {group: cert-manager.io, kind: ClusterIssuer, name: private-ca}
EOF
until kubectl -n ca-test get certificaterequest test-1 >/dev/null 2>&1; do sleep 1; done
kubectl -n ca-test wait --for=condition=Denied certificaterequest/test-1 --timeout=30s
t=$(mktemp -d)
kubectl -n istio-ingress get secret wildcard-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > $t/leaf.pem
kubectl -n ca-test get configmap private-ca -o jsonpath='{.data.ca\.crt}' > $t/root.pem
openssl verify -CAfile $t/root.pem $t/leaf.pem
kubectl delete ns ca-test
```

Storage: `ceph-rbd` the only default class, the driver's pods on the
workers only, and a volume written on the first worker read back on the last,
its image in the pool while the claim exists and gone once it is deleted.

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl get sc                             # ceph-rbd (default), local-path
kubectl -n ceph-csi-rbd get pods -o wide   # a nodeplugin and a provisioner on each worker
kubectl create ns storage-test
kubectl -n storage-test apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: rbd}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}
EOF
# pod <name> <node> <command>: a pod on that node with the claim at /data.
pod() {
  kubectl -n storage-test apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $1}
spec:
  nodeName: $2
  containers:
  - name: c
    image: docker.io/library/busybox:1.37.0
    command: [sh, -c, '$3; sleep 3600']
    volumeMounts: [{name: d, mountPath: /data}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: rbd}}]
EOF
}
workers=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' --no-headers -o custom-columns=:.metadata.name)
pod writer "$(echo "$workers" | head -1)" 'hostname > /data/x'
kubectl -n storage-test wait --for=condition=Ready --timeout=2m pod/writer
ssh root@r620a rbd ls $ceph_pool           # csi-vol-...
kubectl -n storage-test delete pod writer
pod reader "$(echo "$workers" | tail -1)" 'cat /data/x'
kubectl -n storage-test wait --for=condition=Ready --timeout=2m pod/reader
kubectl -n storage-test logs reader        # writer, the pod that wrote it on the first worker
PV=$(kubectl -n storage-test get pvc rbd -o jsonpath='{.spec.volumeName}')
kubectl delete ns storage-test
kubectl wait --for=delete --timeout=2m pv/$PV   # the image goes with the PV
ssh root@r620a rbd ls $ceph_pool           # the csi-vol-... above is gone; the platform's own volumes stay
```

LoadBalancer addresses answer TCP and UDP on the Service's ports only; they
do not answer ping, and a connection to any other port is dropped, not
refused.

Istio and the gateway: the node agents on the workers only, every webhook
failing closed by its Service, the gateway at its pinned address, and hello
answering through it with a certificate that chains to the root, from the
garage network and from a pod. Until the private zone has its wildcard,
`--resolve` stands in for it.

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
kubectl -n istio-system get pods -o wide        # istiod, and istio-cni-node and ztunnel on each worker
kubectl get validatingwebhookconfiguration istio-validator-istio-system \
  -o jsonpath='{.webhooks[0].failurePolicy} {.webhooks[0].clientConfig.service.name}{"\n"}'   # Fail istiod
kubectl -n istio-ingress get gateway ingress     # ADDRESS 10.20.0.30, PROGRAMMED True
gw=$(kubectl -n istio-ingress get gateway ingress -o jsonpath='{.spec.addresses[0].value}')   # the pinned address
kubectl get ciliumloadbalancerippools            # $cluster: 0 available; $cluster-general: none CONFLICTING
kubectl get httproute -A                         # argocd, hello, https-redirect
kubectl get tlsroute -A                          # k8s, and ate with substrate-shim
kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration \
  -o custom-columns='NAME:.metadata.name,FP:.webhooks[*].failurePolicy,SVC:.webhooks[*].clientConfig.service.name'   # Fail everywhere, every one a Service

kubectl -n default get configmap private-ca -o jsonpath='{.data.ca\.crt}' > /tmp/root.pem
curl --resolve hello.$domain:443:$gw --cacert /tmp/root.pem https://hello.$domain/
curl -sI --resolve hello.$domain:80:$gw http://hello.$domain/   # 301 to https
curl -s --resolve argocd.$domain:443:$gw --cacert /tmp/root.pem https://argocd.$domain/api/version

kubectl create ns gw-test
kubectl label ns gw-test istio.io/dataplane-mode=ambient
kubectl -n gw-test run curl --image=docker.io/curlimages/curl:8.11.1 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"curl","image":"docker.io/curlimages/curl:8.11.1","command":["sleep","3600"],"volumeMounts":[{"name":"ca","mountPath":"/ca"}]}],"volumes":[{"name":"ca","configMap":{"name":"private-ca"}}]}}'
kubectl -n gw-test wait --for=condition=Ready pod/curl
kubectl -n gw-test exec curl -- curl -s --cacert /ca/ca.crt \
  --resolve hello.$domain:443:$gw https://hello.$domain/
kubectl -n gw-test exec curl -- curl -s http://hello.hello/   # pod to pod over HBONE
kubectl -n istio-system logs ds/ztunnel | grep 'connection complete'   # one ztunnel's; src.identity and dst.identity
kubectl delete ns gw-test
```

hello answers with the request it received: `X-Forwarded-Proto: https`, and
`RemoteAddr` the gateway pod's address, which ztunnel preserves.

The gateway's reserved address: another Service never gets it, even asking
for it, and the gateway's Service comes back at it after a delete, which
istiod answers by recreating it.

```sh
export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig
gw=$(kubectl -n istio-ingress get gateway ingress -o jsonpath='{.spec.addresses[0].value}')   # the pinned address
kubectl create ns lb-test
kubectl -n lb-test create service loadbalancer t1 --tcp=80:8080   # 10.20.0.31-.33
kubectl -n lb-test create -f - <<EOF
{"apiVersion": "v1", "kind": "Service", "metadata": {"name": "t30"},
 "spec": {"type": "LoadBalancer", "loadBalancerIP": "$gw", "ports": [{"port": 80}]}}
EOF
kubectl -n lb-test get svc t30 -o jsonpath='{.status.conditions[0].reason}{"\n"}'   # pool_selector_mismatch
kubectl -n istio-ingress delete svc ingress-istio
kubectl -n istio-ingress get svc ingress-istio   # EXTERNAL-IP 10.20.0.30 again
kubectl delete ns lb-test
```

On a fresh cluster, `cilium-dbg status` can report `Cluster health: 2/3`
for the first probe round, about two minutes: an agent probes a node's health
endpoint before that endpoint is up. Wait for the next round before reading
it as a fault.

## The control plane's mirror pods

While the control plane was `NotReady`, before its Cilium agent ran, the node
lifecycle controller treated it as a failed node once the workers were
`Ready`: it added the `node.kubernetes.io/not-ready:NoExecute` taint and,
after the default 300-second toleration, evicted the mirror pods of
kube-apiserver, kube-controller-manager and kube-scheduler, which the kubelet
recreated about every five minutes. With the agent on the control plane the
node is `Ready` and the mirror pods stay. If they cycle `Terminating` again,
the control plane has gone `NotReady`: check its `cilium` pod first.
