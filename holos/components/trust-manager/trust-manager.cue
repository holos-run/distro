package holos

import "encoding/json"

// trust-manager copies the private CA's root into every namespace
// (private-ca-bundle holds the Bundle).
//
// v0.25.0, the latest stable, from Jetstack's OCI chart, with the images the
// chart names on quay.io, pinned by digest. It runs in cert-manager's
// namespace, which is also its trust namespace, where the root's Secret is.
TrustManagerVersion: "v0.25.0"

let Webhook = webhookServices["trust-manager"]

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: PrivateCA.namespace
	chart: {
		name:    "oci://quay.io/jetstack/charts/trust-manager"
		version: TrustManagerVersion
		release: "trust-manager"
	}
	values: {
		image: {
			tag:    TrustManagerVersion
			digest: "sha256:0521921c2a46d14d0417336b20bcde69215ef3164f2977cc939d53c6e5224a17"
		}
		// The public CA package (Debian trixie's) that Bundles can include
		// with useDefaultCAs. The private-ca Bundle does not, but the chart's
		// default keeps it available to Bundles that do.
		defaultPackageImage: {
			tag:    "20250419.2"
			digest: "sha256:3093d4f6634fbd9eaf6a70a06d809132850d7cae30da82396d3b1f884c1135e7"
		}
		app: trust: namespace: PrivateCA.namespace
		// The webhook's serving certificate comes from cert-manager (the
		// chart's self-signed Issuer and Certificate). helmCert would have
		// helm template generate a key into deploy/.
		app: webhook: tls: helmCert: enabled: false
	}

	patches: [
		(#WebhookPatch & {
			kind:    "ValidatingWebhookConfiguration"
			name:    "trust-manager"
			service: Webhook.name
			webhooks: "trust.cert-manager.io": path: "/validate-trust-cert-manager-io-v1alpha1-bundle"
		}).patch,
		// The serving certificate also carries the hostname the API server
		// dials through the load balancer (webhooks.cue).
		{
			target: {
				group:   "cert-manager.io"
				version: "v1"
				kind:    "Certificate"
				name:    "trust-manager"
			}
			patch: json.Marshal([{
				op:    "add"
				path:  "/spec/dnsNames/-"
				value: Cluster.webhooks.hosts[Webhook.name]
			}])
		},
	]
}).artifact]
