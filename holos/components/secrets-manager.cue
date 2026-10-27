package holos

// SecretsManager names the Holos Secrets Manager (interview Q18): the release
// the secrets-manager component runs, its namespace and URL, its Keycloak
// client, and the management namespaces it edits, holos-org-platform and
// holos-prj-platform, the second of which every per-namespace store
// (#ScopedSecretStore) reads from by default.
SecretsManager: {
	// version is the holos-run/secrets-manager release, and image its
	// distroless nonroot image, the tag kept for the reader and the index
	// digest the tag pointed to. v0.19.0's SPA sends the OAuth access token,
	// which the server checks as an ID token whose aud must be the client
	// ID; Keycloak's access tokens carry no aud, so every call after login
	// is refused (Q53). The release that sends the ID token instead (ADR
	// 0002) replaces this one: its version and digest, here, are the whole
	// change.
	version: "0.19.0"
	image:   "ghcr.io/holos-run/secrets-manager:v\(version)@sha256:806f23abd285514dfc2d3effa37992d86d188c6a7374e14e67914a9db87634cf"

	// namespace holds the server. It is in the mesh, like keycloak's: the
	// gateway reaches it over HBONE, and it calls Keycloak at its public
	// URL, through the gateway, as any pod does.
	namespace: "secrets-manager"
	name:      "secrets-manager"
	// port is the server's plain HTTP port, behind the ingress gateway, which
	// terminates TLS as it does for Keycloak. /metrics is served on it too,
	// unauthenticated, so the route leaves it out (components/secrets-manager).
	port: 8080

	// url is the server's one public URL, its --origin, the base of its
	// OIDC redirect and of the SPA's post-logout redirect.
	url: "https://\(IngressGateway.hosts.secrets)"

	// clientId is the public client the SPA logs in through, which a
	// holos-controller Client in the server's namespace creates in the
	// realm, unlike Keycloak.clients, which the realm import creates. It is
	// also the aud the server requires of every ID token.
	clientId: "secrets-manager"

	// owners is the group, by the full path the groups claim carries, that
	// alone may create organizations (Q55) and that owns the platform
	// organization and project. keycloak-realm makes it.
	owners: "/platform/owners"

	// secretsRole is the ClusterRole holding the server's secrets verbs,
	// which a RoleBinding in each project namespace git renders grants it
	// there (components/management-namespaces).
	secretsRole: "\(name)-secrets"

	// platform is the management organization and project (Q54), under the
	// server's default prefixes, holos- with org- or prj-: holos-org-platform
	// and holos-prj-platform. The SPA lists projects only within an
	// organization, so the project carries the organization's label and the
	// organization is a namespace of its own. The server manages only
	// namespaces carrying its labels, so git renders both with them, with a
	// grant for owners, in the management-namespaces component. Platform
	// secrets are made in the project through the Secrets Manager and copied
	// out by per-namespace stores.
	platform: {
		organization: "platform"
		orgNamespace: "holos-org-\(organization)"
		project:      "platform"
		namespace:    "holos-prj-\(project)"
	}
}
