package holos

// Keycloak names the platform's one identity provider (interview Q11): the
// release the keycloak-operator component installs, the namespace it and the
// keycloak component share, and the issuer every token carries. Anything that
// trusts or calls Keycloak, such as holos-controller or an OIDC client, reads
// it here.
Keycloak: {
	// version is the Keycloak Operator's release and the server's: the
	// operator runs quay.io/keycloak/keycloak at its own version, so the two
	// move together. 26.8.1 (2026-10-13) is the latest release.
	version: "26.8.1"

	// namespace holds the operator, the server and its database. The
	// keycloak-operator component renders it, in the mesh, since it comes
	// first in the registry.
	namespace: "keycloak"

	// name is the Keycloak resource's. The operator names the server's
	// StatefulSet after it and its Service <name>-service.
	name:    "keycloak"
	service: "\(name)-service"
	// port is the server's plain HTTP port, behind the ingress gateway.
	port: 8080

	// url is the server's one public URL, at the ingress gateway, which pods
	// and the laptop resolve alike (interview Q40). A realm's issuer is
	// <url>/realms/<realm>.
	url: "https://\(IngressGateway.hosts.keycloak)"
}
