package holos

// Istio names the mesh, Istio in ambient mode (interview Q16): the namespace
// its control plane and node agents run in, its charts and its trust domain.
// The istio-base, istiod, istio-cni and ztunnel components install it;
// anything that names a mesh identity or enrolls a namespace reads it here.
// The release and its images, which are the cluster's, are in
// components/istio.cue.
Istio: {
	// charts is where the four charts are.
	charts: "oci://ghcr.io/istio/release/charts"

	// namespace holds istiod, istio-cni and ztunnel. The node agents need
	// privileged pods, so it is labeled out of Talos's baseline Pod Security
	// enforcement.
	namespace: "istio-system"

	// trustDomain is the mesh's SPIFFE trust domain, Istio's default, stated
	// because identities are rendered from it: a workload's is
	// spiffe://<trustDomain>/ns/<namespace>/sa/<service account>.
	trustDomain: "cluster.local"

	// ambient is the label that enrolls a namespace's pods in the mesh:
	// ztunnel carries their traffic over HBONE (port 15008) with mutual TLS.
	ambient: "istio.io/dataplane-mode": "ambient"

	// offControlPlane is the node affinity istio-cni and ztunnel carry: nodes
	// labeled node-role.kubernetes.io/control-plane, which Talos sets on
	// every control plane, are left out. Both tolerate every taint, so
	// without it their pods land on the control plane, where istio-cni
	// would rewrite the API server's host-network sockets.
	offControlPlane: nodeAffinity: requiredDuringSchedulingIgnoredDuringExecution: nodeSelectorTerms: [{
		matchExpressions: [{
			key:      "node-role.kubernetes.io/control-plane"
			operator: "DoesNotExist"
		}]
	}]
}
