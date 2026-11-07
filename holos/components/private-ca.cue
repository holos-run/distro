package holos

// The private CA's permitted subtrees and its requesters
// (PrivateCA.permittedDNSDomains and PrivateCA.requesters, private-ca.cue):
// the domains the root may sign names in, and every Certificate in the
// cluster that the private-ca ClusterIssuer signs, but for a ProjectClaim's
// wildcards, each with a policy of its own (components/project), by namespace
// and name, with what it asks for. The private-ca component puts the subtrees
// in the root's name constraints and turns each namespace into a
// CertificateRequestPolicy, and each Certificate below takes its fields
// from its entry. A component that adds a Certificate
// from the ClusterIssuer adds its entry here; without one its first request
// is denied, by deny-all, the first time it syncs. An entry for an optional
// component says whether the cluster names it (_rendered, Takes), so its names
// are in no policy elsewhere. The entry itself stays: its component reads it,
// and cue vet evaluates that component for every cluster.
//
// The names are made from each component's shared names, so they follow
// the components' own. A field the Certificate sets that its entry does not
// list, such as a subject, makes the request carry something its policy
// does not allow, and it is denied.

let DB = Substrate.database

// CNPG and ESO are the webhook Services of CloudNativePG and External
// Secrets, whose serving certificates are the private CA's.
let CNPG = {name: "cnpg-webhook-service", namespace: "cnpg-system"}
let ESO = {name: "external-secrets-webhook", namespace: "external-secrets"}

// The root's permitted DNS subtrees (PrivateCA.permittedDNSDomains), which
// every name below must be within:
//
//   - the cluster's ingressDomain, which every published name is under:
//     the Gateways' wildcards and the Kubernetes API's host.
//   - svc, the Service names <service>.<namespace>.svc, which the API
//     server dials a webhook by (ADR 0003) and clients the database by.
//   - svc.<dnsDomain>, the same names fully qualified.
//
// Not the bare dnsDomain: only Services are named by the private CA, never
// a pod's name under it. A short name, <service> or <service>.<namespace>,
// is in none of them, so no certificate carries one.
PrivateCA: permittedDNSDomains: [
	Cluster.ingressDomain,
	"svc",
	"svc.\(Cluster.network.dnsDomain)",
]

PrivateCA: requesters: {
	// The Substrate database's server certificate (components/substrate),
	// for the -rw Service's cluster name, which every client dials
	// (Substrate.database.host), and that name fully qualified. Not the
	// short names, which are outside the root's permitted subtrees and
	// which no client uses; CloudNativePG's operator dials the pods by IP
	// and checks no name. It asks for server auth alone.
	(Substrate.namespace): "\(DB.cluster)-server": {
		_rendered: Takes.substrate
		dnsNames: [
			DB.host,
			"\(DB.host).\(Cluster.network.dnsDomain)",
		]
		usages: ["server auth"]
	}

	// The webhooks' serving certificates (components/cloudnative-pg,
	// components/external-secrets): the Service's cluster name, which the
	// API server dials by the configurations' service: reference (ADR 0003).
	(CNPG.namespace): "cnpg-webhook": dnsNames: ["\(CNPG.name).\(CNPG.namespace).svc"]
	(ESO.namespace): "external-secrets-webhook": dnsNames: ["\(ESO.name).\(ESO.namespace).svc"]
	// The Kubernetes API's host on holos-authenticator's Gateway
	// (components/holos-authenticator).
	(PlatformAuthenticator.namespace): (PlatformAuthenticator.gateway.name): dnsNames: [PlatformAuthenticator.host]
	// The ingress Gateway's wildcard (components/ingress-gateway).
	(IngressGateway.namespace): wildcard: dnsNames: [IngressGateway.wildcard]
	// One wildcard per atespace of the platform's on the Substrate shim's
	// Gateway (components/substrate-shim).
	(AteGateway.namespace): {
		for A in AteGateway.atespaces {
			"\(A.name)-wildcard": {
				_rendered: Takes["substrate-shim"] && A.rendered
				dnsNames: [A.hostname]
			}
		}
	}
}
