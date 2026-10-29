package holos

// HolosAuthenticator names holos-authenticator, which the holos-authenticator
// component installs in front of the Kubernetes API server at
// https://k8s.<domain> (overview §4): an Envoy external authorization server
// that verifies a person's Keycloak ID token and answers with the headers that
// make the request an impersonation of them, so Kubernetes RBAC does the rest.
// It runs behind a Gateway of its own (gateway, below), reached through the
// ingress Gateway's k8s listener, as the Substrate shim is (interview Q60).
// istiod reads provider for its mesh configuration, and ingress-gateway reads
// host and namespace for the listener.
HolosAuthenticator: {
	let Self = HolosAuthenticator

	// version is the aavis-ops release, and image its image, the tag kept
	// for the reader and the index digest the tag pointed to. The tag
	// v<version> is the item's; aavis-ops also publishes
	// holos-authenticator-v<version>, a different digest built from the same
	// code.
	version: "0.21.0"
	image:   "ghcr.io/holos-run/holos-authenticator:v\(version)@sha256:c5a1838d65e5fadaa48a370056cdc963ba8abe6a5bc19936bc7ab2294590560f"

	// namespace holds the manager, its Backend and its ServiceAccounts, and
	// the Gateway and the Deployment istiod creates for it. It is in the
	// mesh: ztunnel enforces who may call the manager's gRPC port. The
	// gateway's pods opt out of ambient by themselves, as every gateway
	// istiod deploys does (istio.io/dataplane-mode: none).
	namespace: "holos-authenticator"
	// name is the manager's Deployment, ServiceAccount and Service, and the
	// extension provider's name in istiod's mesh configuration, which the
	// CUSTOM AuthorizationPolicy names.
	name: "holos-authenticator"
	// grpcPort is the manager's plaintext ext_authz gRPC port, its
	// --grpc-bind-address default.
	grpcPort: 9000

	// provider is the extension provider istiod's mesh configuration lists
	// (components/istiod): ext_authz over gRPC to the manager's Service.
	provider: {
		name:    Self.name
		service: "\(Self.name).\(Self.namespace).svc.\(Cluster.network.dnsDomain)"
		port:    grpcPort
	}

	// impersonator is the ServiceAccount whose token the manager mints with
	// the TokenRequest API and puts in the forwarded request's
	// Authorization header, the Backend's serviceAccountRef default. It may
	// impersonate users and groups by name, and nothing else.
	impersonator: "\(name)-impersonator"

	// host is the API server's public name, the Backend's spec.host, matched
	// exactly against :authority, and the gateway's listener hostname. The
	// private zone's *.<domain> resolves it to the ingress Gateway.
	host: "k8s.\(IngressGateway.domain)"

	// gateway is the Gateway that terminates TLS for host and holds the
	// ext_authz policy, the Lua and the TLS to the API server. Like the
	// Substrate shim's, it has no address: the ingress Gateway's k8s
	// listener passes the connection through to its ClusterIP Service on
	// SNI, so none of its policy runs on the ingress Gateway.
	gateway: {
		// name is the Gateway's. istiod names the Deployment and the
		// ClusterIP Service it creates <name>-istio.
		name:    "k8s"
		service: "\(name)-istio"
		// serviceAccount is the one the Gateway's
		// gateway.istio.io/service-account annotation names and istiod
		// creates, and principal its mesh identity, the only one the
		// manager's gRPC port admits.
		serviceAccount: "k8s-gateway"
		principal:      "\(Istio.trustDomain)/ns/\(Self.namespace)/sa/\(serviceAccount)"
		// parameters is the ConfigMap the Gateway's
		// infrastructure.parametersRef names.
		parameters: "k8s-gateway"
	}

	// usernamePrefix is put in front of a token's preferred_username to make
	// the impersonated user's name (interview Q62): jeff is oidc:jeff, and a
	// realm user named system:admin would be oidc:system:admin, which holds
	// nothing.
	usernamePrefix: "oidc:"
	usernameClaim:  "preferred_username"

	// users are the realm's usernames the impersonator may impersonate, so
	// the people who may use kubectl at all: a token for anyone else is
	// verified, and the API server refuses the impersonation with 403. They
	// are the resourceNames of the impersonator's users rule, each with
	// usernamePrefix. Each is in Keycloak.users; the realm import creates
	// only jeff, and anyone else is created in the realm by hand.
	users: [...string]
	users: [Keycloak.users.jeff.username]

	// groups are the groups, by the full path the groups claim carries
	// (Keycloak.groupsClaim), that the manager forwards and the impersonator
	// may impersonate: one list, the Backend's groupMapping.anyOf and the
	// resourceNames of the impersonator's groups rule, so the two cannot
	// drift apart. A group in a token but not here is dropped, and logged,
	// rather than refused: the API server refuses a whole request whose
	// groups include one the impersonator may not impersonate. Granting a
	// group something is a binding of its own, such as the cluster-admin
	// binding of owners in the holos-authenticator component. The
	// ProjectClaim collection (project-collection) adds each project's owner
	// group here, and binds it in the project's namespace.
	groups: [...string]
	groups: [Keycloak.groups.owners.path]
}
