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

	// realm is the platform's realm, holos, which the keycloak-realm
	// component imports and holos-controller reconciles, and issuer is the
	// iss every token from it carries. The master realm holds the bootstrap
	// admin alone.
	realm:  "holos"
	issuer: "\(url)/realms/\(realm)"

	// groupsClaim is the claim the realm's groups client scope writes each
	// user's groups into, as full paths with a leading slash
	// (/platform/owners), in every client's tokens (interview Q6). A binding
	// to a group, an Argo CD policy line or a Kubernetes subject, names the
	// full path.
	groupsClaim: "groups"

	// clients are the realm's client IDs that other components name: the
	// realm import creates each of them.
	clients: {
		// kubectl is the public client a person logs in to kubectl through,
		// with the device grant or kubelogin's PKCE, and the audience of
		// its tokens.
		kubectl: "kubectl"
		// argocd is Argo CD's public PKCE client (Q51).
		argocd: "argocd"
		// controller is holos-controller's confidential service-account
		// client, which it calls the admin API as.
		controller: "svc-holos-controller"
	}
}

// HolosController names holos-controller, which reconciles the realm's groups,
// memberships, users and clients from keycloak.holos.run resources: the
// holos-controller component installs it and keycloak-realm writes its
// Instance and credential.
HolosController: {
	// version is the aavis-ops release tag holos-controller-v<version>,
	// whose CRDs and manifests the holos-controller component vendors.
	version: "0.22.0"
	// image is the release's image, the tag kept for the reader and the
	// index digest the tag pointed to when vendored.
	image: "ghcr.io/holos-run/holos-controller:holos-controller-v\(version)@sha256:117ecfdd80391b77a31a92be16051cda586a2e3d4dcb353ce0bdeff5229ff175"

	// namespace holds the manager. It reads every credential Secret from
	// here, by the downward API's POD_NAMESPACE, whatever namespace the
	// resource naming the Secret is in.
	namespace: "holos-controller"

	// credentials is the Secret the manager calls Keycloak's admin API
	// with, the Instance's credentialsSecretRef default, with keys clientId
	// and clientSecret.
	credentials: "holos-controller-keycloak-creds"

	// instance is the Instance every keycloak.holos.run resource names,
	// in Keycloak's namespace, for the realm.
	instance: {
		name:      Keycloak.realm
		namespace: Keycloak.namespace
	}
}
