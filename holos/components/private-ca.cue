package holos

// The private CA's requesters (PrivateCA.requesters, private-ca.cue): every
// Certificate in the cluster that the private-ca ClusterIssuer signs, by
// namespace and name, with what it asks for. The private-ca component turns
// each namespace into a CertificateRequestPolicy, and each Certificate
// below takes its fields from its entry. A component that adds a Certificate
// from the ClusterIssuer adds its entry here; without one its first request
// is denied, by deny-all, the first time it syncs.
//
// The names are made from each component's shared names, so they follow
// the components' own. A field the Certificate sets that its entry does not
// list, such as a subject, makes the request carry something its policy
// does not allow, and it is denied.

let DB = Substrate.database
let CNPG = webhookServices["cnpg-webhook-service"]
let ESO = webhookServices["external-secrets-webhook"]

PrivateCA: requesters: {
	// The Substrate database's server certificate (components/substrate),
	// for the names a client in the cluster reaches the -rw Service by. It
	// asks for server auth alone.
	(Substrate.namespace): "\(DB.cluster)-server": {
		dnsNames: [
			"\(DB.cluster)-rw",
			"\(DB.cluster)-rw.\(Substrate.namespace)",
			DB.host,
			"\(DB.host).\(Cluster.network.dnsDomain)",
		]
		usages: ["server auth"]
	}
	// The webhooks' serving certificates (components/cloudnative-pg,
	// components/external-secrets): the Service's cluster name and the
	// hostname the API server dials through the Gateway (webhooks.cue).
	(CNPG.namespace): "cnpg-webhook": dnsNames: [
		"\(CNPG.name).\(CNPG.namespace).svc",
		Cluster.webhooks.hosts[CNPG.name],
	]
	(ESO.namespace): "external-secrets-webhook": dnsNames: [
		"\(ESO.name).\(ESO.namespace).svc",
		Cluster.webhooks.hosts[ESO.name],
	]
	// The Kubernetes API's host on holos-authenticator's Gateway
	// (components/holos-authenticator).
	(HolosAuthenticator.namespace): (HolosAuthenticator.gateway.name): dnsNames: [HolosAuthenticator.host]
	// The ingress Gateway's wildcard (components/ingress-gateway).
	(IngressGateway.namespace): wildcard: dnsNames: [IngressGateway.wildcard]
	// One wildcard per atespace on the Substrate shim's Gateway
	// (components/substrate-shim).
	(AteGateway.namespace): {
		for A in AteGateway.atespaces {
			"\(A.name)-wildcard": dnsNames: [A.hostname]
		}
	}
}
