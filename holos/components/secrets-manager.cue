package holos

// SecretsManager names the Holos Secrets Manager (interview Q18): the release
// the secrets-manager component runs, its namespace and URL, its Keycloak
// client, and the management namespaces it edits, holos-org-platform and
// holos-prj-platform, the second of which every per-namespace store
// (#ScopedSecretStore) reads from by default.
SecretsManager: {
	// version is the holos-run/secrets-manager release, and image its
	// distroless nonroot image, the tag kept for the reader and the index
	// digest the tag pointed to. v0.20.0's SPA sends the OIDC ID token as the
	// bearer (ADR 0002). v0.19.0 sent the OAuth access token, which the
	// server checks as an ID token whose aud must be the client ID;
	// Keycloak's access tokens carry no aud, so every call after login was
	// refused (Q53).
	version: "0.20.0"
	image:   "ghcr.io/holos-run/secrets-manager:v\(version)@sha256:e33d995aa4f21d4861b5e7715e9674f8bf305278cf359ad32f9ea55d38272d5c"

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
	owners: Keycloak.groups.owners.path

	// secretsRole is the ClusterRole holding the server's secrets verbs,
	// which a RoleBinding in each project namespace git renders grants it
	// there: holos-prj-platform's alone, in management-namespaces. A
	// ProjectClaim renders no project here and so no RoleBinding (interview
	// Q64); that is the tech debt item
	// secrets-manager-project-for-each-projectclaim.
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
