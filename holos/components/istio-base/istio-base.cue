package holos

// istio-base is Istio's CRDs, its reader ServiceAccount, the istio-system
// namespace and the default revision's validating webhook. istiod, istio-cni
// and ztunnel follow it (registry.cue). Istio's names are in Istio
// (istio.cue).
//
// The validating webhook, istiod-default-validator, is served by istiod, so
// it is registered under istiod's webhookServices entry (webhooks.cue) and
// is reached through the Gateway like istiod's own.

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
	}

	// istio-cni and ztunnel run privileged pods on every node, which Talos's
	// baseline Pod Security enforcement refuses.
	resources: Namespace: (Istio.namespace): metadata: labels: "pod-security.kubernetes.io/enforce": "privileged"

	patches: [(#WebhookPatch & {
		kind:    "ValidatingWebhookConfiguration"
		name:    "istiod-default-validator"
		service: "istiod"
		webhooks: "validation.istio.io": path: "/validate"
	}).patch]
}).artifact]
