package holos

// trust-manager copies the private CA's root into every namespace
// (private-ca-bundle holds the Bundle).
//
// v0.26.0, the latest stable, from Jetstack's OCI chart, with the images the
// chart names on quay.io, pinned by digest. It runs in cert-manager's
// namespace, which is also its trust namespace, where the root's Secret is.
TrustManagerVersion: "v0.26.0"

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
			digest: "sha256:783afe31d39f122a811b96ac3aedab9f358488088df21622ae5b057b4a38b5c2"
		}
		// The public CA package (Debian trixie's) that Bundles can include
		// with useDefaultCAs. The private-ca Bundle does not, but the chart's
		// default keeps it available to Bundles that do. This one lacks the
		// compromised eMudhra roots v0.25.0's chart still carried.
		defaultPackageImage: {
			tag:    "20250419-deb13u1.1"
			digest: "sha256:477cc69ef6a026b90a6d67d4ac7114735c5f66edf1cc97e68b9da599adf231af"
		}
		app: trust: namespace: PrivateCA.namespace
		// The webhook's serving certificate comes from cert-manager (the
		// chart's self-signed Issuer and Certificate). helmCert would have
		// helm template generate a key into deploy/.
		app: webhook: tls: helmCert: enabled: false
	}
}).artifact]
