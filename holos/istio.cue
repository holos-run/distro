package holos

// Istio names the mesh, Istio in ambient mode (interview Q16): the release,
// the namespace its control plane and node agents run in, its images and its
// trust domain. The istio-base, istiod, istio-cni and ztunnel components
// install it; anything that names a mesh identity or enrolls a namespace
// reads it here.
Istio: {
	// version is the release of all four charts, from
	// oci://ghcr.io/istio/release/charts, and of the images. 1.31.4 is the
	// latest patch of 1.31, the release the gateway-api component's CRDs
	// match. 1.31 lists Kubernetes 1.32 to 1.36; the Substrate spike ran it
	// on 1.37.
	version: "1.31.4"
	charts:  "oci://ghcr.io/istio/release/charts"

	// namespace holds istiod, istio-cni and ztunnel. The node agents need
	// privileged pods, so it is labeled out of Talos's baseline Pod Security
	// enforcement.
	namespace: "istio-system"

	// images are the ambient profile's distroless images on docker.io/istio,
	// pinned by digest (the tag is kept for the reader). proxyv2 runs every
	// gateway and waypoint istiod deploys, so it is pinned in istiod's values,
	// from which istiod renders their Deployments.
	images: [NAME=string]: "docker.io/istio/\(NAME):\(version)-distroless@\(digests[NAME])"
	images: {
		pilot:         _
		proxyv2:       _
		"install-cni": _
		ztunnel:       _
	}
	let digests = {
		pilot:         "sha256:2bc9c4190eec5146c6dacb3e2b81fe2752ecd4f5f5198e51fb27ca67b5930312"
		proxyv2:       "sha256:553f3640686d588531426e4c6b6810390b230374b7f83aae65fe4c68efccf1cc"
		"install-cni": "sha256:f80f8bd86001494329d62544da21d75570eef4582f6e95f431296f3bc13b9629"
		ztunnel:       "sha256:7e62e32aebed2cc220aa7a03818b3a0ab6056af462bf3b6a287ea7c6bd3aeec6"
	}

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
