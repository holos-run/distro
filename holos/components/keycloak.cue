package holos

// Keycloak names the platform's one identity provider (interview Q11): the
// release the keycloak-operator component installs, the namespace it and the
// keycloak component share, and the issuer every token carries. Anything that
// trusts or calls Keycloak, such as the platform controller or an OIDC
// client, reads it here.
Keycloak: {
	// version is the Keycloak Operator's release and the server's: the
	// operator runs quay.io/keycloak/keycloak at its own version, so the two
	// move together. 26.8.2 (2026-11-05) is the latest release.
	version: "26.8.2"

	// images are the operator's and the server's, by index digest. The
	// release pins both by tag; the keycloak-operator component sets these
	// over them, so the Keycloak resource names no image and the two still
	// move together.
	images: {
		operator: "quay.io/keycloak/keycloak-operator:\(version)@sha256:3faeeb34df8da88bb0cacb0a8012f2f517d1b2f3a19e1f8f6884a3c1c67ce7ee"
		server:   "quay.io/keycloak/keycloak:\(version)@sha256:3879c623248408de29a5303178b5816c77e8dfef3890c361f8c0bbeaa979ba3b"
	}

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

	// url is the server's one public URL, keycloak.<ingressDomain> at the
	// ingress gateway (IngressGateway.hosts, the Cluster_Qualified_Hostnames
	// planning project), which pods and the laptop resolve alike. A realm's
	// issuer is <url>/realms/<realm>.
	url: "https://\(IngressGateway.hosts.keycloak)"

	// realm is the platform's realm, default, which the keycloak-realm
	// component imports and the platform controller reconciles, and issuer
	// is the iss every token from it carries. It is not part of Brand:
	// every distribution names its realm default, and the issuer's host
	// tells them apart, so a token's iss differs only by domain from one
	// vendor's distribution to another's (ADR 0002). The master realm holds
	// the bootstrap admin alone.
	realm:  "default"
	issuer: "\(url)/realms/\(realm)"

	// groupsClaim is the claim the realm's groups client scope writes each
	// user's groups into, as full paths with a leading slash
	// (/platform/owners), in every client's tokens (interview Q6). A binding
	// to a group, an Argo CD policy line or a Kubernetes subject, names the
	// full path.
	groupsClaim: "groups"

	// groups are the realm's groups that other components grant something
	// to, by the full path the groups claim carries.
	groups: {
		// owners is the platform's owner group: Argo CD admins, and the
		// group the Substrate shim admits to the demo and kagent atespaces
		// (AteGateway). keycloak-realm makes it, named name in its
		// namespace, and puts jeff in it.
		owners: {
			name: "platform-owners"
			path: "/platform/owners"
		}
	}

	// users are the realm's people whom other components name, by username,
	// and PlatformAuthenticator.users lists those who may use kubectl.
	// keycloak-realm's import reads only users.jeff, with his generated
	// password; anyone else is created in the realm by hand.
	users: [USERNAME=string]: {
		username:  USERNAME
		email:     string
		firstName: string
		lastName:  string
	}
	users: {
		// jeff is the milestone's user (interview Q6), a member of
		// groups.owners.
		jeff: {
			email:     "jeff@bank.internal"
			firstName: "Jeff"
			lastName:  "McCune"
		}
	}

	// clients are the realm's client IDs that other components name: the
	// realm import creates each of them.
	clients: {
		// kubectl is the public client a person logs in to kubectl through,
		// with the device grant or kubelogin's PKCE, and the audience of
		// its tokens.
		kubectl: "kubectl"
		// argocd is Argo CD's public PKCE client (Q51).
		argocd: "argocd"
		// controller is the platform controller's confidential
		// service-account client, which it calls the admin API as.
		controller: "svc-\(Brand.slug)-controller"
	}
}

// PlatformController names the platform controller, the software
// holos-controller, which reconciles the realm's groups, memberships, users
// and clients from keycloak.holos.run resources: the holos-controller
// component installs it, as the Argo CD Application <slug>-controller, and
// keycloak-realm writes its Instance and credential. The identifier is
// brand-neutral, as a CUE identifier cannot follow Brand; the names it holds
// are built from Brand.slug.
PlatformController: {
	// version is the aavis-ops release tag holos-controller-v<version>,
	// whose CRDs and manifests the holos-controller component vendors.
	version: "0.22.0"
	// image is the release's image, the tag kept for the reader and the
	// index digest the tag pointed to when vendored.
	image: "ghcr.io/holos-run/holos-controller:holos-controller-v\(version)@sha256:117ecfdd80391b77a31a92be16051cda586a2e3d4dcb353ce0bdeff5229ff175"

	// name is the distribution's name for it, <slug>-controller: its
	// namespace, its Argo CD Application (registry.cue, which builds the
	// same name, since the platform does not load this file), and the base
	// of its Deployment's, ServiceAccount's and RBAC's names
	// (components/holos-controller).
	name: "\(Brand.slug)-controller"

	// namespace holds the manager. It reads every credential Secret from
	// here, by the downward API's POD_NAMESPACE, whatever namespace the
	// resource naming the Secret is in.
	namespace: name

	// credentials is the Secret the manager calls Keycloak's admin API
	// with, the Instance's credentialsSecretRef, with keys clientId and
	// clientSecret.
	credentials: "\(name)-keycloak-creds"

	// instance is the Instance every keycloak.holos.run resource names,
	// in Keycloak's namespace, for the realm.
	instance: {
		name:      Keycloak.realm
		namespace: Keycloak.namespace
	}
}
