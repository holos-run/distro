package holos

// trust-manager copies the private CA's root into every namespace
// (private-ca-bundle holds the Bundle).
//
// It is Jetstack's OCI chart, with the images the chart names on quay.io,
// pinned by digest (Cluster.pins.trustManager). It runs in cert-manager's
// namespace, which is also its trust namespace, where the root's Secret is.
let Pins = Cluster.pins.trustManager

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: PrivateCA.namespace
	chart: {
		name:    "oci://quay.io/jetstack/charts/trust-manager"
		version: Pins.version
		release: "trust-manager"
	}
	values: {
		image: {
			tag:    Pins.version
			digest: Pins.digest
		}
		// The public CA package (Debian trixie's) that Bundles can include
		// with useDefaultCAs. The private-ca Bundle does not, but the chart's
		// default keeps it available to Bundles that do. 20250419-deb13u1.1
		// lacks the compromised eMudhra roots v0.25.0's chart still carried.
		defaultPackageImage: {
			tag:    Pins.packages.version
			digest: Pins.packages.digest
		}
		app: trust: namespace: PrivateCA.namespace
		// The webhook's serving certificate comes from cert-manager (the
		// chart's self-signed Issuer and Certificate). helmCert would have
		// helm template generate a key into deploy/.
		app: webhook: tls: helmCert: enabled: false
	}
}).artifact]
