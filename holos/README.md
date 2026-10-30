# The Holos platform

This directory is the distro's Holos platform: CUE that renders every
component's Kubernetes manifests into `deploy/`, using Holos v1alpha6 as
released in holos v0.106.0. It is its own CUE module
(`go.holos.run/distro/holos`) beside the Go module at the repository root.

```text
holos/
├── cue.mod/        CUE module; holos init platform v1alpha6's schemas
├── clusters.cue    per-site and per-cluster data
├── registry.cue    the components, in sync order
├── collections.cue the ProjectClaim collection, bound into the platform, and its group and user definitions
├── argocd.cue      the repository, branch, project and signing keys Argo CD syncs with
├── webhooks.cue    the Services that serve admission webhooks
├── talos.cue       the control plane's Talos patch made from the above; talos_tool.cue writes it
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

## Clusters

`clusters.cue` holds everything that differs between clusters: the site the
cluster runs in (its private DNS zone and resolvers), the Kubernetes networks
Talos configured, the node uplink, and the cluster's block of LoadBalancer
addresses. Components read their cluster as `Cluster`; none names a cluster
or an address. Every cluster in `clusters` gets every component in the
registry (`registry.cue`), rendered to
`deploy/clusters/<cluster>/components/<component>/`, one file per resource.

The garage's ingress range is 10.20.0.30 to .49, sized for about six clusters
with three or four Gateway addresses each. `treasury` has the first four,
10.20.0.30 to .33. A new cluster takes the next free block:

```cue
clusters: example: {
	site: sites.garage
	loadBalancer: {start: "10.20.0.34", stop: "10.20.0.37"}
}
```

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
and render; the Gateway's `spec.addresses` and both pools follow, and so does
the control plane's Talos patch of webhook host entries (`cue cmd talos`).
Apply that with `talosctl` (`providers/proxmox/talos/README.md`) as soon as
the Gateway reports its new address: in between, the API server dials the
old one and every webhook call is refused. Then change the router's
`*.bank.internal` record to match.

## Components

| Component | What it renders |
| --- | --- |
| `cilium` | Cilium 1.20.4 from its Helm chart, in `kube-system`: CNI, kube-proxy replacement, LB IPAM and L2 announcements |
| `cilium-resources` | The cluster's two `CiliumLoadBalancerIPPool`s, one reserving the gateway's address and one for the rest of the block, a `CiliumL2AnnouncementPolicy` on `eth0`, and the `allow-ambient-hostprobes` `CiliumClusterwideNetworkPolicy` |
| `coredns` | CoreDNS from the CoreDNS project's Helm chart, replacing the one Talos deploys, with the site's private zone forwarded to its resolvers |
| `argocd` | Argo CD v3.5.6 from argo-helm's `argo-cd` chart 10.11.6, in `argocd`, syncing this repository's `main` |
| `gateway-api` | The Gateway API v1.6.3 CRDs, standard channel, vendored from the release, ahead of Istio |
| `cert-manager` | cert-manager v1.21.3 from Jetstack's OCI chart, in `cert-manager`, with its CRDs and its webhook reached through the gateway, and its own approver off once the cluster enforces its webhooks |
| `approver-policy` | approver-policy v0.29.0 from Jetstack's OCI chart, in `cert-manager`, with its `CertificateRequestPolicy` CRD and its webhook reached through the gateway at its `.svc` name |
| `private-ca` | The self-signed bootstrap `Issuer`, the root `Certificate`, the `private-ca` `ClusterIssuer`, and the `CertificateRequestPolicy`s and RBAC every certificate request is approved by |
| `trust-manager` | trust-manager v0.25.0 from Jetstack's OCI chart, in `cert-manager`, with its `Bundle` CRD and its webhook reached through the gateway |
| `private-ca-bundle` | The `private-ca` `Bundle`: the root as ConfigMap `private-ca`, key `ca.crt`, in every namespace |
| `istio-base` | Istio 1.31.3's CRDs from its OCI `base` chart, the `istio-system` namespace (privileged) and the default revision's validating webhook |
| `istiod` | Istio's control plane in ambient mode, in `istio-system`, with its webhooks reached through the gateway, the private root as its JWKS trust and holos-authenticator as an ext_authz provider |
| `istio-cni` | Istio's CNI node agent, chained after Cilium on every worker |
| `ztunnel` | Ambient's node proxy on every worker |
| `cloudnative-pg` | The CloudNativePG operator 1.30.1 from its `cloudnative-pg` chart 0.29.1, in `cnpg-system`, with its CRDs and its webhooks reached through the gateway; no `Cluster` |
| `external-secrets` | The External Secrets operator v2.14.0 from its `external-secrets` chart 2.14.0, in `external-secrets`, with its CRDs and its webhook reached through the gateway; no store, no `ExternalSecret` |
| `management-namespaces` | The Secrets Manager's management organization `holos-org-platform` and project `holos-prj-platform`, and the `RoleBinding` granting the server its `secrets` verbs in the project |
| `ingress-gateway` | The `ingress` `Gateway` in `istio-ingress` at the pinned address, its `*.bank.internal` certificate, the HTTP to HTTPS redirect, Argo CD's `HTTPRoute`, the admission webhooks' TLS passthrough listeners and `TLSRoute`s, the `ate` passthrough listener for `*.ate.bank.internal`, and the `k8s` passthrough listener for `k8s.bank.internal` |
| `hello` | An echo service in the ambient namespace `hello`, at `hello.bank.internal` |
| `ceph-csi-rbd` | ceph-csi 3.17.1's RBD driver from its `ceph-csi-rbd` chart, in `ceph-csi-rbd` (privileged), against the hosts' Ceph, and the default StorageClass `ceph-rbd` |
| `local-path` | local-path-provisioner v0.0.37 from its release manifest, in `local-path-storage` (privileged), and the `local-path` StorageClass, not the default |
| `rustfs` | RustFS 1.0.4 standalone from its `rustfs` chart 1.0.4, in the ambient namespace `rustfs`: one pod, one `ceph-rbd` volume, the S3 endpoint `rustfs-svc.rustfs.svc:9000`, generated keys, and a Job that registers the `substrate` and `quay` buckets and users |
| `keycloak-operator` | The Keycloak Operator 26.8.1 from the release's manifests, vendored, in the ambient namespace `keycloak`, with its four CRDs; no `Keycloak` |
| `keycloak` | Keycloak 26.8.1 in `keycloak`, at `keycloak.bank.internal`: the `Keycloak` resource, its one-instance CloudNativePG cluster `keycloak-db` on `ceph-rbd`, and its generated admin and database credentials |
| `holos-controller` | holos-controller 0.22.0 from aavis-ops' manifests, vendored, in the ambient namespace `holos-controller`, with its eight CRDs and the private root in its trust; no resources of its kinds |
| `keycloak-realm` | The realm `holos`: its `KeycloakRealmImport` and generated secrets, the users `jeff` and `svc-quay-controller`, holos-controller's credential, the `Instance`, the group `/platform/owners` and its membership, and the Job that writes the `Instance`'s `caBundle` |
| `holos-authenticator` | holos-authenticator 0.21.0 in the ambient namespace `holos-authenticator`: its `Backend` CRD, vendored, the manager and its RBAC, the impersonator and its grants, the `Backend` for `k8s.bank.internal`, `/platform/owners` as `cluster-admin`, and the ClusterIP `Gateway` `k8s` behind `ingress`'s `k8s` listener, with the ext_authz policy, the Lua `TrafficExtension` and the TLS to the API server |
| `secrets-manager` | The Holos Secrets Manager v0.19.0 in the ambient namespace `secrets-manager`, at `secrets.bank.internal`, its Keycloak `Client` `secrets-manager`, and its RBAC |
| `substrate` | Agent Substrate from the holos-run fork's install tree at the submodule's commit, images from `ghcr.io/holos-run/substrate` by digest, in `ate-system` (privileged, not in the mesh) and `podcertificate-controller-system`: the pod certificate controller, the API server, the IdP, the controller, the router, the egress gateway, the Kubernetes Secrets credential provider and atelet; its one-instance CloudNativePG cluster `substrate-db` and role Job, snapshots in RustFS's bucket `substrate`, and the gVisor `WorkerPool` `gvisor` in `ate-workers` |
| `substrate-shim` | The Substrate shim: the ClusterIP `Gateway` `ate` in `substrate-shim` behind `ingress`'s `ate` listener, a listener and `*.<atespace>.ate.bank.internal` certificate per atespace (`demo`, `kagent`), the Keycloak token and group policy, the Lua `TrafficExtension` that sets `ate-target-actor` from the host, the `HTTPRoute`s in `ate-system` and the mutual TLS to the router |
| `kagent-crds` | kagent's eight `api.kagent.dev` CRDs from the holos-run fork's `kagent-crds` OCI chart, which Argo CD neither prunes nor deletes |
| `kagent` | kagent from the holos-run fork's `kagent` OCI chart, images by digest, in `kagent` (not in the mesh), at `kagent.bank.internal` behind oauth2-proxy and Keycloak: the controller, the UI, the read-only tool server and oauth2-proxy; its schema and roles in `substrate-db`, with their role Job and passwords in `ate-system`; its Keycloak `Client` `kagent`, the copy of the platform secret `anthropic-api-key`, a zero-replica placeholder `WorkerPool` `gvisor` naming the platform pool, and the NetworkPolicies that admit only the hop before each pod |
| `quay` | Quay 3.17.6 in the ambient namespace `quay`, at `quay.bank.internal`: one Deployment, its one-instance CloudNativePG cluster `quay-db`, an ephemeral Redis, blobs in RustFS's bucket `quay`, its Keycloak `Client` `quay`, the `Organization` `demo` and its public `Repository` `demo/echo`, and holos-controller's Quay credential |
| `project-<name>` | One per ProjectClaim in `projects/`, from `components/project` (Projects, below): the project's ambient namespace, its Keycloak groups, owners and membership, its Quay `Organization`, the owners' `RoleBinding`, and its `AppProject` and `Application`; none today |
| `argocd-apps` | The `platform` `AppProject` and an Argo CD `Application` per component, its own being the root `Application` |

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

Every Cilium pod, the agent and Envoy DaemonSets and the operator, has a
required node affinity `holos.run/pod-network NotIn [none]`, so nothing runs
on the control plane and it stays `NotReady` by design. Cilium registers no
admission webhook and no APIService.

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
platform owns CoreDNS: `providers/proxmox/talos/patches/controlplane.yaml`
sets `KubeCoreDNSConfig` `enabled: false`, and this component deploys CoreDNS
as the same `kube-dns` Service at `10.96.0.10`, the address every kubelet was
given. The chart's CoreDNS is 1.14.7, the version Talos 1.14.4 deploys.

The Corefile has two server blocks: `.` resolves cluster names and forwards
the rest to the node's resolver (Talos host DNS, which forwards to the LAN
resolver), and `bank.internal.` forwards straight to 192.168.2.1, so the
private zone does not depend on how the nodes' resolvers are set.

### Admission webhooks

The control plane is off the pod network (ADR 0001), so the API server
reaches an admission webhook as a client outside the cluster would: through a
URL on the ingress Gateway's address, 10.20.0.30, where the `webhooks`
listener on port 9443 passes TLS through to the webhook's Service, routed on
SNI by one `TLSRoute` per webhook (The ingress gateway, below). The control
plane is on the same LAN as the address, so nothing listens on the control
plane and no proxy is in between.

Every component that registers a webhook renders its configurations with
`#WebhookPatch` (`components/webhooks.cue`), which sets, from the cluster's
`webhooks` in `clusters.cue`:

- `clientConfig.url`: `https://<service>.<namespace>.webhooks.<cluster>.<privateDomain>:9443/<path>`,
  for example
  `https://cert-manager-webhook.cert-manager.webhooks.treasury.bank.internal:9443/validate`.
  The hostname is the SNI the Gateway routes on and a DNS name on the
  webhook's serving certificate. The control plane resolves it through a
  Talos host entry to the Gateway's address (`talos.cue`,
  `providers/proxmox/talos/README.md`), so the API server does not depend on
  the router; the router's `*.bank.internal` record gives the same answer
  everywhere else. One webhook is the exception: approver-policy signs its
  own serving certificate for `cert-manager-approver-policy.cert-manager.svc`
  and nothing else, so its entry in `webhooks.cue` sets that as its
  `hostname`, and its URL is
  `https://cert-manager-approver-policy.cert-manager.svc:9443/validate-policy-cert-manager-io-v1alpha1-certificaterequestpolicy`
  (interview Q68). The control plane's host entry points the `.svc` name at
  the Gateway like the others, the Gateway has a listener of its own for it
  (The ingress gateway, below), and a pod still resolves it to the Service
  through cluster DNS. The router's wildcard does not cover it, so it
  answers only on the control plane.
- `failurePolicy`: `Ignore` while `webhooks.enforcing` is false, the
  default; `Fail` once it is set. It is one flag per cluster, ADR 0001's two
  provisioning steps. `treasury` enforces.
- `timeoutSeconds`: 3, not the default 10.

The webhook's Service is registered in `webhooks.cue`, the one list the
listener's `TLSRoute`s and the control plane's host entries are rendered
from. A new entry also needs its hostname on the webhook's serving
certificate, and its host entry applied to a running control plane with
`talosctl`: Argo CD does not reach the machine config. cert-manager's
cainjector fills each configuration's `caBundle`; it does so for a URL as it
does for a Service. istiod fills its own (see Istio below). CloudNativePG
and External Secrets would fill their own too, each with a CA of its own,
and are told not to (CloudNativePG and External Secrets, below).

A webhook call costs little: a server-side dry run of a `Certificate` takes
about 110 ms, a `ConfigMap`'s about 160 ms. While nothing answers on 9443 the
gateway's address drops the connection, so every call to a webhook failing
open waits the full 3 seconds (3.1s for a `Certificate`) and the API server
logs `Failed calling webhook, failing open ... context deadline exceeded`.
With `Fail` the request is refused instead.

Check that every webhook answers through the Gateway with a request each
must refuse, as server-side dry runs; each error names the webhook that
refused it:

```sh
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
kubectl -n kube-system logs kube-apiserver-treasury-cp-1 --since=10m | grep -c 'failing open'   # 0
```

A `Bundle` with two kinds of source is refused too, but by the CRD's own
validation, before any webhook is called, so it proves nothing about the
path. kubectl rewrites CloudNativePG's refusal, a `422 Invalid`, as `The
Cluster "bad" is invalid: ... Can't set fixed configuration parameter`,
without the webhook's name; `-v=8` shows the API server's message, which
names it. From the garage network each hostname answers on the Gateway's
address with the webhook's own certificate, and a name no route matches is
reset:

```sh
for h in cert-manager-webhook.cert-manager cnpg-webhook-service.cnpg-system external-secrets-webhook.external-secrets istiod.istio-system trust-manager.cert-manager; do
  echo | openssl s_client -connect 10.20.0.30:9443 -servername $h.webhooks.treasury.bank.internal 2>/dev/null |
    openssl x509 -noout -ext subjectAltName
done
echo | openssl s_client -connect 10.20.0.30:9443 -servername cert-manager-approver-policy.cert-manager.svc 2>/dev/null |
  openssl x509 -noout -issuer -ext subjectAltName   # issuer=CN=approver-policy-webhook-ca
```

With `Fail`, every webhook depends on the Gateway and on istiod, which
programs it: while the gateway's Pods are down, a request a webhook matches
is refused, such as any write of a cert-manager resource, a `Bundle`, an
Istio resource or a CloudNativePG resource, and any write or delete of an
`ExternalSecret` or a store. Pods and other core objects are
not matched (the sidecar injector matches only Pods that ask for a sidecar),
so the gateway and istiod can always be restarted.

#### Building a cluster with enforcement

A cluster is built with `webhooks.enforcing` false and turned on afterwards,
as ADR 0001 says. Built with it on, the bootstrap does not converge:
cert-manager's webhook configuration arrives with `Fail` and a URL on a
Gateway that does not exist yet, so it refuses `private-ca`'s `Issuer`,
`Certificate` and `ClusterIssuer`. `private-ca` never reports `Healthy`, so
the root `Application` never creates the ones after it. The Gateway could
not come up anyway: it needs istiod, which mounts the `private-ca` ConfigMap
that trust-manager writes from a `Bundle` its own webhook would refuse, and
a certificate cert-manager's webhook would refuse. Nothing in that loop can
start first.

So to rebuild `treasury`, or to build a new cluster:

1. Leave `webhooks.enforcing` at its default, false, for the cluster in
   `clusters.cue`, render, merge, and bootstrap (Bootstrap Argo CD, below).
2. Once every `Application` is `Synced` and `Healthy`, check every webhook
   with the requests above. A webhook that answers refuses them under
   `Ignore` too.
3. Merge `webhooks: enforcing: true`. The same flag turns cert-manager's
   own approver off (`disableAutoApproval`), so from then on approver-policy
   alone approves certificate requests (Approval, under The private CA,
   below).

Until step 3, cert-manager approves every certificate request itself, as it
did before approver-policy. approver-policy decides the same requests too,
where it can bind a policy: it approves what a policy allows, and through
`deny-all` it denies what none does, such as a project's request or a new
component's with no `PrivateCA.requesters` entry. Whichever answers first
sets the condition, so during a bootstrap such a request may go either way.
It cannot be otherwise: while cert-manager's webhook fails open, a request
made while the webhook is unreachable has no `spec.username`, which the
webhook stamps, and approver-policy cannot bind a policy to a request with
no user. It leaves such a request unprocessed, and on a rebuild those are
the root and the Gateway's wildcard, made before the Gateway the webhook is
reached through: approver-policy alone would deadlock the bootstrap. Once
the cluster enforces, cert-manager's webhook refuses any request it cannot
stamp, so every request has a user. `treasury`'s root request,
`private-ca-root-1`, dates from that time, has no user, and was approved by
cert-manager.

Between the Gateway coming up and step 3, istiod switches its validators to
`Fail` (see Istio below) and Argo CD sets them back to `Ignore`, so
`istio-base` and `istiod` go `OutOfSync` from time to time. Step 3 ends it.

The Gateway, its listener and the `TLSRoute`s must already be live when
`enforcing` turns on. Argo CD's server-side apply dry-runs every object in an
`Application`, and the dry run calls the webhooks, so if cert-manager's
configuration turned to `Fail` before `ingress-gateway` synced, that sync
would be refused and the listener that fixes it would never land. The
rebuild procedure has the listener in step 1. Turning enforcement on in the
same commit that adds the listener needs the Gateway and `TLSRoute`s applied
by hand first, which is how the first garage cluster, before its rebuild as
`treasury`, turned enforcement on.

`istio-ingress` carries `cert-manager.io/disable-validation: "true"`, so the
wildcard `Certificate` never depends on the webhook path, and a commit that
breaks the path, such as a bad listener, a lost address or a host entry that
no longer matches, can still be rolled back through Argo CD. Any other sync
whose objects a webhook matches cannot be until the path works again; then
apply `gateway-ingress.yaml` and `tlsroute-*.yaml` from a good checkout by
hand with `--server-side --field-manager=argocd-controller` and
`argocd app sync ingress-gateway`.

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
`rotationPolicy` is `Never`, so a reissue keeps the same root.

A recreated cluster has a new root. Export it for the laptop, and for the
kubectl plugin, from any namespace's ConfigMap:

```sh
kubectl -n default get configmap private-ca -o jsonpath='{.data.ca\.crt}' > ~/treasury-root-ca.pem
openssl x509 -in ~/treasury-root-ca.pem -noout -subject -dates -fingerprint -sha256
# macOS: trust it for TLS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/treasury-root-ca.pem
# Debian or Ubuntu
sudo cp ~/treasury-root-ca.pem /usr/local/share/ca-certificates/treasury-root-ca.crt
sudo update-ca-certificates
```

Before replacing a trusted root, remove the old one: macOS's Keychain Access
lists it as `Holos treasury root CA`. curl takes it without installing it,
`--cacert ~/treasury-root-ca.pem`.

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
`keycloak.bank.internal`, or a CA, which laptops, pods, holos-controller and
the Talos nodes all trust. Once the cluster enforces its webhooks that
approver is off (`disableAutoApproval` in `components/cert-manager`), and
approver-policy (`components/approver-policy`) decides instead, by the
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
most of the platform's do not.

| Policy | Issuer | Namespace | Allows | Bound to |
| --- | --- | --- | --- | --- |
| `private-ca-root` | `Issuer` `private-ca-bootstrap` | `cert-manager` | the root's common name and subject, a CA | cert-manager's controller |
| `trust-manager-webhook` | `Issuer` `trust-manager` | `cert-manager` | trust-manager's webhook's two DNS names and its common name | cert-manager's controller |
| `private-ca-<namespace>` | `ClusterIssuer` `private-ca` | that namespace | exactly the DNS names, usages and common name its `Certificate`s list, no CA | cert-manager's controller |
| `deny-all` | any | any | nothing: it requires a DNS name from an empty list | `system:authenticated` |

The `private-ca-<namespace>` policies are `ate-system`, `cnpg-system`,
`external-secrets`, `holos-authenticator`, `istio-ingress` and
`substrate-shim`. A policy's `values` are patterns in which `*` matches any
string, so a namespace with a wildcard name, `istio-ingress`'s
`*.bank.internal` or `substrate-shim`'s atespace wildcards, also has a CEL
rule that each name be one of the listed ones exactly; without it
`*.bank.internal` would allow `keycloak.bank.internal`.

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
kubectl get certificaterequestpolicies   # every one READY True
kubectl get certificaterequests -A -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,USER:.spec.username,APPROVED:.status.conditions[?(@.type=="Approved")].message,DENIED:.status.conditions[?(@.type=="Denied")].message'
# ate-system  substrate-db-server-2  system:serviceaccount:cert-manager:cert-manager  Approved by CertificateRequestPolicy: "private-ca-ate-system"  <none>
```

A denied `Certificate` is `Ready=False`, and its `Issuing` condition and
events give the request's message; here one for `keycloak.bank.internal` in
a namespace outside the list:

```text
$ kubectl -n approver-test describe certificate keycloak
...
    Message:                 The certificate request has failed to complete and will be retried: No policy approved this request: [deny-all: spec.allowed.dnsNames.values: Invalid value: ["keycloak.bank.internal"]]
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
`[private-ca-holos-authenticator: spec.allowed.dnsNames.values: Invalid
value: ["keycloak.bank.internal"]: k8s.bank.internal]`. The issuers'
`WaitingForApproval` events on a request are normal. A request pending with
no condition and an `Unprocessed` event matched no policy, which `deny-all`
rules out for any request with a user.

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

Argo CD syncs every component from its directory under
`holos/deploy/clusters/<cluster>/components/` on `main` of
https://github.com/holos-run/distro.git. The repository is public, so Argo CD
reads it anonymously: there is no deploy key and no repository Secret.
`argocd.cue` has the repository, the branch, the project and the signing
keys.

GitHub cannot reach the garage to deliver a webhook, so Argo CD polls:
`timeout.reconciliation` is 30 seconds with no jitter, and a merge to `main`
is synced in under a minute. `argocd app sync` syncs at once.

`argocd-apps` renders the `platform` `AppProject` and one `Application` per
entry in the registry, for its cluster:

- `argocd-apps` is last; its own `Application` is the root, which syncs the
  directory the `Application`s are rendered to. A component added to the
  registry gets its `Application` from the merge alone. Each `Application`'s
  sync wave is the component's index in the registry, and `argocd-cm` has
  the health check for `Application`s that Argo CD dropped in 1.8: an
  `Application` reports the health of its objects, `Missing` until they
  exist. The waves order only the root creating the `Application`s at
  bootstrap: it creates one, waits for it to report `Healthy`, then creates
  the next. Once created, each `Application` polls `main` and syncs on its
  own, so a later merge syncs the components it touches in parallel, and a
  component whose dependency is not ready yet relies on its retry. The
  `AppProject` is wave -1. `argocd-cm` also overrides Argo CD's health check
  for `ExternalSecret`, for generated secrets (External Secrets, below).
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

Login is through Keycloak, realm `holos`, client `argocd`, or as the local
`admin`, which stays until the milestone's login through Keycloak has passed
(Logging in, below); Dex is off. Argo CD is at https://argocd.bank.internal, `global.domain`, through the
ingress gateway, which terminates TLS with the private CA's wildcard and
sends plain HTTP to the server: `server.insecure` is set, so the server
serves no TLS of its own, on either of its Service's ports. The `HTTPRoute`
is rendered by `ingress-gateway`, not by this component, so this component
still applies by hand before the Gateway API CRDs exist. The `argocd`
namespace is not in ambient, so the hop from the gateway to the server is
plain HTTP inside the cluster; enrolling it would put ztunnel in the path
Argo CD needs to repair the platform. Argo CD runs Deployments and one
StatefulSet, no DaemonSet, so the control plane's `NoSchedule` taint keeps
it on the workers. Its pods meet the restricted Pod Security standard, so the
`argocd` namespace needs no label. The images are pinned by digest.

### Istio

Istio 1.31.3 in ambient mode (interview Q16), from the charts at
`oci://ghcr.io/istio/release/charts`, in four components applied in this
order: `istio-base` (the CRDs and the `istio-system` namespace), `istiod`,
`istio-cni` and `ztunnel`. `istio.cue` has the release, the images, pinned by
digest, and the trust domain, `cluster.local`. A workload's mesh identity is
`spiffe://cluster.local/ns/<namespace>/sa/<service account>`.

- `istio-system` is labeled `pod-security.kubernetes.io/enforce=privileged`:
  istio-cni and ztunnel run privileged pods on every node, which Talos's
  baseline enforcement refuses.
- istio-cni and ztunnel tolerate every taint, so both carry Cilium's
  affinity, `holos.run/pod-network NotIn [none]`, and stay off the control
  plane, where they could never start. istiod is a Deployment and the
  control plane's taint keeps it off.
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
  turned on for holos-authenticator, which in the end runs on a Gateway of
  its own and needs no waypoint, so nothing relies on it yet.
- The mesh configuration lists one extension provider,
  `holos-authenticator`: ext_authz over gRPC to
  `holos-authenticator.holos-authenticator.svc.cluster.local:9000`, two
  seconds, not failing open (holos-authenticator, below).
- A namespace joins the mesh with the label
  `istio.io/dataplane-mode=ambient` (`Istio.ambient`). Substrate's
  namespaces stay out: their port-scoped NetworkPolicies would have to admit
  the mesh port 15008, and with it every mesh identity.

istiod's webhooks follow the platform's model (Admission webhooks, above).
The validator `istio-validator-istio-system`, `istio-base`'s
`istiod-default-validator` and the sidecar injector (idle in ambient: it
matches only pods or namespaces that ask for a sidecar) all name
`https://istiod.istio-system.webhooks.<cluster>.<privateDomain>:9443`, and
`ISTIOD_CUSTOM_HOST` adds that hostname to istiod's serving certificate.
istiod manages these configurations itself, which works with the URL and
with Argo CD:

- It writes its own CA's root into every webhook's `caBundle`, whether
  `clientConfig` names a Service or a URL. The render leaves `caBundle` out,
  and Argo CD diffs server-side, so the field istiod owns is no difference.
- It switches a validator's `failurePolicy` from `Ignore` to `Fail` only once
  a dry-run create of a known-invalid Istio `Gateway` is refused by the
  webhook. While the URL is unreachable the API server fails open, the dry
  run passes, and istiod leaves `Ignore` alone: it retries about once a
  minute and logs `Not ready to switch validation to fail-closed`. The
  configurations' `resourceVersion` does not move.
- Once the Gateway reaches istiod, the dry run is refused and istiod sets
  `Fail`. It remembers that until it restarts: from then on it sets `Fail`
  again whenever the configuration changes, even after the Gateway stops
  reaching it. With `webhooks.enforcing` false the render says `Ignore`, so
  Argo CD's self-heal and istiod take turns, `istio-base` and `istiod` go
  `OutOfSync` between Argo CD's self-heal attempts, and every turn bumps the
  configurations' `resourceVersion`. With `enforcing` true the two agree and
  nothing moves. Measured on the first garage cluster: about ten updates a
  configuration in the first 90 seconds with the listener up and `Ignore`
  rendered; none in six minutes with `Fail` rendered.
- Turning `enforcing` off on a cluster whose istiod has seen the webhook
  answer therefore needs an istiod restart as well
  (`kubectl -n istio-system delete pod -l app=istiod`) once the Gateway
  no longer reaches it, or the two keep taking turns.

The chart's own URL values, `istiodRemote.injectionURL` and
`base.validationURL`, would set the URL too, but not the timeout or the
enforcement flag's `failurePolicy`, so `#WebhookPatch` is used, as for every
other component.

### The ingress gateway

One Gateway API `Gateway`, `istio-ingress/ingress` of class `istio`, for
every platform service (`IngressGateway` in `components/ingress.cue`). istiod
deploys it: a Deployment and a `LoadBalancer` Service both named
`ingress-istio`, which it owns; none is rendered.

- **Address.** `spec.addresses` requests 10.20.0.30, the cluster's
  `loadBalancer.gateway`, which the cluster's pool reserves for the gateway
  (see Clusters). istiod sets it as the Service's `loadBalancerIP`, LB IPAM
  allocates it from that pool, and one worker answers ARP for it. The private
  zone's `*.bank.internal` points there. The request is `spec.addresses`, not
  Cilium's `lbipam.cilium.io/ips` annotation (`io.cilium/lb-ipam-ips` is its
  older alias): it is the Gateway API's own field and the Gateway reports the
  address it was given beside it, and Cilium 1.20 reads `loadBalancerIP` and
  the annotation alike, as one list of requested addresses. Kubernetes
  deprecated `loadBalancerIP`, but Cilium supports it until it is removed;
  if istiod or Cilium stops honoring it, the annotation can reach the Service
  through the Gateway's `spec.infrastructure.annotations`. The pool would
  hand the gateway the address without any request, since it is the only
  address its Service can take; the request makes a mismatch show as a
  Pending Service with a reason rather than a different address.
- **Hostnames.** Every service is `<service>.<privateDomain>` (interview
  Q40), `hello.bank.internal`, `argocd.bank.internal`,
  `keycloak.bank.internal`, `secrets.bank.internal`, named in
  `IngressGateway.hosts`, one label under the zone and no cluster name.
- **Listeners.** `https` on 443 for `*.bank.internal`, terminating TLS with
  the `wildcard` `Certificate` from `ClusterIssuer` `private-ca` (Secret
  `istio-ingress/wildcard-tls`), open to routes from every namespace. `http`
  on 80 takes only the `https-redirect` route, which answers every request
  with a 301 to the same URL over HTTPS. A route attaches with
  `IngressGateway.parentRef`, which names the `https` listener.
- **Webhooks listener.** `webhooks` on 9443 for
  `*.webhooks.<cluster>.<privateDomain>`, protocol `TLS` in `Passthrough`
  mode: the gateway reads the SNI and forwards the connection, and the
  webhook's Pods terminate TLS. It accepts only `TLSRoute`s, and only from the
  namespaces of the Services in `webhooks.cue` (`cert-manager`,
  `cnpg-system`, `external-secrets`, `istio-system`), selected by
  `kubernetes.io/metadata.name`.
  This component renders one `TLSRoute` per entry from the registry, in the
  entry's own namespace, matching its hostname and forwarding to the
  Service's port.
  Being in the backend's namespace, a route needs no `ReferenceGrant`; routes
  in `istio-ingress` would need one in each webhook namespace, more objects
  for the same result, since only platform namespaces can attach either way.
  A route matching another webhook's hostname would gain nothing: the API
  server checks the serving certificate against the webhook's `caBundle`.
  Every route is rendered here,
  not by the webhook's component, so the listener and its routes change in
  one sync. istiod adds 9443 to the gateway's Service.
  A webhook hostname outside `*.webhooks.<cluster>.<privateDomain>` gets a
  listener of its own on 9443, `webhooks-<entry>`, for that one name,
  otherwise the same, taking `TLSRoute`s only from its Service's namespace,
  and its route attaches there: today `webhooks-cert-manager-approver-policy`
  for `cert-manager-approver-policy.cert-manager.svc` (Admission webhooks,
  above).
- **Ate listener.** `ate` on 443 for `*.ate.<privateDomain>`, protocol `TLS`
  in `Passthrough` mode, beside `https` on the same port: Envoy matches the
  SNI to the most specific name, so `echo.demo.ate.bank.internal` comes here
  and every other host under the zone to `https`. It accepts only
  `TLSRoute`s from `substrate-shim`, whose one route forwards the connection
  to the Substrate shim's own Gateway (The Substrate shim, below). `ingress`
  never terminates those connections, so none of the shim's policy runs on
  it.
- **K8s listener.** `k8s` on 443 for `k8s.<privateDomain>`, protocol `TLS`
  in `Passthrough` mode, an exact name, so it wins over `https`'s wildcard.
  It accepts only `TLSRoute`s from `holos-authenticator`, whose one route
  forwards the connection to holos-authenticator's own Gateway
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
`ceph.user`): `treasury` uses pool `k8s-rbd` as `client.k8s`, whose caps are
`profile rbd` on that pool. The driver creates nothing on the Ceph side.

The `ceph-rbd` class is the cluster default: ext4, image features
`layering,exclusive-lock,object-map,fast-diff`, volume expansion on, reclaim
policy `Delete`, and `Immediate` binding, since an image attaches to any
node. Volumes are `ReadWriteOnce`. There is no CephFS, no snapshot controller
and no `VolumeSnapshotClass`; the provisioner's `csi-snapshotter` sidecar,
which the chart always renders, is patched out until CNPG backups need it.

- ceph-csi is 3.17.1, not the latest, 3.18.1: from 3.18.0 its image is built
  on Rocky Linux 10, whose glibc needs x86-64-v3, and the garage's Xeon
  E5-2670 hosts have no AVX2, so the plugin exits with `Fatal glibc error:
  CPU does not support x86-64-v3`. 3.17.1 is on CentOS Stream 9 with
  Tentacle's client libraries.
- The monitors are listed by their v1 addresses, port 6789, which the kernel
  RBD client maps with by default. RBD is built into the Talos kernel, so the
  node plugin loads no module; the chart's read-only `/lib/modules` mount is
  unused. kubelet's directory is Talos's `/var/lib/kubelet`, the chart's
  default.
- The node plugin runs privileged with host networking and kubelet's plugin
  paths, so the component labels `ceph-csi-rbd`
  `pod-security.kubernetes.io/enforce=privileged`. The node plugin's
  DaemonSet and the provisioner carry Cilium's affinity,
  `holos.run/pod-network NotIn [none]`; the provisioner's three replicas take
  one worker each, by the chart's required pod anti-affinity.
- ceph-csi registers no admission webhook and no APIService.

The Ceph user's key is never in git, since the repository is public. Ceph
keeps it, outside the cluster, so `ceph auth get-key client.k8s` reads it
again for a rebuilt cluster. It is a platform secret, `ceph-client-k8s`
(`Cluster.ceph.secret`), with keys `userID` and `userKey`, in the management
namespace, `holos-prj-platform`, written there once per cluster at bootstrap
(Bootstrap Argo CD, below). It carries the label
`app.kubernetes.io/managed-by=holos.run` and the annotation
`holos.run/share-roles='[{"principal":"/platform/owners","role":"owner"}]'`,
so the Secrets Manager lists it under Platform/Platform and platform owners
can read it. No `Application` tracks it, so Argo CD neither prunes nor
reverts it, and the namespace carries `Prune=false,Delete=false`.

`ceph-csi-rbd` copies it into its namespace through its own store,
`SecretStore` `platform` (Per-namespace stores, under Secrets Manager), whose
Role may `get` that one Secret, and `ExternalSecret` `ceph-client-k8s`, with
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
kubectl -n ceph-csi-rbd get secretstore,externalsecret   # Valid; SecretSynced
kubectl -n ceph-csi-rbd get secret ceph-client-k8s -o jsonpath='{.metadata.labels.reconcile\.external-secrets\.io/managed} {.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'   # true ExternalSecret/ceph-client-k8s
cmp -s <(kubectl -n ceph-csi-rbd get secret ceph-client-k8s -o jsonpath='{.data.userKey}' | base64 -d) \
  <(ssh root@r620a ceph auth get-key client.k8s) && echo same || echo differ
```

To rotate the key, give Ceph a new one, write it into the management copy,
and force a refresh rather than wait the hour. Rotating invalidates the old
key at once: provisioning and staging fail until the copy refreshes, and a
volume already mapped keeps the old key in the node's kernel client, which
fails the next time it authenticates, such as after a monitor or OSD
restart. So restart every pod with a `ceph-rbd` volume afterwards, which
stages its volume again with the new key:

```sh
ssh root@r620a ceph auth rotate client.k8s > /dev/null
key=$(ssh root@r620a ceph auth get-key client.k8s) && [ -n "$key" ] &&
printf %s "$key" | jq -Rc '{data: {userKey: @base64}}' |
  kubectl -n holos-prj-platform patch secret ceph-client-k8s --type=merge --patch-file=/dev/stdin
unset key
kubectl -n ceph-csi-rbd annotate externalsecret ceph-client-k8s force-sync=$(date +%s) --overwrite
```

A cluster that ran on a Secret made by hand in `ceph-csi-rbd`, as `treasury`
did, hands over in place. Write the management copy with the bootstrap
step's `key=$(ssh …)` pipeline alone, check that `holos-prj-platform` holds
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
Secret `cnpg-ca-secret`, and a serving certificate for the Service's
cluster names only, Secret `cnpg-webhook-cert`, and every hour writes that
CA into both configurations' `caBundle`; it has no setting to add a DNS
name. `WEBHOOK_CERT_DIR`, set on the Deployment, turns all of that off: the
operator serves `apiserver.crt` and `apiserver.key` from the directory and
leaves the configurations alone. The component mounts Secret
`cnpg-system/cnpg-webhook-tls` there, from `Certificate` `cnpg-webhook`,
which `private-ca` issues for the Service's `.svc` name and the webhook
hostname. The configurations carry `cert-manager.io/inject-ca-from:
cnpg-system/cnpg-webhook`, so cainjector writes the private root into
their `caBundle`, and nothing else writes it. The root does not change when
the certificate is renewed, and the operator reloads the files when the
kubelet updates them. The operator reads the variable before its
ConfigMap, so it cannot go in `config.data`.

The component comes before `ingress-gateway` in the registry: its
`TLSRoute`, which `ingress-gateway` renders, is in `cnpg-system`, so the
namespace must exist first. It needs only cert-manager and `private-ca`.

Check that a one-instance `Cluster` comes up on `ceph-rbd`, takes a
connection with its app credentials, and leaves no volume once deleted:

```sh
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
and a serving certificate for the Service's cluster names only, into Secret
`external-secrets-webhook`, and writes that CA into both configurations'
`caBundle` and the CRDs'. The component sets `certController.create: false`
and `webhook.certManager.enabled: true`, which drops the cert-controller
and that Secret from the output and puts `cert-manager.io/inject-ca-from:
external-secrets/external-secrets-webhook` on both configurations, so
cainjector writes the private root into their `caBundle` and nothing else
writes it. The chart's own `Certificate` has no setting for another DNS
name, so it is off too, and the component renders `Certificate`
`external-secrets-webhook`, which `private-ca` issues for the Service's
`.svc` name and the webhook hostname into the Secret the webhook mounts.
The webhook mints and rotates nothing: it serves the Secret's files,
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

The component comes before `ingress-gateway` in the registry: its
`TLSRoute`, which `ingress-gateway` renders, is in `external-secrets`, so
the namespace must exist first. It needs only cert-manager and
`private-ca`.

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
  one per consumer. The access key is the user's name in RustFS.

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

To rotate a consumer's key, rotate its Secret as above. Only the Job's
pods name it, and they are gone once it succeeds, so there is nothing to
scale down or pause: check that no pod names it, rotate, and sync
`rustfs` (`argocd app sync rustfs`). The Job adds the new user and
removes the old one, whose access key no longer matches, so the old key
stops working at once; then rotate the consumer's copy.

```sh
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
for k in RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY; do
  [ "$(kubectl -n rustfs get secret rustfs-root -o jsonpath="{.data.$k}" | base64 -d)" = \
    "$(kubectl -n rustfs exec deploy/rustfs -c rustfs -- printenv $k)" ] && echo "$k matches"
done
```

Check the store, the Job and the policies, with a pod holding the
consumers' keys:

```sh
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
`https://keycloak.bank.internal`, which is also the issuer every token
carries: `https://keycloak.bank.internal/realms/<realm>`. Pods and the
laptop resolve the name alike, to the gateway, so a client in the cluster
calls the same URL a browser does. This is the server and its database; the
realm `holos` is `keycloak-realm`'s (The realm, below), and the master realm
holds only the admin.

Two components, so Argo CD applies the CRDs before the resource that uses
them:

- `keycloak-operator` is the Keycloak Operator 26.8.1 from the release's
  manifests, `kubernetes/` at tag 26.8.1 of
  https://github.com/keycloak/keycloak-k8s-resources, vendored unmodified
  in `components/keycloak-operator/vendor/26.8.1/` and rendered with
  `#FileArtifact`, which gives the namespace-less manifests the namespace as
  `kubectl apply -n keycloak` would. It holds all four CRDs, `Keycloak`,
  `KeycloakRealmImport`, `KeycloakOIDCClient` and `KeycloakSAMLClient`: the
  operator starts a controller for each, and one without its CRD stops it.
  The CRDs carry `Prune=false,Delete=false`, since deleting one deletes
  every resource of its kind. The operator watches its own namespace only,
  registers no admission webhook, and gets a restricted security context
  the release leaves out. This component renders the namespace, `keycloak`,
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
  `HTTPRoute` `keycloak` sends `keycloak.bank.internal` to Service
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
`https://keycloak.bank.internal/admin/`:

```sh
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
kubectl -n keycloak get cluster,keycloak,pods,pvc   # healthy, Ready, keycloak-db-1 Bound on ceph-rbd
kubectl -n keycloak get pod keycloak-0 -o jsonpath='{.spec.containers[0].args}'   # ends in start
kubectl -n keycloak get secret keycloak-admin keycloak-db \
  -o custom-columns='NAME:.metadata.name,TYPE:.type,IMMUTABLE:.immutable,OWNER:.metadata.ownerReferences'
kubectl -n keycloak get configmap private-ca -o jsonpath='{.data.ca\.crt}' > root.pem
curl -s --cacert root.pem https://keycloak.bank.internal/realms/master/.well-known/openid-configuration |
  jq -r .issuer                                     # https://keycloak.bank.internal/realms/master
u=$(kubectl -n keycloak get secret keycloak-admin -o jsonpath='{.data.username}' | base64 -d)
p=$(kubectl -n keycloak get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d)
curl -s --cacert root.pem https://keycloak.bank.internal/realms/master/protocol/openid-connect/token \
  -d grant_type=password -d client_id=admin-cli --data-urlencode "username=$u" \
  --data-urlencode "password=$p" | jq 'has("access_token")'   # true
unset u p
```

### The realm

The platform's realm is `holos`, issuer
`https://keycloak.bank.internal/realms/holos`. holos-controller 0.22.0 has no
kind for a realm, a client scope or a protocol mapper, nor a field for the
device grant, so the realm comes in two halves (interview Q50):

- A `KeycloakRealmImport`, `holos` in `keycloak`, creates the realm with
  what the controller cannot reconcile:
  - the `groups` client scope, whose `oidc-group-membership-mapper` writes
    each user's groups by full path (`/platform/owners`) into the claim
    `groups` of the ID token, the access token and userinfo (Q6). It is a
    realm default default scope, so every client gets it, the controller's
    included. An import that lists any client scope gets none of Keycloak's
    built-in ones, so those are listed too, as the master realm of a fresh
    26.8.1 has them (`components/keycloak-realm/client-scopes.json`).
  - the public client `kubectl`, with the device grant, and the standard
    flow for kubelogin's loopback redirects. PKCE is not required on it:
    Keycloak 26.8.1 then demands a `code_challenge` on the device grant too,
    which not every device-flow client sends.
  - the public client `argocd`, with PKCE S256 required (Q51), redirects
    `/auth/callback` and `/pkce/verify` on `https://argocd.bank.internal` and
    `http://localhost:8085/auth/callback` for the CLI.
  - the confidential client `svc-holos-controller`, client credentials only,
    whose service account holds the `realm-management` roles
    `manage-clients`, `manage-users`, `query-clients` and `query-groups`.
    Not `manage-realm`: aavis-ops grants it only for a `Group`'s
    `custodians`, which need fine-grained admin permissions, and nothing
    here uses them, so the realm leaves `adminPermissionsEnabled` off.
  - the user `jeff`, `jeff@bank.internal`, with the realm role
    `default-roles-holos`. An imported user gets only the roles it lists, and
    without that role's `offline_access` Keycloak refuses the Secrets
    Manager's login, which asks for that scope.
  - the service user `svc-quay-controller`, `svc-quay-controller@bank.internal`,
    Quay's superuser, which `cmd/quay-bootstrap` logs in to Quay as (Quay,
    below). Its first and last name and its verified email are set, so
    Keycloak never interposes its `VERIFY_PROFILE` form, and it holds
    `default-roles-holos` as `jeff` does. A realm imported before it was
    added has it only once it is created by hand (Quay, below).
- holos-controller's resources, in `keycloak` beside the import: the
  `Instance` `holos`, the `Group` `platform-owners` at path
  `platform/owners`, and the `GroupMembership` `platform-owners` putting
  `jeff@bank.internal` in it. The controller finds a member by email among
  the realm's users, so the imported user needs no `User` resource. All three
  are in the `Instance`'s namespace, so there is no `ReferenceGrant`. The
  controller creates the parent group `/platform`, which it does not own.

Two components. `holos-controller` is the manager, from aavis-ops at tag
`holos-controller-v0.22.0`: all eight CRDs (`keycloak.holos.run`,
`quay.holos.run`, `security.holos.run`; the manager starts a controller for
every kind) with `Prune=false,Delete=false`, its RBAC and its Deployment,
vendored unmodified in `components/holos-controller/vendor/0.22.0/`, with the
image set to `ghcr.io/holos-run/holos-controller:holos-controller-v0.22.0`
pinned by digest. It registers no webhook. It mounts the namespace's
`private-ca` ConfigMap at `/etc/ssl/private-ca` and adds it to Go's system
trust with `SSL_CERT_DIR=/etc/ssl/certs:/etc/ssl/private-ca`, as
argocd-server does, so the Quay resources need no `caBundle` (Quay, below).
`keycloak-realm`, after it, is
everything above plus the credential, so the CRDs are established before
Argo CD applies the resources.

The realm's three secrets are generated in `keycloak` (Generated secrets,
above), because the import's placeholders read Secrets in the import's own
namespace: `svc-holos-controller`, username the client ID, password the
client's secret, `holos-user-jeff`, username `jeff`, and
`svc-quay-controller`, username `svc-quay-controller`. The import's
`spec.placeholders` hands their passwords to the import Job as environment
variables, which Keycloak puts in place of `${SVC_HOLOS_CONTROLLER_CLIENT_SECRET}`,
`${JEFF_PASSWORD}` and `${SVC_QUAY_CONTROLLER_PASSWORD}`, so no value is in
the resource or in git.

holos-controller reads its credential from its own namespace, from the
downward API's `POD_NAMESPACE`, whatever the `Instance`'s namespace. An
`ExternalSecret` there, `holos-controller-keycloak-creds`, copies
`svc-holos-controller` into the keys the controller reads, `clientId` and
`clientSecret`, through `SecretStore` `keycloak`, External Secrets'
`kubernetes` provider, which authenticates as ServiceAccount
`keycloak-secret-reader` and may `get` that one Secret in `keycloak`: a
per-namespace store, `#ScopedSecretStore` (Secrets Manager, below), with
`source: "keycloak"`. The
value is generated once, in one place; the copy is not immutable and follows
its source hourly, or at once with
`kubectl -n holos-controller annotate externalsecret holos-controller-keycloak-creds force-sync=$(date +%s) --overwrite`.

The `Instance` names `https://keycloak.bank.internal`, through the gateway,
whose certificate is the private CA's. The root is minted in the cluster, so
it is not rendered (Q52): the `PostSync` Job `instance-cabundle`, in
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

**The import is one-shot.** The operator runs the import as Job `holos`
with `--override false`, from the server's image straight into the
database; a realm that exists is left as it is, and the `KeycloakRealmImport`
reports `Done`. So a change to the realm in `keycloak-realm.cue` renders and
syncs, but changes nothing in Keycloak. To apply one, re-import, which
drops the realm: every session, the users' passwords other than the
imported ones, and every client and group the controller made, until it
makes them again. With automation paused on `keycloak-realm` (and on the
root, `argocd-apps`, which would turn it back on):

```sh
# 1. Let the controller remove what it made: its finalizers delete the
#    groups, memberships and clients in Keycloak. Deleting the realm first
#    would leave its resources reporting errors with finalizers stuck.
kubectl -n keycloak delete groupmembership,group --all     # and any Client or User in other namespaces
# 2. The import, then the realm, with the master admin's token.
kubectl -n keycloak delete keycloakrealmimport holos
t=$(curl -s --cacert root.pem https://keycloak.bank.internal/realms/master/protocol/openid-connect/token \
  -d grant_type=password -d client_id=admin-cli --data-urlencode "username=$u" --data-urlencode "password=$p" | jq -r .access_token)
curl -s --cacert root.pem -X DELETE -H "Authorization: Bearer $t" https://keycloak.bank.internal/admin/realms/holos -w '%{http_code}\n'  # 204
# 3. Turn automation back on; the sync re-creates the import, the groups and
#    the memberships, and its PostSync Job runs again.
```

`u` and `p` are the master admin's, as in the check under Keycloak, above.
The generated Secrets are kept, so the controller's credential and jeff's
password survive a re-import. This procedure was run once on treasury. The
import Job's completed pod names both Secrets, so rotating either (Generated
secrets, above) needs that pod gone first, and a re-import after, since the
realm holds the values it was imported with.

jeff's password, to log in at `https://keycloak.bank.internal/realms/holos/account`
or to Argo CD:

```sh
kubectl -n keycloak get secret holos-user-jeff -o jsonpath='{.data.password}' | base64 -d
```

Check the realm, the controller and a token, without printing a secret
(`root.pem`, `u` and `p` as under Keycloak, above):

```sh
curl -s --cacert root.pem https://keycloak.bank.internal/realms/holos/.well-known/openid-configuration |
  jq -r .issuer                                  # https://keycloak.bank.internal/realms/holos
kubectl -n keycloak get keycloakrealmimport holos \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].status}'   # True
kubectl -n holos-controller get deploy,externalsecret,secretstore   # 1/1, SecretSynced, Valid
kubectl -n keycloak get instance,group,groupmembership             # READY True
t=$(curl -s --cacert root.pem https://keycloak.bank.internal/realms/master/protocol/openid-connect/token \
  -d grant_type=password -d client_id=admin-cli --data-urlencode "username=$u" --data-urlencode "password=$p" | jq -r .access_token)
a=https://keycloak.bank.internal/admin/realms/holos
uid=$(curl -s --cacert root.pem -H "Authorization: Bearer $t" "$a/users?email=jeff@bank.internal&exact=true" | jq -r '.[0].id')
cid=$(curl -s --cacert root.pem -H "Authorization: Bearer $t" "$a/clients?clientId=kubectl" | jq -r '.[0].id')
curl -s --cacert root.pem -H "Authorization: Bearer $t" \
  "$a/clients/$cid/evaluate-scopes/generate-example-id-token?userId=$uid&scope=openid" |
  jq -c '{aud, groups}'                          # {"aud":"kubectl","groups":["/platform/owners"]}
curl -s --cacert root.pem https://keycloak.bank.internal/realms/holos/protocol/openid-connect/auth/device \
  -d client_id=kubectl -d scope=openid | jq 'has("device_code")'   # true
```

### holos-authenticator

`holos-authenticator` puts the Kubernetes API at `https://k8s.bank.internal`
behind a Keycloak login (interview Q60 to Q63): a person's kubeconfig
carries the ID token kubelogin prints for the `kubectl` client, and the API
server sees the request as an impersonation of them, `oidc:<username>` with
their groups by full path, so Kubernetes RBAC does the rest.
`HolosAuthenticator` (`components/holos-authenticator.cue`) has the release,
the names, and the users and groups that may be impersonated.

holos-authenticator 0.21.0, from aavis-ops, is an Envoy external
authorization server, plaintext gRPC on 9000, and a controller of
`Backend` resources (`authenticator.holos.run/v1alpha1`) in its own
namespace. It is not a proxy: Envoy asks it about each request. A request
takes this path:

1. `ingress`'s `k8s` listener passes the connection through, on SNI, to the
   ClusterIP Service `k8s-istio` of the `Gateway` `holos-authenticator/k8s`
   (`TLSRoute` `holos-authenticator/k8s`).
2. That Gateway terminates TLS with the `Certificate` `k8s` from the
   `private-ca` ClusterIssuer.
3. The `CUSTOM` `AuthorizationPolicy` `k8s` sends every request to the
   extension provider `holos-authenticator` (Istio, above). The manager
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
5. The `HTTPRoute` `holos-authenticator/kubernetes` sends the request to the
   `kubernetes` Service in `default`, which the `ReferenceGrant`
   `default/holos-authenticator-kubernetes` allows, and the
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
- **The manager.** `Deployment` `holos-authenticator`, two replicas, each
  answering ext_authz from its own copy of the Backends; leader election
  decides only which writes their status. It watches only its own namespace
  (`POD_NAMESPACE`), so a `Backend` anywhere else is never served, and a
  `Role` there is all its RBAC: Backends, their status, events, its
  `Lease`, and a token for the impersonator alone. It trusts the private
  root as holos-controller does, by `SSL_CERT_DIR` on a mount of the
  `private-ca` ConfigMap, so the `Backend`'s `oidc.caBundle`, base64 PEM,
  stays empty and out of git. Metrics are off.
- **Who may call it.** The Check response carries the impersonator's token,
  so `AuthorizationPolicy` `holos-authenticator-grpc` admits port 9000 only
  from the gateway's mesh identity,
  `cluster.local/ns/holos-authenticator/sa/k8s-gateway`. The namespace is in
  ambient, so ztunnel enforces it; any other pod gets its connection reset
  (`policy rejection: allow policies exist, but none allowed` in ztunnel's
  log). The gateway speaks HBONE to the manager itself. The exception is
  the node's own network namespace, which istio-cni lets through unchecked
  for the kubelet's probes: a hostNetwork pod on a manager's node can reach
  port 9000. Only cilium and the ceph-csi node plugin run there today.
- **The Backend.** `kubernetes`, for host `k8s.bank.internal`, matched
  exactly against `:authority`, so a client that sends `:443` in `Host` is
  refused as an unknown host. `oidc.clientID` is `kubectl` (Q61, ADR 0002):
  the audience kubelogin's token already has, so one login serves the API
  and the shim. The user is `oidc:` and `preferred_username` (Q62); the
  groups are the `groups` claim, forwarded only if in
  `groupMapping.anyOf`. The credential is a token for
  `holos-authenticator-impersonator`, minted with the TokenRequest API for
  an hour and renewed.
- **The allowlist.** `HolosAuthenticator.users` and `.groups`.
  The impersonator's `ClusterRole` may impersonate exactly those users, with
  the `oidc:` prefix, and those groups, and nothing else, so its token can
  become only them. `groups` is also the `Backend`'s `anyOf`, so a group in
  a token but not on the list is dropped, and logged, rather than refusing
  the whole request, which the API server would do for a group the
  impersonator may not impersonate. A user not on `users` is refused by the
  API server with 403. `users` is `jeff` (`Keycloak.users.jeff`, the one
  user the realm import creates) and every project's owners, and `groups`
  is `/platform/owners` and every project's owner group; the owners and
  their groups come from the ProjectClaim collection (Projects, below).
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
the `kubectl` client allows.

```sh
kubectl config set-cluster treasury-oidc --server=https://k8s.bank.internal \
  --certificate-authority="$HOME/treasury-root-ca.pem" --embed-certs
kubectl config set-credentials oidc --exec-api-version=client.authentication.k8s.io/v1 \
  --exec-interactive-mode=IfAvailable --exec-command=kubectl \
  --exec-arg=oidc-login --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://keycloak.bank.internal/realms/holos \
  --exec-arg=--oidc-client-id=kubectl --exec-arg=--grant-type=device-code
kubectl config set-context treasury-oidc --cluster=treasury-oidc --user=oidc
kubectl --context treasury-oidc auth whoami   # oidc:jeff, [/platform/owners system:authenticated]
```

The ID token lasts five minutes; kubelogin renews it with its refresh token
from its cache, the same cache `kubectl oidc-login get-token` reads for the
Substrate shim.

#### Adding a person or a group

- **A person**: as the owner of a project, through its claim (Projects,
  below). Otherwise add them to `Keycloak.users` and their username to
  `HolosAuthenticator.users`, and create them in the realm by hand, as
  `svc-quay-controller` was (Quay, below). The realm import creates only
  `jeff`; it does not read the rest of `Keycloak.users`.
- **A group**: add its full path to `HolosAuthenticator.groups`, and bind
  it to what it may do, with a binding of its own.

Render and commit. The sync changes the impersonator's `ClusterRole` and the
`Backend`, which the manager reloads.

#### Rotation

- **The impersonator's token** is minted for an hour and renewed by the
  manager before it expires.
- **Keycloak's signing keys**: the manager fetches the JWKS itself and
  refreshes it when it sees an unknown key.
- **The private root**: Go reads the pool once, so a new root needs a
  restart of the manager (`kubectl -n holos-authenticator rollout restart
  deploy/holos-authenticator`).
- **The certificate** `k8s` is renewed by cert-manager, and istiod hands it
  to the gateway as it changes.

#### Checking holos-authenticator

```sh
export KUBECONFIG=~/.config/holos/talos/treasury/kubeconfig
kubectl -n holos-authenticator get gateway,certificate,backend,pods -o wide
    # k8s PROGRAMMED True; k8s Ready; backend kubernetes READY True;
    # two holos-authenticator and two k8s-istio pods, on two nodes each
kubectl -n istio-ingress get gateway ingress \
  -o jsonpath='{range .status.listeners[*]}{.name} {.attachedRoutes}{"\n"}{end}'   # k8s 1
# The Lua after ext_authz:
kubectl -n holos-authenticator exec deploy/k8s-istio -c istio-proxy -- \
  pilot-agent request GET 'config_dump?resource=dynamic_listeners' \
  | jq -r '.. | .http_filters? // empty | [.[].name] | join(" -> ")'
# With $TOKEN a kubectl ID token for a member of /platform/owners (The Substrate shim):
kubectl --kubeconfig=/dev/null --server=https://k8s.bank.internal \
  --certificate-authority="$HOME/treasury-root-ca.pem" --token="$TOKEN" auth whoami
curl --cacert ~/treasury-root-ca.pem https://k8s.bank.internal/api                  # 401
curl --cacert ~/treasury-root-ca.pem -H "Authorization: Bearer $TOKEN" \
  -H 'Impersonate-Group: system:masters' https://k8s.bank.internal/api            # 403
curl --cacert ~/treasury-root-ca.pem -H "Authorization: Bearer $TOKEN" \
  -H 'x-impersonate-groups: system:masters' https://k8s.bank.internal/api         # 403
# An ID token for another client, such as argocd, gets 401. The impersonator
# may impersonate only the listed users and groups:
kubectl create -o jsonpath='{.status.allowed}{"\n"}' -f - <<'YAML'                 # false
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: system:serviceaccount:holos-authenticator:holos-authenticator-impersonator
  resourceAttributes: {verb: impersonate, resource: users, name: "oidc:svc-quay-controller"}
YAML
```

### Secrets Manager

The Holos Secrets Manager (holos-run/secrets-manager) is where platform
secrets are made (interview Q18): a Go server with a web UI, at
`https://secrets.bank.internal`, that manages Kubernetes Secrets directly,
with Keycloak login and grants, so there is no external store. A secret is
made in the management namespace through the UI, and an `ExternalSecret` in
the consumer's namespace copies it there through that consumer's own store.
`SecretsManager` (`components/secrets-manager.cue`) holds the release, the
names and the URL; the `secrets-manager` component renders the rest.

- **The server.** One Deployment in the ambient namespace
  `secrets-manager`, the release's distroless nonroot image pinned by
  digest, restricted: non-root, a read-only root, all capabilities dropped.
  It serves plain HTTP on 8080 behind the gateway, which terminates TLS as
  it does for Keycloak (`--plain-http --listen=:8080`), and its public URL
  is `--origin=https://secrets.bank.internal`. It trusts the private root
  from the namespace's `private-ca` ConfigMap, mounted and named by
  `--ca-cert`, for its calls to the issuer. The kubelet probes `/healthz`
  and `/readyz`. It keeps no state beyond Namespaces and Secrets, and acts
  as its own ServiceAccount, `secrets-manager`, impersonating no one.
- **Its RBAC.** Two ClusterRoles, each `get`, `list`, `create`, `update`
  and `delete`. `secrets-manager`, on `namespaces`, is bound cluster wide,
  since organizations and projects are Namespaces the server may make at
  runtime. `secrets-manager-secrets`, on `secrets`, is bound only by a
  `RoleBinding` in each project namespace git renders, beside the
  namespace, so in `holos-prj-platform` alone for now: the server reads and
  writes Secrets only in project namespaces, which in this distro come from
  git. The cost is that a project made in the UI has no access to its
  secrets until git adds its `RoleBinding`. A ProjectClaim renders no
  Secrets Manager project yet (interview Q64); rendering one for each claim
  is the tech debt item secrets-manager-project-for-each-projectclaim. The
  namespace writes are still cluster wide: the
  ServiceAccount may update or delete any Namespace, and deleting one
  deletes everything in it. A `ValidatingAdmissionPolicy` holding them to
  `holos-` namespaces with the server's labels is open hardening.
- **Login.** OIDC against the realm `holos` (`--issuer`, which must always
  be set: an empty issuer turns authentication off), through the public
  client `secrets-manager`, which a holos-controller `Client` in
  `secrets-manager` creates, with the `ReferenceGrant`
  `secrets-manager-clients` in `keycloak` allowing it to name the
  `Instance` there. Its redirect is `https://secrets.bank.internal/pkce/verify`
  and its web origin the URL; the SPA runs the code flow with PKCE and asks
  for `openid profile email groups offline_access`. The server verifies the
  bearer as an ID token whose `aud` is `secrets-manager` (ADR 0002) and
  reads roles from `groups` (`--roles-claim`), full paths. The `Client` has
  no field for a post-logout redirect, so logging out ends on Keycloak's
  page.
- **Organizations.** Only `/platform/owners` may create one
  (`--disable-org-creation --org-creator-roles=/platform/owners`, Q55).
  Never `--enable-insecure-dex`.
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

`holos-prj-platform` (Q54) is a Secrets Manager project, `platform`, under
the server's default prefixes, `holos-` and `prj-`, in the organization
`platform`, `holos-org-platform`. The SPA lists projects only within the
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
`holos-prj-platform`:

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
it for holos-controller's credential, with `source: "keycloak"` and
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

1. Log in at `https://secrets.bank.internal` as a member of
   `/platform/owners`, such as `jeff` (Logging in, under Bootstrap Argo
   CD: the same password), choose the `Platform` organization and open
   its `Platform` project.
2. Create the secret, with the name and keys the consumer expects. The
   server makes it in `holos-prj-platform`, owned by you and, by the
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
kubectl -n secrets-manager get deploy,client               # 1/1, READY True
kubectl -n secrets-manager get httproute secrets-manager \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'   # True
kubectl -n keycloak get referencegrants.security.holos.run
kubectl get ns -L holos.run/resource-type,holos.run/organization -l app.kubernetes.io/managed-by=holos.run
kubectl -n holos-prj-platform get rolebinding secrets-manager-secrets
curl -s --cacert root.pem -o /dev/null -w '%{http_code}\n' https://secrets.bank.internal/          # 200
curl -s --cacert root.pem -o /dev/null -w '%{http_code}\n' https://secrets.bank.internal/metrics   # 500
kubectl -n secrets-manager exec deploy/secrets-manager -- /bin/secrets-manager --version           # the pinned release
```

Check a store with a throwaway consumer, rendered from the definition, and a
secret `sm-test` made in the UI:

```sh
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
kubectl delete -f store.yaml   # its Role and RoleBinding in holos-prj-platform, by name
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
- **Owners.** The API server's bootstrap owners are `ate-client`
  (`system:serviceaccount:ate-system:ate-client`), the identity `kubectl
  ate` acts as without `--token-file`, and kagent's controller. Anyone who
  can mint a token for `ate-client`, which takes `create` on
  `serviceaccounts/token` in `ate-system`, is a global owner of Substrate:
  only cluster admins, from the laptop.
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

Three things have no declarative form and are done by hand, in this order.

**The key pools**, once per cluster, after Argo CD has synced the
namespaces. They are the root of every pod identity, actor token and MITM
certificate: ate-setup creates them as Secrets that Argo CD does not track,
so it never prunes them, and that never pass through the Secrets Manager.
Until they exist the pods that project them wait in ContainerCreating and
the Application is Progressing; the kubelet retries within about two
minutes of their creation. Each command creates only what is missing, so a
second run changes nothing. ate-setup uses `KUBECONFIG`'s current context
(`--context` to choose), and `go run` builds it, about a minute the first
time.

```sh
export KUBECONFIG=~/.config/holos/talos/treasury/kubeconfig
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
ate` port-forwards to Service `api` and, without `--token-file`, mints a
token for `ate-client`. The demo has two templates, `echo` and `other`,
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
`/etc/ssl/certs:/etc/ssl/private-ca`, as argocd-server and holos-controller
do, which keeps the image's public roots. Go reads them once, at start, so
after a rebuild, whose root is new, restart atelet
(`kubectl -n ate-system rollout restart ds/atelet`).

```sh
go build -o ~/bin/kubectl-ate ./cmd/kubectl-ate   # from holos/vendor/substrate; ~/bin on PATH
kubectl ate create atespace demo

# Into Quay, with the controller's token; buildx trusts the root through
# SSL_CERT_DIR, not docker's certs.d.
digest=sha256:c4717a8d1f0134a7444e24f881160e033991f23027c6c5a9a3f8fd22e70d1d44
export DOCKER_CONFIG=$(mktemp -d)
kubectl -n holos-prj-platform get secret quay-controller-token -o jsonpath='{.data.token}' | base64 -d |
  docker login quay.bank.internal -u '$oauthtoken' --password-stdin
SSL_CERT_DIR=/etc/docker/certs.d/quay.bank.internal docker buildx imagetools create \
  -t quay.bank.internal/demo/echo:v1.12.0 docker.io/traefik/whoami:v1.12.0@$digest
docker logout quay.bank.internal; rm -rf $DOCKER_CONFIG; unset DOCKER_CONFIG

image=quay.bank.internal/demo/echo@$digest
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
git diff deploy/clusters/treasury/components/substrate   # what the bump changes on the cluster
git add vendor/substrate substrate.cue components/substrate deploy
```

If the bump's diff changes ConfigMap `atenet-router-envoy-config` or
`atenet-egress`, the Envoy bootstrap upstream ships, restart their readers
once Argo CD has synced it, since no hash covers them:

```sh
kubectl -n ate-system rollout restart deploy/atenet-router deploy/atenet-egress
```

The render refuses a `Substrate.commit` that is not the submodule's, and a
`ko://` image the `images` field does not know, which is what a new
component in upstream's tree looks like: add its name and digest. A new
flag ate-setup appends, a new file it applies on its own or a new
ConfigMap key does not fail the render; only the re-read finds it. A
schema change is migrated by ate-api-server on start, through the owner's
connection.

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
export KUBECONFIG=~/.config/holos/talos/treasury/kubeconfig
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
`substrate` Application Progressing until the key pools exist.

### The Substrate shim

`substrate-shim` is how a person reaches an actor: at
`https://<actor>.<atespace>.ate.bank.internal`, with a Keycloak ID token
(interview Q7 to Q9). It is plain Istio, with no controller of its own.
`AteGateway` (`components/substrate-shim.cue`) names it, and the substrate
component reads the same definition for the router's allowed list.

- **Its own Gateway.** A `RequestAuthentication` applies to every request
  its gateway sees, and refuses a bearer JWT from an issuer it does not know
  with 401 `Jwt issuer is not configured`. On `ingress` that would break
  `docker pull` from Quay, whose registry tokens are Quay's JWTs, and the
  argocd CLI. So the shim is the `Gateway` `substrate-shim/ate`, class
  `istio`, annotated `networking.istio.io/service-type: ClusterIP`: istiod
  gives it the Service `ate-istio` and no address. `ingress`'s `ate`
  listener passes every `*.ate.bank.internal` connection through to that
  Service, by SNI, with the `TLSRoute` `substrate-shim/ate` (The ingress
  gateway, above). There is no new address and no DNS change: the private
  zone's `*.bank.internal` already resolves the hosts to 10.20.0.30. Two
  replicas, preferably on two nodes, as `ingress` has.
- **Listeners.** One per atespace, named after it, for
  `*.<atespace>.ate.bank.internal`, terminating TLS with the `Certificate`
  `<atespace>-wildcard` from the `private-ca` ClusterIssuer: `demo` and
  `kagent` today. Each admits only `HTTPRoute`s from `ate-system`, where
  `ate-<atespace>` routes to the router's Service on 443. Being in the
  router's namespace, those routes need no `ReferenceGrant`, and no
  `ReferenceGrant` into `ate-system` exists, so no other route can reach the
  router through the gateway. A host under an atespace with no listener,
  such as `foo.nope.ate.bank.internal`, matches no filter chain and the
  connection is reset during the TLS handshake (curl exits 35). The Gateway
  sets `allowedListeners` to its own namespace, so a `ListenerSet` there can
  add an atespace.
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
  (`Keycloak.groups.owners`). Istio matches `hosts` as a plain suffix of
  `:authority`, so each rule lists the host with and without `:443`, for a
  client that puts the port in `Host`. Everything else, a request with no
  token included, gets 403 `RBAC: access denied`.
- **The actor.** `TrafficExtension` `ate-target-actor` is a few lines of
  Lua. It splits the host, `<actor>.<atespace>.ate.bank.internal`, and
  replaces `ate-target-actor` with `<atespace>/<actor>`, which drops any
  value the client sent. It has no phase, so istiod puts it after
  `jwt_authn` and `rbac` in the filter chain, and a refused request never
  gets the header. A host of any other shape, such as
  `a.echo.demo.ate.bank.internal`, gets 400. The router strips the header
  before the actor sees the request, so the proof of routing is which actor
  answers.
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
  own proxy, and the router is outside the mesh. Unlike `istio-ingress`, it
  is not exempt from cert-manager's webhook: the webhook's path is
  `ingress`'s `webhooks` listener, which this component does not render, so
  a commit here cannot break the dry run of its own Certificates.
- **Client addresses.** `ingress` passes the connection through, so the
  shim, and the actor in `X-Forwarded-For`, see the `ingress` pod's address,
  not the client's.

#### Reaching an actor

From a machine that trusts the private root (The private CA, above), as a
member of `/platform/owners`. kubelogin prints the `kubectl` client's ID
token, which lasts five minutes:

```sh
TOKEN=$(kubectl oidc-login get-token --oidc-issuer-url=https://keycloak.bank.internal/realms/holos \
  --oidc-client-id=kubectl --grant-type=device-code | jq -r .status.token)
curl https://echo.demo.ate.bank.internal/                                       # 403 RBAC: access denied
curl -H "Authorization: Bearer $TOKEN" https://echo.demo.ate.bank.internal/     # Name: echo
curl -H "Authorization: Bearer $TOKEN" https://other.demo.ate.bank.internal/    # Name: other
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

An atespace claimed through a project is meant to arrive as a `ListenerSet`
in `substrate-shim`, with its certificate and its rule, from the project's
claim (atespace-from-the-projectclaim); the Gateway already allows it.

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
export KUBECONFIG=~/.config/holos/talos/treasury/kubeconfig
kubectl -n substrate-shim get gateway,certificate,pods -o wide
    # ate PROGRAMMED True; both wildcards Ready; two ate-istio pods on two nodes
kubectl -n istio-ingress get gateway ingress \
  -o jsonpath='{range .status.listeners[*]}{.name} {.attachedRoutes}{"\n"}{end}'   # ate 1
# With $TOKEN as above:
curl -H "Authorization: Bearer $TOKEN" -H 'ate-target-actor: demo/other' \
  https://echo.demo.ate.bank.internal/ | head -1                     # still Name: echo
curl https://foo.nope.ate.bank.internal/                             # exit 35, no listener
# A token for a user outside the atespace's groups, such as
# svc-quay-controller, gets 403. The router refuses any other identity:
# Checking Substrate, above, step 2, under ServiceAccount default.
docker pull quay.bank.internal/demo/echo@sha256:c4717a8d1f0134a7444e24f881160e033991f23027c6c5a9a3f8fd22e70d1d44
    # ingress still passes Quay's own bearer tokens
```

### kagent

kagent runs agents as Substrate actors (interview Q26), from the holos-run
fork ([docs/forks.md](../docs/forks.md)), at `https://kagent.bank.internal`
behind a Keycloak login. `Kagent` (`kagent.cue`, and `components/kagent.cue`
for the names that need the Gateway or Keycloak) holds the pins and the
names, and the substrate component reads the same definition for the
router's allowed list, the bootstrap owners and the credential provider's
namespace policy. Two components: `kagent-crds`, the CRD chart, and
`kagent`, the main chart with the CUE-made objects beside it.

- **Pins.** The charts and the controller and UI images are the fork's, on
  `ghcr.io/holos-run/kagent`, by digest. The fork builds nothing else, so
  `config.harnessImages` (`kagent`, `claude`, `codex`) and
  `config.sandboxes.guestImage` are upstream kagent-dev's
  `v1.0.0-alpha17`, the release nearest the fork's base: the harnesses by
  the index digests that release's chart lists in
  `files/builtin-harness-images.json`, and the guest, which that file does
  not list, by the index digest of its `sandbox-guest:1.0.0-alpha17` tag.
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
  The controller runs its migrations as the owner at start.
- **Login.** The chart's oauth2-proxy, with the confidential client
  `kagent`, which a holos-controller `Client` creates, and a generated
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
  with its rights, so the chart's `ClusterRole`s, which read every core
  resource and write core, apps and batch in every namespace, would be
  theirs. Agents, Harnesses, ModelConfigs, Secrets and the placeholder pool
  are all in `kagent`. The tool server's subchart is not scoped: its
  read-only role covers the cluster, so agents can read it.
- **Exposure.** `kagent.bank.internal` is under the Gateway's wildcard. The
  `HTTPRoute` `kagent` sends every path to oauth2-proxy on 4180, never to
  the UI or the controller; the chart's own route is off.
- **The tool server** runs with `--read-only`, which leaves out every tool
  that writes, and binds a read-only `ClusterRole`, get, list and watch
  without Secrets, in place of `cluster-admin`.

#### Adding the Anthropic key

The model key is the platform secret `anthropic-api-key`, key
`ANTHROPIC_API_KEY` (Adding a platform secret, under Secrets Manager,
above). The `ExternalSecret` `kagent/kagent-anthropic` copies it within the
hour, or at once with:

```sh
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

#### Checking kagent

```sh
export KUBECONFIG=~/.config/holos/talos/treasury/kubeconfig
kubectl -n kagent get pods,client,externalsecret   # four pods 1/1; Client READY True; all SecretSynced but kagent-anthropic
kubectl -n ate-system exec substrate-db-1 -c postgres -- psql -d substrate -At \
  -c "select version_id from kagent.schema_migrations" \
  -c "select usename, ssl from pg_stat_activity join pg_stat_ssl using (pid) where usename like 'kagent%'"
    # the migrations; kagent_readwrite_user connections with ssl t
curl -s --cacert root.pem -o /dev/null -w '%{http_code} %{redirect_url}\n' https://kagent.bank.internal/oauth2/start
    # 302 to https://keycloak.bank.internal/realms/holos/protocol/openid-connect/auth?...client_id=kagent...
curl -s --cacert root.pem -o /dev/null -w '%{http_code}\n' https://kagent.bank.internal/api/   # 403 without a session
curl -s --cacert root.pem -o /dev/null -w '%{http_code}\n' -H 'X-Forwarded-Uri: /login' https://kagent.bank.internal/api/   # 403 too
kubectl auth can-i get secrets -n keycloak --as=system:serviceaccount:kagent:kagent-controller   # no
# From a pod outside kagent, every kagent port times out:
kubectl -n default run np-test --image=curlimages/curl:8.11.1 --restart=Never --command -- sleep 600
kubectl -n default exec np-test -- curl -s -m 5 http://kagent-controller.kagent.svc:8083/health   # exit 28
kubectl -n default delete pod np-test
```

### Quay

Quay is the platform's registry (interview Q13, Q56, Q57 and Q59), at
`https://quay.bank.internal`: the demo actor's image, public. The Substrate
and kagent images and charts are on `ghcr.io/holos-run`, pulled anonymously
([docs/forks.md](../docs/forks.md)). `Quay`
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
- **Login.** OIDC against the realm `holos`, Keycloak being Quay's only
  identity store (`AUTHENTICATION_TYPE: OIDC`, `FEATURE_DIRECT_LOGIN:
  false`), through the confidential client `quay`, which a holos-controller
  `Client` in `quay` creates, with `ReferenceGrant` `quay-clients` in
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
  behind the gateway, as Keycloak. Pods resolve `quay.bank.internal` to the
  gateway already, so aavis-ops' ServiceEntries are not ported.
- **Organizations.** One holos-controller `Organization` in `quay`, `demo`,
  which holds the public `Repository` `echo` for the demo actor. It syncs
  team `platformowners` from `/platform/owners` as admin, not `owners`, the
  team Quay makes in every new organization, which holos-controller would
  report as a conflict. Both are `deletionPolicy: Orphan`, so a deleted or
  pruned resource leaves the organization and its images, which are not in
  git. Neither carries a `caBundle`: holos-controller trusts the
  private root through `SSL_CERT_DIR`, as argocd-server does, from the
  `private-ca` ConfigMap mounted at `/etc/ssl/private-ca`; Go reads it at
  start, so a new root needs `kubectl -n holos-controller rollout restart
  deploy/holos-controller-manager`.
- **holos-controller's credential.** The controller reads its Quay token
  from `holos-controller/holos-controller-quay-creds` (`url`, `token`,
  `username`), which `ExternalSecret` `holos-controller-quay-creds`, in
  this component, copies from the platform secret `quay-controller-token`
  through `SecretStore` `platform` there (reader
  `holos-controller-platform-reader`). It is here rather than in
  `holos-controller`, which syncs long before Quay exists: its Application
  would stay `Degraded` and the root would never reach Quay.

#### Bringing Quay up

The irreducible part, which no CRD models, is `cmd/quay-bootstrap`, a Go
program ported from aavis-ops' `hack/quay-bootstrap`, run by hand from the
repository's root after Quay is up, at bootstrap and after a rebuild.

`quay-bootstrap token` logs in to Quay as `svc-quay-controller` through
Keycloak's login form, with the password from Secret
`keycloak/svc-quay-controller`, makes the organization `platform-automation`
and its OAuth Application `holos-controller` if they are missing, mints a
token through the implicit grant the UI's Generate Token drives, and writes
Secret `quay-controller-token` (`url`, `token`, `username`) in
`holos-prj-platform`. A stored token is probed first, on endpoints that need
its `super:user` and `org:admin` scopes, and replaced only when Quay refuses
it with a 401 or 403: a token stays live until it is revoked, so minting on
any other fault would leave another live superuser token behind.

The Secret is a platform secret, with `app.kubernetes.io/managed-by=holos.run`
and the platform owners' grant, so it shows under Platform in the Secrets
Manager. The command converges: a second run prints `no change` and writes
nothing. It uses `kubectl`'s current context (or `-context`) and trusts the
private root from the cluster's `private-ca` ConfigMap (or `-ca-file`)
beside the system's; `-h` lists the rest.

On a new cluster the root reaches `quay` next to last and waits there:
the credential's `ExternalSecret` reports `SecretSyncedError`, and the
Application `Degraded`, until the steps below. Quay itself comes up once
the `Client` has delivered `quay-oidc`, `quay-db` is healthy and
`rustfs-quay` is copied.

```sh
export KUBECONFIG=~/.config/holos/talos/treasury/kubeconfig
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
go run ./cmd/quay-bootstrap token
kubectl -n holos-controller annotate externalsecret holos-controller-quay-creds force-sync=$(date +%s) --overwrite
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
export TALOSCONFIG=~/.config/holos/talos/treasury/talosconfig
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

`certificates` is a string, so patching again replaces it: after a
rebuild, run the same loop with the new root. containerd reads the trust store once, when it starts, so the
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
([Restarting nodes](../providers/proxmox/README.md#restarting-nodes) has the
rest):

```sh
# From the repository's root.
set -a; . ~/.config/holos/proxmox.env; set +a
export KUBECONFIG=~/.config/holos/talos/treasury/kubeconfig
export TALOSCONFIG=~/.config/holos/talos/treasury/talosconfig
go run ./providers/proxmox/cmd/talosvm restart -cluster treasury -dry-run   # the steps of each worker
go run ./providers/proxmox/cmd/talosvm restart -cluster treasury
kubectl -n argocd get applications                                          # every one Synced and Healthy
```

#### Rotation

- **The controller's token.** Delete `quay-controller-token` in
  `holos-prj-platform` and run `quay-bootstrap token`; the copy follows within
  the hour, or at once with the `force-sync` above. The old token stays live
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
  `quay-bootstrap token` only if the token must be replaced too.

None of these has been exercised on a cluster yet.

#### Checking Quay

What Quay uses, once it has run a while (no metrics server here), to check
its memory request against:

```sh
kubectl -n quay exec deploy/quay -c quay -- cat /sys/fs/cgroup/memory.current   # bytes
```

From the repository's root on the claude VM, with `root.pem` as above,
docker trusting the root
(`sudo install -D root.pem /etc/docker/certs.d/quay.bank.internal/ca.crt`):

```sh
# 1. Running, migrated, Synced and Healthy.
kubectl -n quay get cluster,deploy,pods                 # quay-db healthy; quay and quay-redis 1/1
kubectl -n argocd get application quay -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'   # Synced Healthy
kubectl -n quay logs deploy/quay -c quay | grep -i -m3 'migrat'

# 2. By hand, in a browser: log in at https://quay.bank.internal as jeff
#    through Keycloak, log out, and log in again (no 400 on the code exchange).

# 3. The command converges, and the secret is listed under Platform.
go run ./cmd/quay-bootstrap token | tail -1              # ... no change
kubectl -n holos-prj-platform get secret -l app.kubernetes.io/managed-by=holos.run
  # ceph-client-k8s, quay-controller-token

# 4. The organization and the repository are Ready, and jeff is in the platformowners team.
kubectl -n quay get organization,repository             # READY True
tok=$(kubectl -n holos-prj-platform get secret quay-controller-token -o jsonpath='{.data.token}' | base64 -d)
curl -s --cacert root.pem -H "Authorization: Bearer $tok" \
  https://quay.bank.internal/api/v1/organization/demo/team/platformowners/members | jq -c '[.members[].name]'
                                                        # lists jeff, once jeff has logged in

# 5. A multi-layer image, one layer large, pushed to the public repository
#    with the controller's token, which docker login takes as $oauthtoken,
#    and its blobs in RustFS.
printf %s "$tok" | docker login quay.bank.internal -u '$oauthtoken' --password-stdin
d=$(mktemp -d)
printf 'FROM docker.io/library/busybox:1.37.0\nRUN head -c 300000000 /dev/urandom > /big\nRUN echo one > /one\nRUN echo two > /two\n' > $d/Dockerfile
docker build -t quay.bank.internal/demo/echo:check $d
docker push quay.bank.internal/demo/echo:check
docker logout quay.bank.internal
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
kubectl -n quay-test run anonymous --image=quay.bank.internal/demo/echo:check --image-pull-policy=Always \
  --restart=Never --command -- sleep 600
kubectl -n quay-test get pods                           # anonymous Running, with no pull secret
kubectl delete ns quay-test
#   on the laptop, logged out: docker pull quay.bank.internal/demo/echo:check

# 7. A clean render reproduces deploy/ (Render, below).
```

Step 6 is what the Talos patch is for, and a pull that fails with a
certificate error points there. The check's tag, `demo/echo:check`, is
deleted in the UI afterwards.

## Projects

A product engineer gets a project, a namespace they own, with a
ProjectClaim: one small CUE file in `projects/`, in a pull request with the
manifests it renders. The ProjectClaim collection is a pure CUE collection,
not a CRD (overview §4), ported from aavis-ops' Project collection, which
names the same thing. `projects/projects.cue` is its schema,
`collections.cue` binds it into the platform, and `components/project`
renders each claim.

A claim renders, as the component `project-<name>` with an `Application` of
its own in the `platform` `AppProject` (interview Q66):

- **The namespace** `<name>`, in ambient, labeled `holos.run/project: <name>`.
- **Keycloak**: the groups `/projects/<name>/roles/owner`, `editor` and
  `viewer`; a `User` for each owner who is not already one of the realm's
  people (`Keycloak.users`, such as `jeff`); the owners' membership in the
  owner group; and the `ReferenceGrant` `project-<name>` in `keycloak` that
  lets these resources name the `Instance` there. holos-controller makes the
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
  neither RBAC nor holos-controller's kinds; and the `Application` `<name>`
  in it, which syncs `deploy/clusters/<cluster>/projects/<name>/`. That
  directory holds only what the claim renders, one `ConfigMap`, `project`,
  describing it. Every render removes `deploy/clusters` first, so a file
  added there by hand is gone at the next render and fails CI; a project's
  own manifests are future work, to be rendered from CUE or kept outside
  `deploy/clusters`.
- **holos-authenticator**: the owners' usernames and the owner group join
  `HolosAuthenticator.users` and `.groups`, so the authenticator forwards
  the group and may impersonate the owners. The `RoleBinding`'s subject and
  the allowlist entry are the same definition, `#ProjectRoleGroupPath`, so
  `grep -r /projects/<name>/roles/owner deploy/` finds both.

No Secrets Manager project (Q64), no `ResourceQuota`, and no RBAC for the
editor and viewer groups. The collection is empty in the repository (Q67).

### Adding a project

1. Write `projects/<name>.cue`, with one owner or more, keyed by email in
   lower case:

   ```cue
   package projects

   projects: "my-project": owners: "alice@bank.internal": _
   ```

   `<name>` is the project's one name: lower case letters, digits and single
   dashes, 2 to 63 characters. It may not be a name the platform uses: a
   component's, a platform namespace, Argo CD's `platform` or `default`, a
   Quay organization, a person's username, a Substrate atespace, or anything
   starting `kube-`, `holos-` or `project-` (`Projects.reserved`,
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
   there, one username is one person, and no owner may be a platform
   service user (`svc-quay-controller`, or a client's `service-account-*`):
   each mistake fails the render. `ownerAccess: "edit"` or `"view"` gives
   the owners less than `admin`.

2. Render, from this directory, and check what changed:

   ```sh
   cue vet ./... && rm -rf deploy/clusters && holos render platform
   git status deploy/
     # new: components/project-<name>/, projects/<name>/ and
     #      components/argocd-apps/application-project-<name>.yaml
     # changed: holos-authenticator's Backend and impersonator ClusterRole,
     #      and the sync wave, its index in the registry, of every
     #      Application after the new one: argocd-apps' always, and any
     #      other project-* Application that sorts after it
   ```

3. Commit the claim and `deploy/` together, signed (`git commit -S`, Argo
   CD, above), and open a pull request. CI renders the platform again and
   fails if `deploy/` differs from what the claim renders. Merge it in
   GitHub's UI.

4. Argo CD syncs the merge within a minute: the root creates `project-<name>`,
   which makes everything above and the project's `Application`, and
   `holos-authenticator` syncs its allowlist.

5. **For an owner Keycloak did not already have**, set their first and last
   name and a password in Keycloak's admin console (realm `holos`, Users),
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
   kubectl --context treasury-oidc auth whoami       # oidc:alice, [/projects/my-project/roles/owner system:authenticated]
   kubectl --context treasury-oidc auth can-i create deployments -n my-project   # yes
   kubectl --context treasury-oidc auth can-i create deployments -n default      # no
   ```

### Checking a project

```sh
export KUBECONFIG=~/.config/holos/talos/treasury/kubeconfig
kubectl -n argocd get application project-my-project my-project   # Synced Healthy
kubectl -n my-project get groups.keycloak.holos.run,users.keycloak.holos.run,groupmemberships.keycloak.holos.run,organizations.quay.holos.run
    # every READY True
grep -r /projects/my-project/roles/owner deploy/   # the RoleBinding, the Backend, the impersonator, the Organization, the ConfigMap
```

### Removing a project

Removing the claim and rendering removes its files, and the root prunes
`project-<name>`'s `Application`; but no `Application` has the resources
finalizer (Argo CD, above), so everything it made stays. Remove it by hand,
in this order, after the merge:

```sh
kubectl -n argocd delete application <name>
kubectl -n argocd delete appproject <name>
kubectl delete namespace <name>        # wait: holos-controller's finalizers delete the groups and the membership
kubectl -n keycloak delete referencegrant.security.holos.run project-<name>
```

The `ReferenceGrant` goes last: without it the finalizers of the namespace's
`Group` and `GroupMembership` cannot reach the `Instance`, report
`ReferenceNotGranted` and hold the namespace in `Terminating` until the
grant is back. Three things stay, by design, and are removed in Keycloak's
admin console or Quay's API once nobody needs them:

- the parent groups `/projects/<name>` and `/projects/<name>/roles`, which
  holos-controller made and does not own, and `/projects` once no project
  is left;
- each owner's user, `Orphan`, since a person may own another project and
  their password was set by hand;
- the Quay organization and its images, `Orphan`, as `demo` is. Delete it
  before a claim of the same name is added again: the new `Organization`
  does not adopt, so holos-controller reports a `Conflict` on an
  organization it did not create, and the project's never becomes Ready.

## Render

From this directory, in a clone or worktree with the Substrate submodule
checked out (Substrate, above), which a fresh one is not:

```sh
git submodule update --init vendor/substrate
cue vet ./...
rm -rf deploy/clusters
holos render platform
cue cmd talos
git status deploy/ ../providers/proxmox/talos/clusters/
```

`cue cmd talos` writes the control plane's Talos patch, the webhook host
entries, from the same data (`talos.cue`); it is not part of the platform, so
`holos render platform` does not write it. A change to it reaches a running
cluster only through `talosctl` (`providers/proxmox/talos/README.md`).

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

## Bootstrap Argo CD

A cluster is built with its webhooks failing open, `webhooks.enforcing`
false in `clusters.cue`; turn it on once they answer (Building a cluster with
enforcement, above). Argo CD needs pod networking, and DNS to reach GitHub,
before it can sync anything, so a new cluster gets four components by hand: `cilium`,
`coredns`, `argocd` and the root `Application` with its `AppProject`. It
also gets `management-namespaces` and the Ceph key in it (Storage, above),
which no component renders. The root then creates every component's
`Application` in registry order, waiting for each to report `Healthy` before
the next, and takes over the hand-applied components as it goes. Apply
from a checkout of `main`, since that is what Argo CD will sync, and from this
directory:

```sh
export KUBECONFIG=~/.config/holos/talos/treasury/kubeconfig
export TALOSCONFIG=~/.config/holos/talos/treasury/talosconfig
d=deploy/clusters/treasury/components

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
key=$(ssh root@r620a ceph auth get-key client.k8s) && [ -n "$key" ] &&
printf %s "$key" |
  kubectl -n holos-prj-platform create secret generic ceph-client-k8s \
    --from-literal=userID=k8s --from-file=userKey=/dev/stdin --dry-run=client -o yaml |
  kubectl label --local -f - app.kubernetes.io/managed-by=holos.run -o yaml |
  kubectl annotate --local -f - \
    'holos.run/share-roles=[{"principal":"/platform/owners","role":"owner"}]' -o yaml |
  kubectl create -f -
unset key

# The AppProject and the root alone: the root creates the other
# Applications wave by wave. Applying the whole directory would create them
# all at once, and they would sync in parallel.
kubectl apply --server-side --field-manager=argocd-controller \
  -f $d/argocd-apps/appproject-platform.yaml -f $d/argocd-apps/application-argocd-apps.yaml
kubectl -n argocd get applications -w
```

The `Application`s appear one at a time in registry order, and each reaches
`Synced` and `Healthy` within a few minutes. The workers turn `Ready` once
the Cilium agents are up; the control plane stays `NotReady`. Once
`private-ca-bundle` is `Healthy`, restart the server so it reads the private
root, which it needs to log in through Keycloak (Logging in, below): its
`private-ca` mount is optional because the server starts before
trust-manager writes the ConfigMap, and Go reads the trust pool only at
start.

```sh
kubectl -n argocd rollout restart deploy/argocd-server
```

The root then waits on `substrate` until its key pools exist: once its
namespaces are synced, run the key pool commands under Bringing Substrate
up (Substrate, above). Its pods that project the pools wait in
ContainerCreating until then, so the Application stays Progressing.

The root then waits on `quay`, next to last, whose credential is a platform
secret made by `cmd/quay-bootstrap` against the running Quay: once Quay's
pod is up, run the steps under Bringing Quay up, and patch the workers'
trust and restart them with `talosvm restart` (Trusting the root on the
workers), both under Quay, above.

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

### Logging in

Through Keycloak, as a member of `/platform/owners`, which the `argocd-rbac-cm`
policy makes `role:admin`: in a browser at https://argocd.bank.internal,
**Log in via Keycloak**, or with the CLI, `argocd login argocd.bank.internal
--grpc-web --sso`, which opens a browser and listens on `localhost:8085`.
Argo CD's `oidc.config` names the realm's issuer, the public client `argocd`
with PKCE and the scopes `openid profile email groups`, and no secret (The
realm, above). The server checks Keycloak's certificate against the private
root without it being in git: it mounts the namespace's `private-ca`
ConfigMap and adds it to Go's system trust with `SSL_CERT_DIR`, so
`oidc.config` has no `rootCA`. Groups are matched by full path, leading
slash included. Nobody else from Keycloak gets a role.

That member is the realm's one user, `jeff` (`jeff@bank.internal`), imported
with the realm and put in `/platform/owners` by holos-controller (The realm,
above). Log in as `jeff`, with the generated password from the `keycloak`
namespace:

```sh
kubectl -n keycloak get secret holos-user-jeff -o jsonpath='{.data.password}' | base64 -d; echo
```

Argo CD's **User Info** page, or `argocd account get-user-info`, then shows
`/platform/owners` under Groups, with the leading slash.

Or as the local `admin`, kept until the milestone's login through Keycloak
has passed, once the laptop trusts the private root (The private CA,
above). The gateway serves HTTP/1.1 to the server, so the CLI needs
`--grpc-web`; without it the CLI warns and falls back to it.

```sh
argocd login argocd.bank.internal --grpc-web --username admin --password \
  "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
argocd app list
```

Without the gateway, as during a bootstrap, a port-forward reaches the
server, which serves plain HTTP:

```sh
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
# 1. Disable Talos's CoreDNS (the patch is already in controlplane.yaml).
set -a; . ~/.config/holos/proxmox.env; set +a
providers/proxmox/talos/cluster.sh gen treasury
providers/proxmox/talos/cluster.sh apply treasury

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
kubectl -n argocd get applications   # every one Synced and Healthy
kubectl get nodes
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status
kubectl get ciliumloadbalancerippools

kubectl create ns treasury-test
kubectl -n treasury-test run dnstest --image=docker.io/nicolaka/netshoot:v0.14 \
  --restart=Never --command -- sleep 3600
kubectl -n treasury-test exec dnstest -- dig +search kubernetes.default A
kubectl -n treasury-test exec dnstest -- dig @10.96.0.10 test.bank.internal A
kubectl -n treasury-test create deployment echo \
  --image=registry.k8s.io/e2e-test-images/agnhost:2.53 -- /agnhost netexec --http-port=8080
kubectl -n treasury-test expose deployment echo --type=LoadBalancer --port=80 --target-port=8080
kubectl -n treasury-test get svc echo   # EXTERNAL-IP from 10.20.0.31-.33, never the gateway's .30
curl http://<external-ip>/hostname   # from the garage network
kubectl delete ns treasury-test
```

CoreDNS's metrics show which upstream answered: a `bank.internal` query is
counted against `to="192.168.2.1:53"`, anything else against host DNS,
`to="169.254.116.108:53"`:

```sh
kubectl -n treasury-test exec dnstest -- curl -s http://<coredns pod IP>:9153/metrics |
  grep proxy_request_duration_seconds_count
```

The private CA: issue a certificate, check it chains to the root in the
namespace's bundle, and remove it.

```sh
kubectl create ns ca-test
kubectl -n ca-test get configmap private-ca   # trust-manager's copy of the root
kubectl -n ca-test apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: test}
spec:
  secretName: test-tls
  dnsNames: [test.ca-test.bank.internal]
  issuerRef: {group: cert-manager.io, kind: ClusterIssuer, name: private-ca}
EOF
kubectl -n ca-test wait --for=condition=Ready certificate/test
t=$(mktemp -d)
kubectl -n ca-test get secret test-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > $t/leaf.pem
kubectl -n ca-test get configmap private-ca -o jsonpath='{.data.ca\.crt}' > $t/root.pem
openssl verify -CAfile $t/root.pem $t/leaf.pem
kubectl delete ns ca-test
```

Storage: `ceph-rbd` the only default class, the driver's pods on the
workers only, and a volume written on one worker read back on another, its
image in the pool while the claim exists and gone once it is deleted.

```sh
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
pod writer treasury-general-1 'hostname > /data/x'
kubectl -n storage-test wait --for=condition=Ready --timeout=2m pod/writer
ssh root@r620a rbd ls k8s-rbd              # csi-vol-...
kubectl -n storage-test delete pod writer
pod reader treasury-general-3 'cat /data/x'
kubectl -n storage-test wait --for=condition=Ready --timeout=2m pod/reader
kubectl -n storage-test logs reader        # writer, the pod that wrote it on general-1
PV=$(kubectl -n storage-test get pvc rbd -o jsonpath='{.spec.volumeName}')
kubectl delete ns storage-test
kubectl wait --for=delete --timeout=2m pv/$PV   # the image goes with the PV
ssh root@r620a rbd ls k8s-rbd              # empty
```

LoadBalancer addresses answer TCP and UDP on the Service's ports only; they
do not answer ping, and a connection to any other port is dropped, not
refused.

Istio and the gateway: the node agents on the workers only, the webhooks
enforcing through the gateway, the gateway at its pinned address, and hello answering through
it with a certificate that chains to the root, from the garage network and
from a pod. Until the private zone has its wildcard, `--resolve` stands in
for it.

```sh
kubectl -n istio-system get pods -o wide        # istiod, and istio-cni-node and ztunnel on each worker
kubectl get validatingwebhookconfiguration istio-validator-istio-system \
  -o jsonpath='{.webhooks[0].failurePolicy} {.webhooks[0].clientConfig.url}{"\n"}'
kubectl -n istio-ingress get gateway ingress     # ADDRESS 10.20.0.30, PROGRAMMED True
kubectl get ciliumloadbalancerippools            # treasury: 0 available; treasury-general: none CONFLICTING
kubectl get httproute -A                         # argocd, hello, https-redirect
kubectl get tlsroute -A                          # cert-manager-webhook, trust-manager, cnpg-webhook-service, external-secrets-webhook, istiod
kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration \
  -o custom-columns='NAME:.metadata.name,FP:.webhooks[*].failurePolicy'   # Fail everywhere

kubectl -n default get configmap private-ca -o jsonpath='{.data.ca\.crt}' > /tmp/root.pem
curl --resolve hello.bank.internal:443:10.20.0.30 --cacert /tmp/root.pem https://hello.bank.internal/
curl -sI --resolve hello.bank.internal:80:10.20.0.30 http://hello.bank.internal/   # 301 to https
curl -s --resolve argocd.bank.internal:443:10.20.0.30 --cacert /tmp/root.pem https://argocd.bank.internal/api/version

kubectl create ns gw-test
kubectl label ns gw-test istio.io/dataplane-mode=ambient
kubectl -n gw-test run curl --image=docker.io/curlimages/curl:8.11.1 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"curl","image":"docker.io/curlimages/curl:8.11.1","command":["sleep","3600"],"volumeMounts":[{"name":"ca","mountPath":"/ca"}]}],"volumes":[{"name":"ca","configMap":{"name":"private-ca"}}]}}'
kubectl -n gw-test wait --for=condition=Ready pod/curl
kubectl -n gw-test exec curl -- curl -s --cacert /ca/ca.crt \
  --resolve hello.bank.internal:443:10.20.0.30 https://hello.bank.internal/
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
kubectl create ns lb-test
kubectl -n lb-test create service loadbalancer t1 --tcp=80:8080   # 10.20.0.31-.33
kubectl -n lb-test create -f - <<'EOF'
{"apiVersion": "v1", "kind": "Service", "metadata": {"name": "t30"},
 "spec": {"type": "LoadBalancer", "loadBalancerIP": "10.20.0.30", "ports": [{"port": 80}]}}
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

Once the workers are `Ready`, the node lifecycle controller treats the
`NotReady` control plane as a failed node: it adds the
`node.kubernetes.io/not-ready:NoExecute` taint and, after the default
300-second toleration, evicts the mirror pods of kube-apiserver,
kube-controller-manager and kube-scheduler. The static pods keep running;
the kubelet recreates the mirror pods, so `kubectl get pods` shows them
`Terminating` and then young again, about every five minutes. While every
node was `NotReady` the controller held back, as it does for a full
disruption, which is why this starts only once Cilium is up.
