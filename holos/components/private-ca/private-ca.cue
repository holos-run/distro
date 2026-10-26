package holos

// The private CA (interview Q10): a self-signed bootstrap Issuer signs a
// root, stored as a Secret, and the ClusterIssuer issues from it. cert-manager
// generates the root's key in the cluster, so nothing secret is rendered.
// Names are in PrivateCA (private-ca.cue).
//
// Applied once cert-manager's CRDs are established and its controller is
// running.

let Site = Cluster.site

holos: spec: artifacts: [(#ResourcesArtifact & {
	resources: {
		// Namespaced, not a ClusterIssuer, so nothing outside cert-manager's
		// namespace can mint a self-signed certificate from it.
		Issuer: (PrivateCA.bootstrapIssuer): {
			metadata: namespace: PrivateCA.namespace
			spec: selfSigned: {}
		}

		// The root. Ten years, so it outlives any garage cluster. The key never
		// rotates: with cert-manager's default (Always), any reissue, a spec
		// edit or a manual renew, would make a new root that every certificate
		// already issued stops verifying against.
		Certificate: (PrivateCA.root): {
			metadata: namespace: PrivateCA.namespace
			spec: {
				isCA:       true
				commonName: "Holos \(Cluster.name) root CA"
				subject: {
					organizations: ["Holos"]
					organizationalUnits: ["\(Cluster.name).\(Site.privateDomain)"]
				}
				duration:   "87600h"
				secretName: PrivateCA.root
				privateKey: {
					algorithm:      "ECDSA"
					size:           256
					rotationPolicy: "Never"
				}
				issuerRef: {
					group: "cert-manager.io"
					kind:  "Issuer"
					name:  PrivateCA.bootstrapIssuer
				}
			}
		}

		ClusterIssuer: (PrivateCA.issuer): spec: ca: secretName: PrivateCA.root
	}
}).artifact]
