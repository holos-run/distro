package holos

// Istio names the mesh, Istio in ambient mode (interview Q16): the release,
// the namespace its control plane and node agents run in, its images and its
// trust domain. The istio-base, istiod, istio-cni and ztunnel components
// install it; anything that names a mesh identity or enrolls a namespace
// reads it here.
Istio: {
	// version is the release of all four charts, from
	// oci://ghcr.io/istio/release/charts, and of the images. 1.31.3 is the
	// latest patch of 1.31, the release the gateway-api component's CRDs
	// match. 1.31 lists Kubernetes 1.32 to 1.36; the Substrate spike ran it
	// on 1.37.
	version: "1.31.3"
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
		pilot:         "sha256:1b0e5f3bddf0cc472dce4dc44bb1d6880b6b598df5fe2eb5e5b7b88627debf6a"
		proxyv2:       "sha256:ca2a25ce888e73e8c3c2b8a3a7d5e8f4b089adc80fa2baf00fe2efd74e55c57e"
		"install-cni": "sha256:42cb4521bfef160fbe60087f2d68ba630c7220ebc4260388a9897eb75063731e"
		ztunnel:       "sha256:5235c45bbfc4f11c45496ea69906aa4d305264f8b29bf5b2ba6e785ef82818f7"
	}

	// trustDomain is the mesh's SPIFFE trust domain, Istio's default, stated
	// because identities are rendered from it: a workload's is
	// spiffe://<trustDomain>/ns/<namespace>/sa/<service account>.
	trustDomain: "cluster.local"

	// ambient is the label that enrolls a namespace's pods in the mesh:
	// ztunnel carries their traffic over HBONE (port 15008) with mutual TLS.
	ambient: "istio.io/dataplane-mode": "ambient"

	// podNetwork is the node affinity Cilium's pods carry: nodes labeled
	// holos.run/pod-network=none, the control plane, have no pod network.
	// istio-cni and ztunnel tolerate every taint, so without it their pods
	// land on the control plane and never start.
	podNetwork: nodeAffinity: requiredDuringSchedulingIgnoredDuringExecution: nodeSelectorTerms: [{
		matchExpressions: [{
			key:      "holos.run/pod-network"
			operator: "NotIn"
			values: ["none"]
		}]
	}]
}
