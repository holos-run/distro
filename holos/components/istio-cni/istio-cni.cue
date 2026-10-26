package holos

// istio-cni is Istio's CNI node agent, a DaemonSet that chains itself after
// Cilium and, for pods in ambient namespaces, redirects their traffic to the
// node's ztunnel. Istio's names are in Istio (istio.cue).
//
// The chart's paths, /opt/cni/bin, /etc/cni/net.d and /var/run/netns, are
// where Talos keeps them, so they are left at their defaults; the Substrate
// spike confirmed its plugin chains into 05-cilium.conflist. The Cilium
// values need nothing for it (README.md, "Cilium").

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: Istio.namespace
	chart: {
		name:    "\(Istio.charts)/cni"
		version: Istio.version
		release: "istio-cni"
	}
	values: {
		profile:  "ambient"
		image:    Istio.images["install-cni"]
		affinity: Istio.podNetwork
	}
}).artifact]
