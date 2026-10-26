package holos

// The private CA's root in every namespace. trust-manager writes ConfigMap
// PrivateCA.bundle with the root in PEM under PrivateCA.bundleKey to every
// namespace, including ones created later, so any in-cluster client that
// calls a platform service over the gateway can mount it.
//
// istiod is one such client: it trusts /cacerts/extra.pem, besides the system
// pool, when it fetches the JWKS for a RequestAuthentication. That file comes
// from a ConfigMap, not from the cacerts Secret, so the Istio component mounts
// this ConfigMap's ca.crt there as extra.pem (README.md, "The private CA").
//
// Applied once trust-manager is running, since its CRD defines Bundle.

holos: spec: artifacts: [(#ResourcesArtifact & {
	resources: Bundle: (PrivateCA.bundle): spec: {
		sources: [{
			secret: {
				name: PrivateCA.root
				key:  "ca.crt"
			}
		}]
		target: configMap: key: PrivateCA.bundleKey
	}
}).artifact]
