# Glossary

Terms the distro's documents use with a meaning of their own: the garage's names, the platform's,
and Agent Substrate's. A term used the ordinary Kubernetes, Istio or Talos way is not listed. The
details live in [holos/README.md](../holos/README.md), linked from each entry.

## Sites and clusters

**garage**
: The lab site the distro runs in: three Proxmox hosts, `r620a` to `r620c`, on the network
  10.20.0.0/24, with an OpenWrt router as its resolver. `sites.garage` in `holos/clusters.cue`
  holds its data ([Clusters](../holos/README.md#clusters)).

**treasury**
: The garage's first Talos cluster: control plane `treasury-cp-1` at 10.20.0.50 and workers
  `treasury-general-1` to `-3` at .51 to .53. Its admin kubeconfig is
  `~/.config/holos/talos/treasury/kubeconfig` on the machine that built it.

**cartography**
: The garage's second Talos cluster, independent of treasury: control plane `cartography-cp-1` at
  10.20.0.60 and workers `cartography-general-1` to `-3` at .61 to .63, with its ingress gateway at
  10.20.0.34.

**bank.internal**
: The garage's private DNS zone. Each cluster has a subdomain of it, so every service is
  `<svc>.<cluster>.bank.internal`, such as `keycloak.treasury.bank.internal`, and answers on its
  cluster's ingress gateway, 10.20.0.30 for treasury. Email addresses stay `<user>@bank.internal`.

**talosvm**
: The program that makes, resizes and restarts the cluster's Proxmox VMs,
  `go run ./providers/talos/cmd/talosvm`. It wires the Proxmox provider
  (`providers/proxmox`) into the Talos layer (`providers/talos`).

**private root**, **private CA**
: The cluster's own certificate authority, `Bank of the Salish Sea treasury root CA`. The
  `private-ca` ClusterIssuer issues from it, and every namespace has it as ConfigMap `private-ca`,
  key `ca.crt`. A laptop trusts it to reach `*.treasury.bank.internal`
  ([The private CA](../holos/README.md#the-private-ca)).

## The platform

**Bank of the Salish Sea**
: The distribution's brand, `Brand` in `holos/brand.cue`, which every name it chooses for itself is
  built from: `seabank-controller`, `seabank-prj-platform`, the Secrets Manager's title. A
  vendor's distribution sets its own. The software it is built with keeps its own names: the
  `holos` CLI, the `*.holos.run` API groups and `holos.run/*` keys, holos-controller.

**component**
: A directory under `holos/components/` that renders one set of manifests, synced by Argo CD as one
  Application. `holos/registry.cue` lists them in sync order
  ([Components](../holos/README.md#components)).

**stack**
: The platform's components as levels, by priority, with `required` at the bottom and `optional`
  at the top. A cluster takes the stack up to `standard`, plus the optional components it names in
  `components` and the ProjectClaims that select it. "Above" only ever means further up the stack,
  toward `optional`, never more important. Stack order is not sync order: the registry's order is,
  and `hello`, `standard`, syncs before `ceph-csi-rbd`, `important`
  ([The stack](../holos/README.md#the-stack)).

**priority**
: A registry entry's level in the stack, `priority` in `holos/registry.cue`, in Debian's
  vocabulary: `required`, `important`, `standard` or `optional`. Every entry states it, with no
  default ([The stack](../holos/README.md#the-stack)).

**layering violation**
: A component that depends on one above it in the stack, in the Kubernetes sense of the term.
  Nothing at the `standard` level may depend on the `optional` components above it in the stack
  ([The stack](../holos/README.md#the-stack)).

**render**
: `holos render platform`, which writes every component's manifests to `holos/deploy/`. The rendered
  tree is committed and never edited by hand ([Render](../holos/README.md#render)).

**platform secret**
: A Kubernetes Secret made through the Secrets Manager in project namespace `seabank-prj-platform`,
  such as the Ceph key. A consumer copies it into its own namespace through a `#ScopedSecretStore`
  ([Secrets Manager](../holos/README.md#secrets-manager)).

**`#ScopedSecretStore`**
: The CUE definition that renders a consumer's own SecretStore, allowed to read only the platform
  secrets it names.

**`#GeneratedSecret`**
: The CUE definition that renders an ExternalSecret whose generator makes a password once and keeps
  it in an immutable Secret ([External Secrets](../holos/README.md#external-secrets)).

**Secrets Manager**
: The Bank of the Salish Sea Secrets Manager, holos-run/secrets-manager, at
  `https://secrets.treasury.bank.internal`: the web UI where platform secrets are made.

**platform controller**, **holos-controller**
: The controller that manages Keycloak and Quay for the platform, such as each service's
  confidential client, from its own custom resources. The software is holos-controller; it runs as
  `seabank-controller` ([The realm](../holos/README.md#the-realm)).

**platform authenticator**, **holos-authenticator**
: The ext_authz server in front of the Kubernetes API at `k8s.treasury.bank.internal` that turns a
  verified Keycloak ID token into impersonation headers, so `kubectl` works with a Keycloak
  identity. The software is holos-authenticator; it runs as `seabank-authenticator`
  ([holos-authenticator](../holos/README.md#holos-authenticator)).

**ProjectClaim**
: A CUE collection in which a team claims a project, and from which its namespace, RoleBinding,
  Keycloak groups, Quay organization and Argo CD project are rendered on the clusters its required
  `clusterSelector` selects, a Kubernetes LabelSelector over each cluster's `metadata.labels`, and
  its Substrate atespace on those that name `substrate` and `substrate-shim`
  ([Projects](../holos/README.md#projects)).

## Identity and tokens

**ksa**
: A Kubernetes service account. "The `ate-client` ksa" is the ServiceAccount `ate-client` in
  namespace `ate-system`, and its principal is `system:serviceaccount:ate-system:ate-client`. A
  project with an atespace has a ServiceAccount of the same name in its namespace, which owns that
  atespace and nothing else; the documents call it `<project>/ate-client`, never the `ate-client`
  ksa.

**ksa token**
: A standard Kubernetes service account token: a short-lived JWT, signed by the cluster's API
  server, for one ksa and one or more audiences. It is minted with `kubectl create token`, which
  calls the TokenRequest API. A service checks it against the cluster's service account issuer, by
  signature and audience, as Substrate's API server does, and learns the ksa it names.

**ate-client ksa token**
: A ksa token for the `ate-client` ksa with the audience `api.ate-system.svc`, which is what
  Substrate's API server accepts. Older documents call it the `ate-client` token or the
  `ate-client` ServiceAccount token; they mean the same thing. The `ate-client` ksa is a
  [bootstrap owner](#substrate), so the token is the global admin credential for Substrate, and
  anyone who may `create` `serviceaccounts/token` in `ate-system` can mint it. Mint one from a
  laptop whose `KUBECONFIG` is the treasury kubeconfig:

  ```sh
  kubectl -n ate-system create token ate-client --duration=1h --audience=api.ate-system.svc > ate-client.token
  kubectl ate get actors -a demo --token-file ate-client.token
  rm ate-client.token
  ```

  A token with any other audience is refused with `Unauthenticated: invalid bearer token`. Without
  `--token-file`, `kubectl ate` mints the same token itself, for one hour.

**ID token**
: The OIDC ID token Keycloak issues, which is the only token the platform's services check, never the access
  token ([ADR 0002](adr/0002-oidc-id-tokens.md)). For the realm `default` and the client `kubectl`
  it has `aud` `kubectl`, carries the user's full-path `groups`, and lasts five minutes.

**kubelogin**
: The `kubectl oidc-login` plugin, which prints an ID token for the `kubectl` client, through a
  browser or the device-code grant.

**`/platform/owners`**
: The Keycloak group of the platform's operators. Members are Argo CD admins and may reach every
  atespace through the shim.

**SPIFFE ID**
: A workload identity URI, here `spiffe://cluster.local/ns/<namespace>/sa/<ksa>`, carried in a pod
  certificate.

**pod certificate**
: A certificate the kubelet obtains for a pod through a `podCertificate` projected volume (a
  PodCertificateRequest), renews before it expires, and writes into the pod's files. Substrate's
  signers issue them.

**pod identity signer**
: `podidentity.podcert.ate.dev/identity`, the signer whose pod certificates carry the pod's ksa as
  a SPIFFE ID. The router admits clients by it.

**servicedns signer**
: `servicedns.podcert.ate.dev/identity`, the signer of Substrate's serving certificates, such as
  the router's for `atenet-router.ate-system.svc`. Clients trust its ClusterTrustBundles labeled
  `podcert.ate.dev/canarying: live`.

## Substrate

**Agent Substrate**, **Substrate**
: The upstream project agent-substrate/substrate, Go module `go.ate.dev/substrate`, which runs
  agents as actors in gVisor sandboxes. The distro builds it from the fork holos-run/substrate, a
  submodule at `holos/vendor/substrate` ([the forks](forks.md),
  [Substrate](../holos/README.md#substrate)). Its names start with `ate`.

**atespace**
: Substrate's tenant: a named group of actor templates and actors, such as `demo` or `kagent`. It
  is an object in Substrate's database, not a Kubernetes namespace. A ProjectClaim makes one of the
  project's name, on a cluster that names `substrate` and `substrate-shim`
  ([Projects](../holos/README.md#projects)).

**actor template**
: The immutable recipe for an actor: its image, by digest, and its environment.

**actor**
: A sandboxed workload made from an actor template, named `<atespace>/<actor>`. It is suspended to
  a snapshot in RustFS and resumed when a request arrives.

**worker pool**
: A `WorkerPool`, the pods that actors run in. Treasury's is `ate-workers/gvisor`, three workers.

**atelet**
: The agent on each worker that runs its actors, and pulls their images itself.

**router**
: `atenet-router` in `ate-system`, the only way into an actor. It speaks mutual TLS and admits only
  clients whose pod certificate's SPIFFE ID is on its `--ingress-allowed-spiffe-ids`, then sends
  each request to the actor named in its `ate-target-actor` header.

**`ate-target-actor`**
: The request header the router routes on, `<atespace>/<actor>`. The shim sets it from the host
  name, replacing any value the client sent, and the router strips it before the actor sees the
  request.

**bootstrap owner**
: A principal given owner of Substrate's global scope by the API server's
  `--authz-bootstrap-owners`. Treasury's are the `ate-client` ksa and kagent's controller.

**`kubectl ate`**
: Substrate's kubectl plugin, built from `holos/vendor/substrate/cmd/kubectl-ate`. It port-forwards
  to Service `ate-system/api` through `KUBECONFIG`, and authenticates with an ate-client ksa token
  unless `--token-file` gives it another.

**ate-setup**
: Substrate's installer. The distro renders Substrate in CUE instead, and runs ate-setup only to create
  the key pools.

**key pools**
: The CA Secrets in `ate-system` that every pod certificate, actor token and egress MITM
  certificate chains to. ate-setup creates them once per cluster, by hand, and Argo CD does not
  track them ([Bringing Substrate up](../holos/README.md#bringing-substrate-up)).

**Substrate shim**, **shim**
: Component `substrate-shim`, the Istio Gateway `substrate-shim/ate` that is how a person reaches
  an actor, at `https://<actor>.<atespace>.ate.treasury.bank.internal`. It checks the caller's ID
  token and groups, sets `ate-target-actor`, and connects to the router with mutual TLS
  ([The Substrate shim](../holos/README.md#the-substrate-shim)).

**`ate-gateway`**, **`AteGateway`**
: `ate-gateway` is the ksa the shim's gateway pods run as, whose SPIFFE ID is on the router's
  allowed list. `AteGateway` is the CUE definition, in `holos/components/substrate-shim.cue`, that
  names it and the shim's atespaces, the platform's in `atespaces` and the claims' in `claimed`.

**kagent**
: The Kubernetes agent framework, built from the fork holos-run/kagent, that runs its agents as
  Substrate actors in atespace `kagent`.
