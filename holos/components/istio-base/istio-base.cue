package holos

// istio-base is Istio's CRDs, its reader ServiceAccount, the istio-system
// namespace and the default revision's validating webhook. istiod, istio-cni
// and ztunnel follow it (registry.cue). Istio's names are in Istio
// (istio.cue).
//
// The validating webhook, istiod-default-validator, is served by istiod: the
// API server reaches it by the chart's service: reference to istiod, like
// istiod's own (ADR 0003).

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: Istio.namespace
	chart: {
		name:    "\(Istio.charts)/base"
		version: Istio.version
		release: "istio-base"
	}
	values: {
		// The revision whose istiod validates Istio resources in every
		// namespace. The chart's default, stated: the default revision is the
		// only one.
		defaultRevision: "default"
		// Fail, as istiod's own validator (istiod.cue) and as the chart
		// recommends for a tool that cannot tell an install from an upgrade:
		// helm template renders Ignore, istiod switches it to Fail once the
		// webhook answers, and Argo CD's self-heal would switch it back.
		base: validationFailurePolicy: "Fail"
	}

	// istio-cni and ztunnel run privileged pods on every node, which Talos's
	// baseline Pod Security enforcement refuses.
	resources: Namespace: (Istio.namespace): metadata: labels: "pod-security.kubernetes.io/enforce": "privileged"
}).artifact]
