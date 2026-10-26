package holos

// PrivateCA names the cluster's private certificate authority and the trust
// bundle that distributes its root, so components that issue from it or
// trust it refer to these names rather than repeating them.
//
// A self-signed bootstrap Issuer signs the root, stored as a Secret; the
// ClusterIssuer issues every certificate in the cluster from that Secret;
// trust-manager copies the root into a ConfigMap in every namespace. The root
// is generated in the cluster and never enters git: a recreated cluster has a
// new root, which the laptop must import again (README.md, "The private CA").
PrivateCA: {
	// namespace holds the root's Secret. It is cert-manager's cluster
	// resource namespace, where a ClusterIssuer reads its CA Secret, and
	// trust-manager's trust namespace, where a Bundle reads its sources.
	namespace: "cert-manager"
	// bootstrapIssuer is the namespaced self-signed Issuer that signs the
	// root and nothing else.
	bootstrapIssuer: "private-ca-bootstrap"
	// root is the root's Certificate and Secret.
	root: "private-ca-root"
	// issuer is the ClusterIssuer every component issues from.
	issuer: "private-ca"
	// bundle is the trust-manager Bundle and the ConfigMap it writes to every
	// namespace, holding the root in PEM under bundleKey.
	bundle:    "private-ca"
	bundleKey: "ca.crt"
}
