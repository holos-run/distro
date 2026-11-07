package holos

import (
	"encoding/json"
	"list"
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
// is generated in the cluster and never enters git: a new cluster has a new
// root, which the laptop must import (README.md, "The private CA"), and a
// rebuild keeps the old one by saving and restoring it with cmd/state
// (README.md, "Rebuilding a cluster").
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
	// issuerRef selects the ClusterIssuer, in a Certificate or in a
	// CertificateRequestPolicy's selector.
	issuerRef: {
		group: "cert-manager.io"
		kind:  "ClusterIssuer"
		name:  issuer
	}
	// certManager is cert-manager's controller's ServiceAccount, the
	// requester of every request made from a Certificate (spec.username,
	// which cert-manager's webhook stamps), whom a policy's use is granted
	// to. Its namespace is cert-manager's, which is namespace.
	certManager: {
		name:        "cert-manager"
		"namespace": namespace
	}
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
	//
	// A ProjectClaim's wildcards are not here: its atespace's on the shim,
	// and its zone's on the ingress Gateway where it has a binding. The claim
	// renders a policy of its own for each, ahead of its Certificate
	// (components/project), since an entry here would reach the cluster on
	// private-ca's sync, which nothing orders against the claim's.
	//
	// _rendered is whether the entry reaches a policy on this cluster. An
	// optional component's entry sets it (components/private-ca.cue), and a
	// namespace with none rendered has no policy. It is hidden because each
	// Certificate takes its entry whole, and a Certificate has no such field.
	requesters: [Namespace=string]: [Certificate=string]: {
		_rendered: bool | *true
		dnsNames: [#Within, ...#Within]
		usages?: [string, ...string]
		commonName?: #Within
	}

	// permittedDNSDomains are the DNS subtrees the root's name constraints
	// permit (components/private-ca), and so the only names a certificate
	// it signs may carry: each is the domain itself and every name under
	// it, as RFC 5280 matches a dNSName constraint. They are set in
	// components/private-ca.cue, from the cluster's domains; optional here,
	// outside any component, where there is no cluster to make them from.
	permittedDNSDomains?: [string, ...string]

	// #Within is a DNS name in one of permittedDNSDomains: equal to one, or
	// ending in a dot and one, which allows a leading *. label as well. The
	// match is by whole labels, as the root's is: with svc.cluster.local
	// permitted, foo.svc.cluster.local is within it, but foo.cluster.local
	// and xsvc are not.
	#Within: =~"^(.+\\.)?(\(strings.Join([for D in permittedDNSDomains {regexp.QuoteMeta(D)}], "|")))$"
}

// #Exactly is an allowed string list of approver-policy's that permits
// exactly the names given. values are patterns, in which * matches any
// string, so *.treasury.bank.internal would also allow
// keycloak.treasury.bank.internal; where a name has a *, a CEL rule also
// requires each value to be one of the names as written.
#Exactly: {
	names: [...string]
	out: {
		required: true
		values:   names
		if list.Contains([for N in names {strings.Contains(N, "*")}], true) {
			validations: [{
				rule:    "self in \(json.Marshal(names))"
				message: "must be one of these exactly, * included: \(strings.Join(names, ", "))"
			}]
		}
	}
}
