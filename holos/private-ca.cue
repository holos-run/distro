package holos

import (
	"regexp"
	"strings"
)

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

	// requesters is what the ClusterIssuer may sign, by the namespace of the
	// Certificates that ask, then by the Certificate's name: the DNS names
	// it carries, and the usages and the common name if it sets any. The
	// private-ca component renders one CertificateRequestPolicy,
	// private-ca-<namespace>, per namespace, which approves a request from
	// that namespace for exactly these and nothing else; a namespace not
	// listed has no policy, and its requests are denied (README.md, "The
	// private CA"). Each Certificate takes these fields from its own entry,
	// so the names are written once.
	//
	// Every DNS name, and the common name, is within one of
	// permittedDNSDomains, the root's permitted subtrees, so a Certificate
	// outside them fails here, at render, rather than at its first TLS
	// handshake, where a client that enforces the root's constraints
	// refuses it. (Go ignores a common name; OpenSSL checks one that looks
	// like a host name when there is no DNS name.)
	//
	// The entries are in components/private-ca.cue, beside the other
	// components' shared names, which they are made from; only a component
	// knows the cluster it renders for.
	requesters: [Namespace=string]: [Certificate=string]: {
		dnsNames: [Within, ...Within]
		usages?: [string, ...string]
		commonName?: Within
	}

	// permittedDNSDomains are the DNS subtrees the root's name constraints
	// permit (components/private-ca), and so the only names a certificate
	// it signs may carry: each is the domain itself and every name under
	// it, as RFC 5280 matches a dNSName constraint. They are set in
	// components/private-ca.cue, from the cluster's domains; optional here,
	// outside any component, where there is no cluster to make them from.
	permittedDNSDomains?: [string, ...string]

	// Within is a DNS name in one of permittedDNSDomains: equal to one, or
	// ending in a dot and one, which allows a leading *. label as well. The
	// match is by whole labels, as the root's is: with svc.cluster.local
	// permitted, foo.svc.cluster.local is within it, but foo.cluster.local
	// and xsvc are not.
	let Within = =~"^(.+\\.)?(\(strings.Join([for D in permittedDNSDomains {regexp.QuoteMeta(D)}], "|")))$"
}
