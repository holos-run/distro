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
├── argocd.cue      the repository, branch, project and signing keys Argo CD syncs with
├── webhooks.cue    the Services that serve admission webhooks
├── talos.cue       the control plane's Talos patch made from the above; talos_tool.cue writes it
├── private-ca.cue  the names of the private CA and its trust bundle
├── istio.cue       the mesh's release, namespace, images and trust domain
├── signing-keys/   the public keys commits on main are signed with
├── platform/       the Platform: the registry, rendered per cluster
├── components/     one directory per component, each producing a BuildPlan
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
| `cert-manager` | cert-manager v1.21.3 from Jetstack's OCI chart, in `cert-manager`, with its CRDs and its webhook reached through the gateway |
| `private-ca` | The self-signed bootstrap `Issuer`, the root `Certificate` and the `private-ca` `ClusterIssuer` |
| `trust-manager` | trust-manager v0.25.0 from Jetstack's OCI chart, in `cert-manager`, with its `Bundle` CRD and its webhook reached through the gateway |
| `private-ca-bundle` | The `private-ca` `Bundle`: the root as ConfigMap `private-ca`, key `ca.crt`, in every namespace |
| `istio-base` | Istio 1.31.3's CRDs from its OCI `base` chart, the `istio-system` namespace (privileged) and the default revision's validating webhook |
| `istiod` | Istio's control plane in ambient mode, in `istio-system`, with its webhooks reached through the gateway and the private root as its JWKS trust |
| `istio-cni` | Istio's CNI node agent, chained after Cilium on every worker |
| `ztunnel` | Ambient's node proxy on every worker |
| `cloudnative-pg` | The CloudNativePG operator 1.30.1 from its `cloudnative-pg` chart 0.29.1, in `cnpg-system`, with its CRDs and its webhooks reached through the gateway; no `Cluster` |
| `external-secrets` | The External Secrets operator v2.14.0 from its `external-secrets` chart 2.14.0, in `external-secrets`, with its CRDs and its webhook reached through the gateway; no store, no `ExternalSecret` |
| `ingress-gateway` | The `ingress` `Gateway` in `istio-ingress` at the pinned address, its `*.bank.internal` certificate, the HTTP to HTTPS redirect, Argo CD's `HTTPRoute`, and the admission webhooks' TLS passthrough listener and `TLSRoute`s |
| `hello` | An echo service in the ambient namespace `hello`, at `hello.bank.internal` |
| `ceph-csi-rbd` | ceph-csi 3.17.1's RBD driver from its `ceph-csi-rbd` chart, in `ceph-csi-rbd` (privileged), against the hosts' Ceph, and the default StorageClass `ceph-rbd` |
| `local-path` | local-path-provisioner v0.0.37 from its release manifest, in `local-path-storage` (privileged), and the `local-path` StorageClass, not the default |
| `rustfs` | RustFS 1.0.4 standalone from its `rustfs` chart 1.0.4, in the ambient namespace `rustfs`: one pod, one `ceph-rbd` volume, the S3 endpoint `rustfs-svc.rustfs.svc:9000`, generated keys, and a Job that registers the `substrate` and `quay` buckets and users |
| `keycloak-operator` | The Keycloak Operator 26.8.1 from the release's manifests, vendored, in the ambient namespace `keycloak`, with its four CRDs; no `Keycloak` |
| `keycloak` | Keycloak 26.8.1 in `keycloak`, at `keycloak.bank.internal`: the `Keycloak` resource, its one-instance CloudNativePG cluster `keycloak-db` on `ceph-rbd`, and its generated admin and database credentials |
| `holos-controller` | holos-controller 0.22.0 from aavis-ops' manifests, vendored, in the ambient namespace `holos-controller`, with its eight CRDs; no resources of its kinds |
| `keycloak-realm` | The realm `holos`: its `KeycloakRealmImport` and generated secrets, holos-controller's credential, the `Instance`, the group `/platform/owners` and its membership, and the Job that writes the `Instance`'s `caBundle` |
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
  everywhere else.
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
3. Merge `webhooks: enforcing: true`.

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
every `Application` with a `ComparisonError`: `signed with unallowed key`.
To add a key, export it with `gpg --armor --export <long key ID>` into
`signing-keys/<long key ID>.asc` and add it to `ArgoCD.signingKeys`.

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
  `istio.io/ingress-use-waypoint` through the Service's waypoint, which
  holos-authenticator relies on.
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
  `keycloak.bank.internal`, named in
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
- **ServiceAccount.** The `gateway.istio.io/service-account` annotation names
  it `ingress-gateway`, so the gateway's mesh identity is
  `spiffe://cluster.local/ns/istio-ingress/sa/ingress-gateway`
  (`IngressGateway.spiffeID`), the identity substrate-shim puts on the
  Substrate router's allowed list. Without the annotation it would be
  `ingress-istio`, a side effect of the class.
- **Deployment.** `infrastructure.parametersRef` names ConfigMap
  `istio-ingress/ingress-gateway`, whose `deployment` key istiod merges into
  the Deployment it generates: two replicas spread across nodes, so draining
  a worker does not drop the gateway. substrate-shim adds its podCertificate
  volume there.
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

The Ceph user's key is never in git, since the repository is public. It is
in Secret `ceph-csi-rbd/ceph-client-k8s` (`Cluster.ceph.secret`), made by
hand, which the class's provisioner, controller-expand, controller-publish
and node-stage secret parameters name. No `Application` tracks it, so Argo CD
neither prunes nor reverts it; it moves to the management namespace once
external-secrets is in. A rebuilt cluster needs it before anything can claim
a volume (Bootstrap Argo CD, below). To make it on a running cluster, without
the key reaching the terminal:

```sh
ssh root@r620a ceph auth get-key client.k8s |
  kubectl -n ceph-csi-rbd create secret generic ceph-client-k8s \
    --from-literal=userID=k8s --from-file=userKey=/dev/stdin
```

Without it the driver's pods run and `Application` `ceph-csi-rbd` reports
`Healthy`, but every claim on `ceph-rbd` stays `Pending`.

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
component generates its own secrets with `#GeneratedSecret`, below, and the
stores that read from outside the cluster come with the Secrets Manager. The
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
cue export ./components --out text -e 'yaml.MarshalStream([for K, V in
  (#GeneratedSecret & {name: "eso-test", namespace: "eso-test"}).resources
  for R in V {R}])' > es.yaml
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
  - the user `jeff`, `jeff@bank.internal`.
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
pinned by digest. It registers no webhook. `keycloak-realm`, after it, is
everything above plus the credential, so the CRDs are established before
Argo CD applies the resources.

The realm's two secrets are generated in `keycloak` (Generated secrets,
above), because the import's placeholders read Secrets in the import's own
namespace: `svc-holos-controller`, username the client ID, password the
client's secret, and `holos-user-jeff`, username `jeff`. The import's
`spec.placeholders` hands their passwords to the import Job as environment
variables, which Keycloak puts in place of `${SVC_HOLOS_CONTROLLER_CLIENT_SECRET}`
and `${JEFF_PASSWORD}`, so neither value is in the resource or in git.

holos-controller reads its credential from its own namespace, from the
downward API's `POD_NAMESPACE`, whatever the `Instance`'s namespace. An
`ExternalSecret` there, `holos-controller-keycloak-creds`, copies
`svc-holos-controller` into the keys the controller reads, `clientId` and
`clientSecret`, through `SecretStore` `keycloak`, External Secrets'
`kubernetes` provider, which authenticates as ServiceAccount
`keycloak-secret-reader` and may `get` that one Secret in `keycloak`. The
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

## Render

From this directory:

```sh
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
`deploy/` must be clean after a render. Argo CD syncs what is committed on
`main`, so a change reaches a cluster only with its render. Render one
component with `holos render platform --selector component=cilium`.

## Bootstrap Argo CD

A cluster is built with its webhooks failing open, `webhooks.enforcing`
false in `clusters.cue`; turn it on once they answer (Building a cluster with
enforcement, above). Argo CD needs pod networking, and DNS to reach GitHub,
before it can sync anything, so a new cluster gets four components by hand: `cilium`,
`coredns`, `argocd` and the root `Application` with its `AppProject`. The
root then creates every component's `Application` in registry order, waiting
for each to report `Healthy` before the next, and takes over the four as it
goes. Apply
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

# The Ceph key's Secret, which nothing renders (Storage, above), in the
# namespace ceph-csi-rbd's Application later takes over.
kubectl apply --server-side --field-manager=argocd-controller -f $d/ceph-csi-rbd/namespace-ceph-csi-rbd.yaml
ssh root@r620a ceph auth get-key client.k8s |
  kubectl -n ceph-csi-rbd create secret generic ceph-client-k8s \
    --from-literal=userID=k8s --from-file=userKey=/dev/stdin

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
