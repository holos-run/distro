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
with three or four Gateway addresses each. `spike` has the first four,
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

- `<cluster>` (`spike`) holds only the gateway's address and selects only the
  gateway's Service, by the `gateway.networking.k8s.io/gateway-name` label
  istiod sets on it and the `io.kubernetes.service.namespace` label LB IPAM
  adds to every Service. No other Service can be given the address, whatever
  order things start in, even one that asks for it; it stays Pending with
  `pool_selector_mismatch`.
- `<cluster>-general` (`spike-general`) holds the rest of the block, 10.20.0.31
  to .33, for every namespace but the gateway's. The gateway's Service matches
  only the first pool, so it can be given nothing else.

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
| `ingress-gateway` | The `ingress` `Gateway` in `istio-ingress` at the pinned address, its `*.bank.internal` certificate, the HTTP to HTTPS redirect, Argo CD's `HTTPRoute`, and the admission webhooks' TLS passthrough listener and `TLSRoute`s |
| `hello` | An echo service in the ambient namespace `hello`, at `hello.bank.internal` |
| `argocd-apps` | The `platform` `AppProject` and an Argo CD `Application` per component, its own being the root `Application` |

Helm charts are cached in `components/<name>/vendor/<version>/`, which is
committed, so a render needs no network and reads the same chart everywhere.

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
  `https://cert-manager-webhook.cert-manager.webhooks.spike.bank.internal:9443/validate`.
  The hostname is the SNI the Gateway routes on and a DNS name on the
  webhook's serving certificate. The control plane resolves it through a
  Talos host entry to the Gateway's address (`talos.cue`,
  `providers/proxmox/talos/README.md`), so the API server does not depend on
  the router; the router's `*.bank.internal` record gives the same answer
  everywhere else.
- `failurePolicy`: `Ignore` while `webhooks.enforcing` is false, the
  default; `Fail` once it is set. It is one flag per cluster, ADR 0001's two
  provisioning steps. `spike` enforces.
- `timeoutSeconds`: 3, not the default 10.

The webhook's Service is registered in `webhooks.cue`, the one list the
listener's `TLSRoute`s and the control plane's host entries are rendered
from. A new entry also needs its hostname on the webhook's serving
certificate, and its host entry applied to a running control plane with
`talosctl`: Argo CD does not reach the machine config. cert-manager's
cainjector fills each configuration's `caBundle`; it does so for a URL as it
does for a Service. istiod fills its own (see Istio below).

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
kubectl -n kube-system logs kube-apiserver-spike-cp-1 --since=10m | grep -c 'failing open'   # 0
```

A `Bundle` with two kinds of source is refused too, but by the CRD's own
validation, before any webhook is called, so it proves nothing about the
path. From the garage network each hostname answers on the Gateway's address
with the webhook's own certificate, and a name no route matches is reset:

```sh
for h in cert-manager-webhook.cert-manager istiod.istio-system trust-manager.cert-manager; do
  echo | openssl s_client -connect 10.20.0.30:9443 -servername $h.webhooks.spike.bank.internal 2>/dev/null |
    openssl x509 -noout -ext subjectAltName
done
```

With `Fail`, every webhook depends on the Gateway and on istiod, which
programs it: while the gateway's Pods are down, a request a webhook matches
is refused, such as any write of a cert-manager resource, a `Bundle` or an
Istio resource. Pods and other core objects are not matched (the sidecar
injector matches only Pods that ask for a sidecar), so the gateway and
istiod can always be restarted.

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

So to rebuild `spike`, or to build a new cluster:

1. Merge `webhooks: enforcing: false` for the cluster (for `spike`, drop the
   line in `clusters.cue`), render, and bootstrap (Bootstrap Argo CD, below).
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
by hand first, which is how `spike` first enforced.

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
kubectl -n default get configmap private-ca -o jsonpath='{.data.ca\.crt}' > ~/spike-root-ca.pem
openssl x509 -in ~/spike-root-ca.pem -noout -subject -dates -fingerprint -sha256
# macOS: trust it for TLS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/spike-root-ca.pem
# Debian or Ubuntu
sudo cp ~/spike-root-ca.pem /usr/local/share/ca-certificates/spike-root-ca.crt
sudo update-ca-certificates
```

Before replacing a trusted root, remove the old one: macOS's Keychain Access
lists it as `Holos spike root CA`. curl takes it without installing it,
`--cacert ~/spike-root-ca.pem`.

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
  `AppProject` is wave -1.
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
  each webhook configuration, is not a difference, and no `Application` needs
  `ignoreDifferences`.
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

Login is the local `admin` until Keycloak gives Argo CD a client; Dex is
off. Argo CD is at https://argocd.bank.internal, `global.domain`, through the
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
  nothing moves. Measured on `spike`: about ten updates a configuration in
  the first 90 seconds with the listener up and `Ignore` rendered; none in
  six minutes with `Fail` rendered.
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
  Q40), `hello.bank.internal`, `argocd.bank.internal`, named in
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
  `istio-system`), selected by `kubernetes.io/metadata.name`. This component
  renders one `TLSRoute` per entry from the registry, in the entry's own
  namespace, matching its hostname and forwarding to the Service's port.
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
export KUBECONFIG=~/.config/holos/talos/spike/kubeconfig
export TALOSCONFIG=~/.config/holos/talos/spike/talosconfig
d=deploy/clusters/spike/components

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

# The AppProject and the root alone: the root creates the other
# Applications wave by wave. Applying the whole directory would create them
# all at once, and they would sync in parallel.
kubectl apply --server-side --field-manager=argocd-controller \
  -f $d/argocd-apps/appproject-platform.yaml -f $d/argocd-apps/application-argocd-apps.yaml
kubectl -n argocd get applications -w
```

The `Application`s appear one at a time in registry order, and each reaches
`Synced` and `Healthy` within a few minutes. The workers turn `Ready` once the Cilium agents are up;
the control plane stays `NotReady`.

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

The local `admin`, with a browser at https://argocd.bank.internal or with
the argocd CLI, once the laptop trusts the private root (The private CA,
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

A cluster built before Argo CD, as `spike` was, had every component applied
by hand with field manager `holos`. Argo CD takes those objects over without
a conflict: its server-side apply forces conflicts, and its manifests are
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
providers/proxmox/talos/cluster.sh gen spike
providers/proxmox/talos/cluster.sh apply spike

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

kubectl create ns spike-test
kubectl -n spike-test run dnstest --image=docker.io/nicolaka/netshoot:v0.14 \
  --restart=Never --command -- sleep 3600
kubectl -n spike-test exec dnstest -- dig +search kubernetes.default A
kubectl -n spike-test exec dnstest -- dig @10.96.0.10 test.bank.internal A
kubectl -n spike-test create deployment echo \
  --image=registry.k8s.io/e2e-test-images/agnhost:2.53 -- /agnhost netexec --http-port=8080
kubectl -n spike-test expose deployment echo --type=LoadBalancer --port=80 --target-port=8080
kubectl -n spike-test get svc echo   # EXTERNAL-IP from 10.20.0.31-.33, never the gateway's .30
curl http://<external-ip>/hostname   # from the garage network
kubectl delete ns spike-test
```

CoreDNS's metrics show which upstream answered: a `bank.internal` query is
counted against `to="192.168.2.1:53"`, anything else against host DNS,
`to="169.254.116.108:53"`:

```sh
kubectl -n spike-test exec dnstest -- curl -s http://<coredns pod IP>:9153/metrics |
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
kubectl get ciliumloadbalancerippools            # spike: 0 available; spike-general: none CONFLICTING
kubectl get httproute -A                         # argocd, hello, https-redirect
kubectl get tlsroute -A                          # cert-manager-webhook, trust-manager, istiod
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
