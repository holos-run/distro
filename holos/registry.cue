package holos

// registry lists the platform's components in sync order. Every cluster in
// clusters (clusters.cue) gets every component (platform/platform.cue), and
// every component gets an Argo CD Application (components/argocd-apps) whose
// sync wave is its index here. The waves order only the root Application
// creating the Applications, when a cluster is bootstrapped: it creates one,
// waits for it to report Healthy, then creates the next. Once created, each
// Application polls main and syncs on its own, so a later merge syncs the
// components it touches in parallel, and a component whose dependency is
// not ready yet relies on its sync retry. The order is also the order to
// apply components by hand in.
registry: [...#Registration]

// #Registration is one component in the registry.
#Registration: {
	// name is the component's directory under components/ and its name in
	// deploy/ and in Argo CD.
	name: string
	// syncOptions are added to the Application's sync options, after the
	// ones every Application has.
	syncOptions: [...string]
}

registry: [
	// cilium is the CNI and kube-proxy replacement. Nothing else gets a pod
	// address until it is up.
	{name: "cilium"},
	// cilium-resources holds the Cilium custom resources: the LB IPAM pools,
	// the L2 announcement policy and the ambient kubelet probe policy. The
	// operator registers their CRDs when it starts, after cilium is synced,
	// so the dry run Argo CD makes before applying skips kinds it cannot
	// find yet.
	{
		name: "cilium-resources"
		syncOptions: ["SkipDryRunOnMissingResource=true"]
	},
	// coredns replaces the CoreDNS Talos deploys, to own the Corefile.
	{name: "coredns"},
	// argocd syncs everything from git, itself included. It needs pod
	// networking and DNS to reach GitHub, and nothing else, so it comes
	// straight after them.
	{name: "argocd"},
	// gateway-api is the Gateway API CRDs, standard channel, at the release
	// Istio supports, installed ahead of Istio.
	{name: "gateway-api"},
	// cert-manager, its CRDs and its webhook.
	{name: "cert-manager"},
	// private-ca is the bootstrap Issuer, the root and the ClusterIssuer. It
	// needs cert-manager's CRDs established and its controller running.
	{name: "private-ca"},
	// trust-manager, its Bundle CRD and its webhook. Its webhook certificate
	// is a cert-manager Certificate, so it comes after cert-manager.
	{name: "trust-manager"},
	// private-ca-bundle is the Bundle that copies the root into every
	// namespace. It needs trust-manager's CRD and the root's Secret.
	{name: "private-ca-bundle"},
	// istio-base is Istio's CRDs and the istio-system namespace, ahead of
	// everything else of Istio's.
	{name: "istio-base"},
	// istiod is the mesh's control plane. It mounts the private-ca
	// ConfigMap, so it comes after private-ca-bundle.
	{name: "istiod"},
	// istio-cni and ztunnel are the ambient node agents. Both wait on istiod
	// for their configuration and certificates.
	{name: "istio-cni"},
	{name: "ztunnel"},
	// cloudnative-pg is the CloudNativePG operator, its CRDs and its
	// webhooks; each consumer writes its own Cluster. Its webhook
	// certificate is a cert-manager Certificate from the private-ca
	// ClusterIssuer, and its webhook's TLSRoute is in its namespace, so it
	// comes after private-ca and before ingress-gateway.
	{name: "cloudnative-pg"},
	// external-secrets is the External Secrets operator, its CRDs and its
	// webhook; components generate their own secrets with it
	// (#GeneratedSecret). Its webhook certificate is a cert-manager
	// Certificate from the private-ca ClusterIssuer, and its webhook's
	// TLSRoute is in its namespace, so it comes after private-ca and before
	// ingress-gateway.
	{name: "external-secrets"},
	// ingress-gateway is the ingress Gateway, its wildcard certificate and
	// the routes of components that come before it. It needs the Gateway API
	// CRDs, the private-ca ClusterIssuer and istiod's istio GatewayClass.
	{name: "ingress-gateway"},
	// hello is the ambient echo service behind the gateway. It needs the node
	// agents and the Gateway.
	{name: "hello"},
	// ceph-csi-rbd is the Ceph RBD driver and the default StorageClass,
	// ceph-rbd. It needs pod networking alone, and its key's Secret, which is
	// made by hand; it comes ahead of every component that claims a volume.
	{name: "ceph-csi-rbd"},
	// local-path is the node-local fallback StorageClass, not the default.
	{name: "local-path"},
	// rustfs is the S3 store, RustFS standalone. It claims a ceph-rbd
	// volume and generates its keys with ExternalSecrets, so it comes after
	// ceph-csi-rbd and external-secrets; its Job registers the consumers'
	// buckets and users once RustFS is up.
	{name: "rustfs"},
	// argocd-apps is the platform AppProject and every component's
	// Application, its own included: its Application is the root Application.
	// It is last, so the root syncs every other Application before it waits
	// on itself.
	{name: "argocd-apps"},
]
