package holos

// cert-manager issues the cluster's certificates; private-ca configures the
// CA it issues from and the policies approver-policy approves requests by.
//
// It is the OCI chart Jetstack publishes, with the images the chart names on
// quay.io, pinned by digest (Cluster.pins.certManager; the tag is kept for
// the reader, and only the digest is pulled). quay.io/jetstack allows anonymous
// pulls.
let Pins = Cluster.pins.certManager

CertManagerNamespace: "cert-manager"

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: CertManagerNamespace
	chart: {
		name:    "oci://quay.io/jetstack/charts/cert-manager"
		version: Pins.version
		release: "cert-manager"
	}
	values: {
		// The CRDs are part of the chart's output and of this component. The
		// chart's default crds.keep marks them helm.sh/resource-policy: keep,
		// which only Helm reads.
		crds: enabled: true

		image: {
			tag:    Pins.version
			digest: Pins.digests.controller
		}
		cainjector: image: {
			tag:    Pins.version
			digest: Pins.digests.cainjector
		}
		webhook: image: {
			tag:    Pins.version
			digest: Pins.digests.webhook
		}
		// cert-manager's own approver approves every CertificateRequest for
		// any Issuer or ClusterIssuer, so anyone who may create a Certificate
		// could have the private CA sign any name, or a CA. It is off, with
		// the RBAC that lets it approve, and approver-policy decides alone,
		// against the CertificateRequestPolicies in private-ca (README.md,
		// "The private CA"). approver-policy binds a policy to a request by
		// its spec.username and spec.groups, which cert-manager's webhook
		// stamps; the webhook fails closed, so no request is made without
		// them.
		disableAutoApproval: true

		// startupapicheck is a post-install Helm hook Job, which holos does
		// not render (helm template --no-hooks). Off, so the values say so.
		startupapicheck: enabled: false
	}

	resources: Namespace: (CertManagerNamespace): _
}).artifact]
