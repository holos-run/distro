package holos

// ztunnel is ambient's node proxy, a DaemonSet that carries the traffic of
// every ambient pod on its node over HBONE, mutual TLS on port 15008, with
// the pod's mesh identity. Istio's names are in Istio (istio.cue).

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: Istio.namespace
	chart: {
		name:    "\(Istio.charts)/ztunnel"
		version: Istio.version
		release: "ztunnel"
	}
	values: {
		profile:  "ambient"
		image:    Istio.images.ztunnel
		affinity: Istio.podNetwork
	}
}).artifact]
