package holos

// The platform renders every registered component once per cluster in
// clusters (clusters.cue), into deploy/clusters/<cluster>/components/<name>.
// Inspect the result with `holos show platform`.
//
// See https://holos.run/docs/api/author/v1alpha6/#Platform
platform: name: "distro"

// registry lists the components, in apply order. Until Argo CD exists the
// order is the order README.md applies them by hand.
registry: [
	// cilium is the CNI and kube-proxy replacement. Nothing else gets a pod
	// address until it is up.
	{name: "cilium"},
	// cilium-resources holds the Cilium custom resources: the LB IPAM pool,
	// the L2 announcement policy and the ambient kubelet probe policy. The
	// operator registers their CRDs, so they apply after cilium is running.
	{name: "cilium-resources"},
	// coredns replaces the CoreDNS Talos deploys, to own the Corefile.
	{name: "coredns"},
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
]

for CLUSTER in clusters for C in registry {
	platform: components: "\(CLUSTER.name):\(C.name)": {
		name: C.name
		path: "components/\(C.name)"
		parameters: clusterName: CLUSTER.name
		labels: {
			cluster:   CLUSTER.name
			component: C.name
		}
		annotations: "app.holos.run/description": "\(C.name) for cluster \(CLUSTER.name)"
	}
}
