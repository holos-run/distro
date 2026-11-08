package holos

import "list"

// Kagent's names that need the ingress Gateway and Keycloak, which only
// component instances load: its public URL and its Keycloak client, and the
// claims it runs agents for on this cluster. The pins and the names Substrate
// reads are in kagent.cue at the platform root.
Kagent: {
	// host and url are the UI's one public name, behind oauth2-proxy, under
	// the ingress Gateway's wildcard certificate, so no Certificate of its
	// own.
	host: IngressGateway.hosts.kagent
	url:  "https://\(host)"

	// clientId is the confidential client oauth2-proxy logs in through,
	// which a holos-controller Client in kagent's namespace creates in the
	// realm. It is also the aud of the ID tokens oauth2-proxy accepts.
	// oidcSecret is the Secret there the controller delivers its secret
	// to.
	clientId: "kagent"
	oidcSecret: {
		name: "kagent-oidc-client"
		key:  "client-secret"
	}
	// callback is oauth2-proxy's redirect URL, the client's one redirect
	// URI.
	callback: "\(url)/oauth2/callback"

	// proxy is oauth2-proxy, the chart's subchart, which the ingress Gateway
	// routes every request for host to: its Service and port.
	proxy: {
		service: "\(Kagent.release)-oauth2-proxy"
		port:    4180
	}
	// ui is the UI's Service, nginx, which oauth2-proxy forwards to and
	// which proxies the API to the controller.
	ui: {
		service: "\(Kagent.release)-ui"
		port:    8080
	}

	// claims are the claims kagent runs agents for on this cluster, by name,
	// sorted: each claim with a binding here (clusterBindings,
	// collections.cue) of a product whose components name kagent. The
	// product's component renders the agents in the claim's namespace
	// (components/product-planboard), and the kagent component widens the
	// controller's RBAC and watch, and its login, to them. On a cluster with
	// no such binding it is empty, and kagent renders as it did before any.
	claims: list.SortStrings([for NAME, _ in {
		for B in clusterBindings[Cluster.name]
		for R in B.productRefs
		if list.Contains(products[R.name].components, "kagent") {(B.project): true}
	} {NAME}])

	// allowedGroups are the groups whose members may log in to kagent, as
	// full paths, the form the ID token's groups claim carries
	// (#ProjectRoleGroupPath): the platform's owners, and the owner and
	// editor groups of each of claims, who drive their claim's agent. A
	// viewer of a claim and a user of the realm in no group are refused at
	// the login. Only claims with an agent here: an owner of any other claim
	// would reach kagent's API and no agent of theirs. kagent has no
	// authorizer of its own, so whoever is admitted may use every agent in
	// every watched namespace (README.md, kagent).
	allowedGroups: list.SortStrings([
		Keycloak.groups.owners.path,
		for C in claims for ROLE in ["owner", "editor"] {
			(#ProjectRoleGroupPath & {project: C, role: ROLE}).claim
		},
	])
}
