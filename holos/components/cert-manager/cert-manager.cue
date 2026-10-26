package holos

// cert-manager issues the cluster's certificates; private-ca configures the
// CA it issues from.
//
// v1.21.3, the latest stable, from the OCI chart Jetstack publishes, with the
// images the chart names on quay.io, pinned by digest (the tag is kept for
// the reader; only the digest is pulled). quay.io/jetstack
// allows anonymous pulls.
CertManagerVersion: "v1.21.3"

CertManagerNamespace: "cert-manager"

let Webhook = webhookServices["cert-manager-webhook"]

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: CertManagerNamespace
	chart: {
		name:    "oci://quay.io/jetstack/charts/cert-manager"
		version: CertManagerVersion
		release: "cert-manager"
	}
	values: {
		// The CRDs are part of the chart's output and of this component. The
		// chart's default crds.keep marks them helm.sh/resource-policy: keep,
		// which only Helm reads.
		crds: enabled: true

		image: {
			tag:    CertManagerVersion
			digest: "sha256:9f4f96a33c7774cef24466fcd85031997531a03a8d117f151126baa8d1290dcc"
		}
		cainjector: image: {
			tag:    CertManagerVersion
			digest: "sha256:083d0e906f8eb44e255fe4ff817ae54e49f9ed82e22f1011bb4e9e4f4b8a641f"
		}
		webhook: {
			image: {
				tag:    CertManagerVersion
				digest: "sha256:055ac8e9de6a0ba6763794838fe38944acc650f68ebe1b01dd8be079e580f458"
			}
			// The webhook's dynamic serving certificate also carries the
			// hostname the API server dials through the Gateway
			// (webhooks.cue). The chart's webhook.url.host would add it too,
			// but it renders the URL without a port.
			extraArgs: ["--dynamic-serving-dns-names=\(Cluster.webhooks.hosts[Webhook.name])"]
		}
		// startupapicheck is a post-install Helm hook Job, which holos does
		// not render (helm template --no-hooks). Off, so the values say so.
		startupapicheck: enabled: false
	}

	resources: Namespace: (CertManagerNamespace): _

	// Both webhook configurations are served by the one webhook Service.
	patches: [
		(#WebhookPatch & {
			kind:    "ValidatingWebhookConfiguration"
			name:    "cert-manager-webhook"
			service: Webhook.name
			webhooks: "webhook.cert-manager.io": path: "/validate"
		}).patch,
		(#WebhookPatch & {
			kind:    "MutatingWebhookConfiguration"
			name:    "cert-manager-webhook"
			service: Webhook.name
			webhooks: "webhook.cert-manager.io": path: "/mutate"
		}).patch,
	]
}).artifact]
