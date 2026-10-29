# Glossary

Terms the distro's documents use with a meaning of their own: the garage's names, Holos's, and
Agent Substrate's. A term used the ordinary Kubernetes, Istio or Talos way is not listed. The
details live in [holos/README.md](../holos/README.md), linked from each entry.

## Sites and clusters

**garage**
: The lab site the distro runs in: three Proxmox hosts, `r620a` to `r620c`, on the network
  10.20.0.0/24, with an OpenWrt router as its resolver. `sites.garage` in `holos/clusters.cue`
  holds its data ([Clusters](../holos/README.md#clusters)).

**treasury**
: The Talos cluster in the garage: control plane `treasury-cp-1` at 10.20.0.50 and workers
  `treasury-general-1` to `-3` at .51 to .53. Its admin kubeconfig is
  `~/.config/holos/talos/treasury/kubeconfig` on the machine that built it.

**bank.internal**
: The garage's private DNS zone. Every service is `<svc>.bank.internal` and answers on the ingress
  gateway, 10.20.0.30.

**talosvm**
: The program that makes, resizes and restarts the cluster's Proxmox VMs,
  `go run ./providers/proxmox/cmd/talosvm`.

**private root**, **private CA**
: The cluster's own certificate authority, `Holos treasury root CA`. The `private-ca` ClusterIssuer
  issues from it, and every namespace has it as ConfigMap `private-ca`, key `ca.crt`. A laptop
  trusts it to reach `*.bank.internal` ([The private CA](../holos/README.md#the-private-ca)).

## Holos

**component**
: A directory under `holos/components/` that renders one set of manifests, synced by Argo CD as one
  Application. `holos/registry.cue` lists them in sync order
  ([Components](../holos/README.md#components)).

**render**
: `holos render platform`, which writes every component's manifests to `holos/deploy/`. The rendered
  tree is committed and never edited by hand ([Render](../holos/README.md#render)).

**platform secret**
: A Kubernetes Secret made through the Secrets Manager in project namespace `holos-prj-platform`,
  such as the Ceph key. A consumer copies it into its own namespace through a `#ScopedSecretStore`
  ([Secrets Manager](../holos/README.md#secrets-manager)).

**`#ScopedSecretStore`**
: The CUE definition that renders a consumer's own SecretStore, allowed to read only the platform
  secrets it names.

**`#GeneratedSecret`**
: The CUE definition that renders an ExternalSecret whose generator makes a password once and keeps
  it in an immutable Secret ([External Secrets](../holos/README.md#external-secrets)).

**Secrets Manager**
: The Holos Secrets Manager, holos-run/secrets-manager, at `https://secrets.bank.internal`: the web
  UI where platform secrets are made.

**holos-controller**
: The controller that manages Keycloak for Holos, such as each service's confidential client, from
  its own custom resources ([The realm](../holos/README.md#the-realm)).

**holos-authenticator**
: Planned. A proxy in front of the Kubernetes API that turns a verified Keycloak ID token into
  impersonation headers, so `kubectl` works with a Keycloak identity.

**ProjectClaim**
: Planned. A CUE collection in which a team claims a project, and from which its namespaces,
  RoleBindings and, later, its Substrate atespace are rendered.

## Identity and tokens

**ksa**
: A Kubernetes service account. "The `ate-client` ksa" is the ServiceAccount `ate-client` in
  namespace `ate-system`, and its principal is `system:serviceaccount:ate-system:ate-client`.

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
: The OIDC ID token Keycloak issues, which is the only token Holos services check, never the access
  token ([ADR 0002](adr/0002-oidc-id-tokens.md)). For the realm `holos` and the client `kubectl`
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
  agents as actors in gVisor sandboxes. Holos builds it from the fork holos-run/substrate, a
  submodule at `holos/vendor/substrate` ([the forks](forks.md),
  [Substrate](../holos/README.md#substrate)). Its names start with `ate`.

**atespace**
: Substrate's tenant: a named group of actor templates and actors, such as `demo` or `kagent`. It
  is an object in Substrate's database, not a Kubernetes namespace.

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
: Substrate's installer. Holos renders Substrate in CUE instead, and runs ate-setup only to create
  the key pools.

**key pools**
: The CA Secrets in `ate-system` that every pod certificate, actor token and egress MITM
  certificate chains to. ate-setup creates them once per cluster, by hand, and Argo CD does not
  track them ([Bringing Substrate up](../holos/README.md#bringing-substrate-up)).

**Substrate shim**, **shim**
: Component `substrate-shim`, the Istio Gateway `substrate-shim/ate` that is how a person reaches
  an actor, at `https://<actor>.<atespace>.ate.bank.internal`. It checks the caller's ID token and
  groups, sets `ate-target-actor`, and connects to the router with mutual TLS
  ([The Substrate shim](../holos/README.md#the-substrate-shim)).

**`ate-gateway`**, **`AteGateway`**
: `ate-gateway` is the ksa the shim's gateway pods run as, whose SPIFFE ID is on the router's
  allowed list. `AteGateway` is the CUE definition, in `holos/components/substrate-shim.cue`, that
  names it and the shim's atespaces.

**kagent**
: The Kubernetes agent framework, built from the fork holos-run/kagent, that runs its agents as
  Substrate actors in atespace `kagent`.
