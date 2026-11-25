package holos

// Istio's release on this cluster, from its pins (pins/<cluster>.cue). The
// names are in istio.cue at the platform root.
Istio: {
	let Pins = Cluster.pins.istio

	// version is the release of all four charts, from
	// oci://ghcr.io/istio/release/charts, and of the images. It is of the
	// minor the gateway-api component's CRDs match. 1.31 lists Kubernetes 1.32
	// to 1.36; the Substrate spike ran it on 1.37.
	version: Pins.version

	// images are the ambient profile's distroless images on docker.io/istio,
	// pinned by digest (the tag is kept for the reader). proxyv2 runs every
	// gateway and waypoint istiod deploys, so it is pinned in istiod's values,
	// from which istiod renders their Deployments.
	images: {for NAME, DIGEST in Pins.digests {(NAME): "docker.io/istio/\(NAME):\(version)-distroless@\(DIGEST)"}}
}
