package holos

// Quay names the platform's registry (interview Q13, Q56, Q57 and Q59):
// the release the quay component runs, its namespace and URL, its Keycloak
// client, its superusers and the organizations holos-controller makes in it. Anything
// that pushes to, pulls from or reconciles Quay reads it here, as
// cmd/quay-bootstrap's defaults do by hand.
Quay: {
	// version is Quay's release, and image the projectquay image, the tag
	// kept for the reader and the index digest the tag pointed to. The tag
	// has no leading v. 3.18 is for version-bump-before-the-day to weigh.
	version: "3.17.6"
	image:   "quay.io/projectquay/quay:\(version)@sha256:e1f7407f90b169247c9a0714ed2cfdd61b24292ed708a12385fd89a762f004a2"

	// namespace holds Quay, its Redis and its database, in the mesh.
	namespace: "quay"
	name:      "quay"
	// port is Quay's plain HTTP port, behind the ingress gateway, which
	// terminates TLS as it does for Keycloak.
	port: 8080

	// host and url are Quay's one public name, its SERVER_HOSTNAME, which
	// pods, the workers' kubelets and the laptop resolve alike, to the
	// gateway. Every image is named host/<organization>/<repository>.
	host: IngressGateway.hosts.quay
	url:  "https://\(host)"

	// clientId is the confidential client Quay logs in through, which a
	// holos-controller Client in Quay's namespace creates in the realm, and
	// oidcSecret the Secret there the controller delivers its secret to.
	clientId: "quay"
	oidcSecret: {
		name: "quay-oidc"
		key:  "client-secret"
	}

	// controller is the realm user Quay's superuser credential acts as: the
	// keycloak-realm component imports it, with a generated password in
	// Secret <username> in keycloak, and cmd/quay-bootstrap logs in as it to
	// mint holos-controller's OAuth token (Q57).
	controller: {
		username:  "svc-quay-controller"
		email:     "\(username)@\(IngressGateway.domain)"
		firstName: "Quay"
		lastName:  "Controller"
	}

	// superUsers are Quay's SUPER_USERS, matched on preferred_username: the
	// controller's user, and jeff, the platform's owner.
	superUsers: [controller.username, "jeff"]

	// organizations are the holos-controller Organizations in Quay's
	// namespace. demo holds the actor's public repository (Q13); the
	// Substrate and kagent images are on ghcr.io, not here (docs/forks.md).
	// Each syncs one team, platformowners, from the platform owners' group,
	// as admin.
	organizations: [NAME=string]: {name: NAME}
	organizations: demo: _

	// ownersTeam is the synced team every organization has. It is not
	// owners: Quay makes a team owners in every new organization, with its
	// creator in it, and holos-controller reports a team it did not make as
	// a conflict, so the Organization would never be Ready. Adopting owners
	// instead would sync its members from OIDC and drop the creator,
	// svc-quay-controller. Quay team names take no dash.
	ownersTeam: "platformowners"

	// credentials is the platform secret cmd/quay-bootstrap writes the
	// controller's token to, in holos-prj-platform, and the copy in
	// holos-controller's namespace its Quay reconcilers read by default.
	credentials: {
		platform:   "quay-controller-token"
		controller: "holos-controller-quay-creds"
	}
}
