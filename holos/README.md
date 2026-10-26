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
├── private-ca.cue  the names of the private CA and its trust bundle
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

## Components

| Component | What it renders |
| --- | --- |
| `cilium` | Cilium 1.20.4 from its Helm chart, in `kube-system`: CNI, kube-proxy replacement, LB IPAM and L2 announcements |
| `cilium-resources` | The cluster's `CiliumLoadBalancerIPPool`, a `CiliumL2AnnouncementPolicy` on `eth0`, and the `allow-ambient-hostprobes` `CiliumClusterwideNetworkPolicy` |
| `coredns` | CoreDNS from the CoreDNS project's Helm chart, replacing the one Talos deploys, with the site's private zone forwarded to its resolvers |
| `argocd` | Argo CD v3.5.6 from argo-helm's `argo-cd` chart 10.11.6, in `argocd`, syncing this repository's `main` |
| `gateway-api` | The Gateway API v1.6.3 CRDs, standard channel, vendored from the release, ahead of Istio |
| `cert-manager` | cert-manager v1.21.3 from Jetstack's OCI chart, in `cert-manager`, with its CRDs and its webhook on the load balancer |
| `private-ca` | The self-signed bootstrap `Issuer`, the root `Certificate` and the `private-ca` `ClusterIssuer` |
| `trust-manager` | trust-manager v0.25.0 from Jetstack's OCI chart, in `cert-manager`, with its `Bundle` CRD and its webhook on the load balancer |
| `private-ca-bundle` | The `private-ca` `Bundle`: the root as ConfigMap `private-ca`, key `ca.crt`, in every namespace |
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
reaches an admission webhook through a URL on HAProxy, a layer 4 load
balancer on the control plane, which passes TLS through to a host-network
Gateway that routes on SNI to the webhook's Service. HAProxy, the
`extraHostEntries` and the Gateway are a later item; until they exist no
webhook is reachable, and every webhook fails open.

Every component that registers a webhook renders its configurations with
`#WebhookPatch` (`components/webhooks.cue`), which sets, from the cluster's
`webhooks` in `clusters.cue`:

- `clientConfig.url`: `https://<service>.<namespace>.webhooks.<cluster>.<privateDomain>:9443/<path>`,
  for example
  `https://cert-manager-webhook.cert-manager.webhooks.spike.bank.internal:9443/validate`.
  The hostname resolves only on the control plane, through Talos
  `extraHostEntries`, to the control plane's address, where HAProxy listens on
  9443. The webhook's serving certificate carries the hostname.
- `failurePolicy`: `Ignore` while `webhooks.enforcing` is false, the
  default; `Fail` once it is set. It is one flag per cluster, ADR 0001's two
  provisioning steps.
- `timeoutSeconds`: 3, not the default 10.

The webhook's Service is registered in `webhooks.cue`, the one list the load
balancer item renders the host entries, HAProxy and TLSRoutes from.
cert-manager's cainjector fills each configuration's `caBundle`; it does so
for a URL as it does for a Service.

While the webhooks fail open, the API server skips them: a cert-manager
resource is not validated, and a CertificateRequest is not stamped with its
requester's `spec.username` and `spec.groups` by the mutating webhook.
cert-manager's own approver does not need them. The API server logs every
skipped call as `Failed calling webhook, failing open`. With no host entry the
name does not resolve and the call fails at once; once a name resolves to an
address that does not answer, each request waits the 3-second timeout.

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
```

istiod trusts the root when it fetches the JWKS for a RequestAuthentication
through `/cacerts/extra.pem`, which Istio's chart mounts from ConfigMap
`pilot-jwks-extra-cacerts`, not from the `cacerts` Secret. The Istio
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
off. There is no ingress yet, so Argo CD is reached with a port-forward.
`global.domain` is already `argocd.<cluster>.<privateDomain>`, the name the
server will have behind the gateway. Argo CD runs Deployments and one
StatefulSet, no DaemonSet, so the control plane's `NoSchedule` taint keeps
it on the workers. Its pods meet the restricted Pod Security standard, so the
`argocd` namespace needs no label. The images are pinned by digest.

## Render

From this directory:

```sh
rm -rf deploy/clusters
holos render platform
git status deploy/
```

`holos render platform` writes files but never removes one a component no
longer renders, such as the Hubble certgen Job whose name changes with the
Cilium values, so remove `deploy/clusters` first. Commit the result;
`deploy/` must be clean after a render. Argo CD syncs what is committed on
`main`, so a change reaches a cluster only with its render. Render one
component with `holos render platform --selector component=cilium`.

## Bootstrap Argo CD

Argo CD needs pod networking, and DNS to reach GitHub, before it can sync
anything, so a new cluster gets four components by hand: `cilium`,
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

The local `admin`, through a port-forward, with the argocd CLI or a browser
at https://localhost:8443. The certificate is the server's own self-signed
one, hence `--insecure`.

```sh
kubectl -n argocd port-forward svc/argocd-server 8443:443 &
argocd login localhost:8443 --insecure --username admin --password \
  "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
argocd app list
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
kubectl -n spike-test get svc echo   # EXTERNAL-IP from 10.20.0.30-.33
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
do not answer ping.

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
