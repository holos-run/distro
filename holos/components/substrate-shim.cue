package holos

// AteGateway is the Substrate shim's Gateway, which the substrate-shim
// component renders: the one client of Substrate's router, which every actor
// is reached through at https://<actor>.<atespace>.ate.<domain>. It holds
// the policy that would break other clients on the shared ingress Gateway,
// since a RequestAuthentication applies to every request its gateway sees,
// and a bearer JWT from another issuer, such as a Quay registry token, would
// get 401 there. So it is a Gateway of its own, with no address: the ingress
// Gateway's ate listener passes every *.ate.<domain> connection through to
// its Service, untouched, on SNI.
AteGateway: {
	let Self = AteGateway

	// namespace holds the Gateway, its listener certificates, its policy and
	// the Deployment istiod creates for it. Not in ambient, as istio-ingress
	// is not: the gateway is its own proxy, and the router it dials is
	// outside the mesh.
	namespace: "substrate-shim"
	// name is the Gateway's. istiod names the Deployment and the ClusterIP
	// Service it creates <name>-istio.
	name:    "ate"
	service: "\(name)-istio"
	// serviceAccount is the one the Gateway's
	// gateway.istio.io/service-account annotation names and istiod creates.
	// The gateway's pod certificate from Substrate's pod identity signer is
	// issued for it, and spiffeID is the identity that certificate carries:
	// the substrate component puts it on the router's allowed list, from
	// here, so the two cannot disagree.
	serviceAccount: "ate-gateway"
	spiffeID:       "spiffe://\(Istio.trustDomain)/ns/\(namespace)/sa/\(serviceAccount)"
	// parameters is the ConfigMap the Gateway's infrastructure.parametersRef
	// names, whose deployment key adds the pod certificate to the gateway.
	parameters: "ate-gateway"

	// domain is the zone under the private domain every actor's hostname is
	// in, <actor>.<atespace>.<domain> (interview Q9): two labels, the
	// router's atespace slash actor. The private zone's *.<privateDomain>
	// already resolves it to the ingress Gateway's address.
	domain:   "ate.\(IngressGateway.domain)"
	wildcard: "*.\(domain)"

	// atespaces are the Substrate atespaces the shim serves, by name, each a
	// listener with a wildcard certificate *.<atespace>.<domain>, an
	// HTTPRoute to the router, and an AuthorizationPolicy rule admitting a
	// Keycloak ID token whose groups claim holds one of groups. Any other
	// host under domain has no listener, so the gateway refuses it.
	// Atespaces claimed through a project are added by
	// atespace-from-the-projectclaim as ListenerSets, which the Gateway
	// allows from its own namespace.
	atespaces: [NAME=string]: {
		name:     NAME
		hostname: "*.\(NAME).\(Self.domain)"
		// groups are the full group paths (Keycloak.groupsClaim) that may
		// reach the atespace's actors.
		groups: [...string]
	}
	atespaces: {
		// demo is the atespace README.md, Substrate, creates by hand, with
		// the echo and other actors.
		demo: groups: [Keycloak.groups.owners.path]
		// kagent's agents, in the atespace kagent creates for itself.
		(Kagent.atespace): groups: [Keycloak.groups.owners.path]
	}
}
