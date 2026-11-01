# 0003. Control plane to pod network Service contract

Status: accepted, 2026-10-31

## Context

Three kinds of extension make the API server a client of software running
in the cluster: admission webhooks, CRD conversion webhooks and aggregated
APIs. On a stock cluster each is a Service with a selector and a `service:`
reference naming it. That is the form the Kubernetes reference prescribes,
"If the webhook is running within the cluster, then you should use
`service` instead of `url`"
(https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/),
the form the kubebuilder scaffold generates, a `webhook-service` named in
the configuration, selecting the manager's pods, and a cert-manager
Certificate whose CA cainjector copies into the configuration
(https://book.kubebuilder.io/cronjob-tutorial/running-webhook.html), and
the form every chart the distro packages ships by default.

On a managed control plane that cannot reach the pod network, charts grow a
setting per provider: `hostNetwork` on EKS with a custom CNI, port 10250
for GKE private clusters, a `url:` for a remote istiod. The distro today
carries the heaviest form of that per-provider configuration itself.
ADR 0001 keeps the garage's control plane off the pod network to model GKE
and EKS (Agent_Substrate_Day_MVP Q33), and treats the API server as a client
of the ingress Gateway's address (Agent_Substrate_Day_MVP Q34 revisited,
and Q68 for approver-policy). So `holos/webhooks.cue` registers six webhook
Services; seven components (approver-policy, cert-manager, cloudnative-pg,
external-secrets, istio-base, istiod and trust-manager) rewrite eleven
webhook configurations from `service:` to `url:` through `#WebhookPatch`
(`holos/components/webhooks.cue`); five of the six serving certificates
carry an extra Gateway hostname, and approver-policy's, which can carry
only the Service's name, has the host entry map that name instead; the
ingress Gateway has two passthrough listeners on port 9443 with a TLSRoute
per entry; and `holos/talos.cue` renders a
`StaticHostConfig` into the control plane's machine config, the one place
the base still reaches into the layer beneath it. Because a webhook was
unreachable until the Gateway came up, provisioning became two steps,
`Ignore` then `Fail`, switched by the per-cluster `webhooks.enforcing` flag
(Agent_Substrate_Day_MVP Q35, Q43 and Q44).

The Talos_Control_Plane_Ready project set out to replace that path with
Konnectivity, on the premise that EKS, GKE and the garage all use it
(Talos_Control_Plane_Ready Q2). The research behind this record found the
premise false. EKS gives no way to set the API server's egress selector:
the request for the control plane to reach a single, un-chained Cilium
overlay has been open on AWS's roadmap since 2023 with no answer
(https://github.com/aws/containers-roadmap/issues/2227); Cilium's
installation guide says "the EKS API Server is unable to route packets to
the overlay network", so a webhook there "must be host networked or exposed
through a service or ingress"
(https://docs.cilium.io/en/stable/installation/k8s-install-helm/); and the
pinned Cilium issue on the subject records users settling on `hostNetwork`
for every component the API server calls
(https://github.com/cilium/cilium/issues/30111). The only EKS-side answers
are ENI mode, `hostNetwork` per webhook, or a controller that rewrites each
webhook Service's endpoints to node addresses
(https://github.com/CharlieR-o-o-t/eks-webhook-proxy). GKE's control
plane reaches the cluster through managed Konnectivity, whose traffic
arrives from `konnectivity-agent` pods in `kube-system`
(https://docs.cloud.google.com/kubernetes-engine/docs/troubleshooting/kubectl);
whether webhook calls ride that tunnel is inferred, not documented, as the
Providers section says. Its default firewall lets the control plane reach
pods on ports 443 and 10250 only
(https://docs.cloud.google.com/kubernetes-engine/docs/how-to/private-clusters#add_firewall_rules).

What survives is the question one level up. The distro does not want to
maintain vendor-specific configuration for every webhook; it wants one
interface every Kubernetes provider can meet. The upstream convention is
that interface, stated here as a contract between the base and the
Kubernetes layer.

This record is published as accepted on the research alone. The payments
cluster in Talos_Control_Plane_Ready is its first proof
(Control_Plane_Service_Contract Q2, overruling the recommendation of a
throwaway cluster first), so the record says, where it matters, which of
its facts are documented and which are inferred or untried.

## Decision

### The contract

The base promises three things, numbered so the checker can name them.
They are required, and `contract-check` (below) checks them:

1. Every admission webhook, CRD conversion stanza and APIService names a
   Service by `service:`, never a `url:`.
2. The Service has a selector and is not headless.
3. The pods behind it run on the pod network, never on `hostNetwork`.

The kubebuilder scaffold's remaining conventions are the recommended form.
They are not checked, since istiod issues its own certificate and
cert-manager cannot issue its own webhook's
(Control_Plane_Service_Contract Q5):

- The Service port is 443. The pod port is whatever the chart uses, and is
  what GKE's firewall sees (below).
- A cert-manager Certificate on the `.svc` names,
  `<service>.<namespace>.svc` and `<service>.<namespace>.svc.cluster.local`.
- `cert-manager.io/inject-ca-from` on the webhook configuration or CRD, so
  cainjector fills the `caBundle`.

Third-party charts render with their defaults.

### Distribution-written admission

For admission logic the distro writes, in-process CEL comes first, a
ValidatingAdmissionPolicy or CRD validation rules, as Substrate and Gateway
API do, and a webhook in the canonical form second, only when CEL cannot
express the rule, such as digest verification against a registry
(Control_Plane_Service_Contract Q6). ValidatingAdmissionPolicy and
MutatingAdmissionPolicy need no network and are outside this contract.

### What the base leaves alone

The base does not rewrite `failurePolicy` or `timeoutSeconds`; both are the
chart's. Ordering is Argo CD's sync waves, as on any stock cluster. The
two-step procedure of ADR 0001, `Ignore` then `Fail` switched by the
per-cluster `webhooks.enforcing` flag, is retired: it existed only because
a webhook was unreachable until the Gateway came up
(Control_Plane_Service_Contract Q14).

### What the Kubernetes layer promises

The Kubernetes layer promises that the API server reaches every such
Service, and nothing more.

One `ServiceResolver`, built once from `--enable-aggregator-routing`,
serves admission, conversion and the aggregator alike, dialing either the
Service's ClusterIP or one of its endpoints. GKE and EKS both dial
endpoints: GKE on a Kubernetes maintainer's statement that it enables the
flag because Service IPs are not routable from its API server, EKS on the
inference recorded under Providers; no Google or AWS document states
either. Which one a provider uses is the provider's business, and the
base may not depend on it, so a selectorless Service with a hand-made
EndpointSlice is as much a violation as a `url:`, and so is a headless
Service, which only works when the resolver dials endpoints.

The Kubernetes layer also publishes where calls from the API server arrive
from, as `Cluster.apiServer.from`, a list in the NetworkPolicyPeer shape
that a base NetworkPolicy copies into its `ingress[].from` to admit the
control plane to a webhook port without naming a provider:
`konnectivity-agent` pods in `kube-system` on GKE, as far as the research
shows, and node addresses on EKS (Control_Plane_Service_Contract Q9).
This record names the field; its first consumer adds it and establishes
the garage's value (Control_Plane_Service_Contract Q19). The garage's
value is not simply the control plane node's address: once the node runs
a Cilium agent its address carries the `remote-node` identity, which Cilium
matches against `ipBlock` rules only under `policyCIDRMatchMode: nodes`. The existing comment on
`Cluster.apiServer` (`holos/clusters.cue`), that the control plane runs no
Cilium agent so no selector reaches it, goes stale the day the garage
follows this record; `apiServer.address` and `apiServer.port` stay the
egress target a pod dials, and `apiServer.from` is the opposite direction.

### Enforcement

ADR 0001's reason for keeping the control plane off the pod network was
that "a lab control plane that shares the pod network hides these
constraints until a component meets a managed control plane in
production". The contract answers that directly: the constraint a managed
control plane imposes is that the base uses Service references and nothing
else, and a check states it rather than relying on the network to fail.

`cmd/contract-check`, a Go program this project adds to the repository,
run as `go run ./cmd/contract-check holos/deploy`, reads the rendered
tree once per `clusters/<cluster>` subtree, pairs each webhook configuration,
conversion stanza and APIService with its Service and that Service's pod
templates in the same namespace, and fails on a `url:`, a Service missing,
without a selector or headless, a selector matching no pod template, or a
serving pod on `hostNetwork`. It will run in CI's render job beside the
check that `holos/deploy` matches the CUE, and by hand with `go run`. It
reads a whole cluster's tree rather than one component at a time because
istio-base's webhook names istiod's Service, which another component
renders, so a per-component BuildPlan validator could not pair them
(Control_Plane_Service_Contract Q7). The program itself, its output and its
tests are the contract-checker-over-the-rendered-tree item of this
project; the policy is here.

A chart that cannot comply carries the exception annotation
(Control_Plane_Service_Contract Q8):

- The key is `holos.run/contract-exception`. It goes on the webhook
  configuration, CRD or APIService, never on the Service.
- It is set in the component's CUE, never by editing the render, so it
  travels with the resource and one search of `holos/deploy` lists every
  exception.
- Its value is one sentence naming why the chart cannot comply, an ADR by
  number or a Planboard item, and what removes it. The checker reports the
  exception and passes, and fails an exception whose reason names no ADR
  and no Planboard item, or one on a resource that already complies, so
  an exception cannot outlive its reason.

The first exceptions are the eleven webhook configurations treasury still
routes through the Gateway. Nothing carries the annotation yet;
`#WebhookPatch` will add it in the change that lands the checker, so CI is
green that day. On treasury's trust-manager configuration it will read:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: trust-manager
  annotations:
    holos.run/contract-exception: >-
      ADR 0001's Gateway webhook path, kept on treasury until its rebuild;
      see ADR 0003 and
      Talos_Control_Plane_Ready/rebuild-treasury-on-the-new-layer
```

The rebuild of treasury on the new layer deletes the patch and removes the
annotations with it. Before reaching for an exception, a component tries,
in order: the chart's defaults, which comply on every chart the distro
packages today; an upstream fix, where a chart's default does not; and
only then the exception.

### Providers

Each Kubernetes layer must satisfy three things:

1. The API server reaches every Service a `service:` reference in the
   cluster's tree names.
2. `Cluster.apiServer.from` is set to where its calls arrive from.
3. Every pod port behind such a Service is reachable from the API server,
   whatever number the chart chose.

**The garage.** The Talos control plane joins Cilium. The API server is a
host-network static pod; once the node is no longer excluded, the Cilium
chart's tolerations put the agent on it, and the agent's socket load
balancer gives host-namespace processes ClusterIP translation. The node
turns Ready and stays unschedulable under the default control plane taint.
`--enable-aggregator-routing` stays on, matching GKE and EKS, so a Service
that only works by ClusterIP fails in the garage first
(Control_Plane_Service_Contract Q10). The `holos.run/pod-network: none`
label is read by more than Cilium: istio-cni and ztunnel, local-path and
ceph-csi-rbd, and the L2 announcement policy all key off it, and the
restart command treats a NotReady control plane as normal, so joining
Cilium is a decision per consumer, keeping istio-cni, ztunnel, storage and
LoadBalancer announcement off the node that holds the cluster's secrets.
Two facts are untried, not documented: that a Talos API server reaches a
stock `service:` webhook with the agent on its node, which rests on the
socket load balancer and a correct `cgroup.hostRoot`; and what the agent
and envoy cost the control plane node in memory. The payments cluster in
Talos_Control_Plane_Ready settles both.

**GKE.** Managed Konnectivity is the mechanism this record infers for
GKE. Google's troubleshooting page says that proxied traffic from the
control plane arrives from `konnectivity-agent` pods in `kube-system`, by
saying a NetworkPolicy that blocks ingress from `kube-system` breaks the
proxy and by giving the `namespaceSelector` and `podSelector` that admit it
(https://docs.cloud.google.com/kubernetes-engine/docs/troubleshooting/kubectl).
That page covers kubectl's exec, logs and port-forward, not webhooks, and
a Kubernetes maintainer wrote on the AWS roadmap issue above that GKE
reaches webhooks by `--enable-aggregator-routing` rather than Konnectivity,
so where webhook calls arrive from on GKE is not documented; the GKE
provider's first NetworkPolicy consumer establishes `apiServer.from` there.
GKE's default firewall lets the control plane reach pod ports 443 and
10250 only, and "any API that has a ServiceReference field requires
additional firewall rules" for other ports
(https://docs.cloud.google.com/kubernetes-engine/docs/how-to/private-clusters#add_firewall_rules),
so a webhook whose pod port is another number needs a firewall rule, which
is the GKE provider's part of the contract rather than a chart setting. The
research behind this record also found that GKE refuses `url:` webhooks
outright when control plane egress is restricted, the convention enforced
from the other side; neither Google page cited here documents it.

**EKS.** The EKS layer needs a controller that discovers the Services
behind every webhook configuration and conversion webhook by itself, with
no configuration per webhook, and makes their endpoints reachable from the
control plane. The pattern is eks-webhook-proxy's: a NodePort clone of
each Service, an EndpointSlice of node addresses, the selector removed at
runtime. This record names the pattern and its requirements, not the code
(Control_Plane_Service_Contract Q11): the project is ten months old, from
January 2026, with one author, and nothing can test it until an EKS
cluster exists, so the EKS provider's own project chooses adopt, fork or
rewrite, and the Argo CD `ignoreDifferences` rule the selector removal
needs. That the EKS API
server resolves `service:` to endpoints, which the pattern depends on, is
inferred from a flag dump in control plane logs, the open roadmap issue
and the fact that `hostNetwork` webhooks work there; no AWS document
states it.

## Consequences

Once the garage follows, all of this goes, in Talos_Control_Plane_Ready:
`holos/webhooks.cue` and its registry of webhook Services; `#WebhookPatch`
and its eleven call sites; the Gateway's two webhooks listeners and the
TLSRoute per entry; the extra hostnames on each serving certificate
(cert-manager's `--dynamic-serving-dns-names`, istiod's `ISTIOD_CUSTOM_HOST`,
trust-manager's Certificate and the private CA's Certificates for
CloudNativePG and External Secrets); the `StaticHostConfig` rendered by
`holos/talos.cue`; and `Cluster.webhooks`, with the `enforcing` flag, its
`failurePolicy` derivation and cert-manager's `disableAutoApproval`
coupling. Treasury keeps ADR 0001's form until its rebuild; from the day
the checker lands until then, its eleven webhook configurations carry the
exception annotation.

Joining Cilium changes the one node that holds the cluster's secrets. The
Cilium agent and envoy run there as system DaemonSets, so ADR 0001's
"workloads never run on the control plane" becomes "no workload pods": the
taint stays, and every other consumer of the pod network label stays off
the node. A `url:` or an APIService pointed at an internal Service by
anyone who can write webhook configurations is a path the Gateway did not
offer; that is cluster-admin level access, and the
admission-policy-denying-url-webhooks-in-the-cluster item of this project
is the cluster-side complement to the render check. istio-cni stays off the
node, so its rewriting of host-network sockets never touches the API
server.

The check reads Git only. A controller that registers its webhook
configuration at runtime bypasses it, which the admission policy above
closes. Every default-deny ingress policy on a webhook pod will need
`Cluster.apiServer.from`; the first one adds the field.

The policy reverses the off-the-pod-network half of Agent_Substrate_Day_MVP
Q33, the webhook path of Q34 revisited and Q68, the two-step procedure of
Q35, Q43 and Q44, and the Konnectivity half of Talos_Control_Plane_Ready
Q2. ADR 0001 is amended with a dated section pointing here. The Kubernetes
layer contract that Talos_Control_Plane_Ready planned as ADR 0003 becomes
ADR 0004 and cites this record for its reachability guarantee.

## Open for ADR 0004

Whether the CNI is a Kubernetes-layer fact rather than a base component,
given that GKE does not allow replacing its CNI, is left open for ADR 0004
(Control_Plane_Service_Contract Q12).
