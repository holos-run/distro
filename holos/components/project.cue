package holos

// Projects holds what the project component (components/project) renders
// every ProjectClaim with, beside the collection itself (collections.cue):
// the Quay teams a project's groups sync to, the realm's people a claim
// may name, and the names a claim may not take. It is here rather than in
// collections.cue because it reads Keycloak, Quay and the other definitions
// in components/, which the platform instance does not load. Every project
// component's render evaluates it, so a claim that breaks one of its checks
// fails `holos render platform`.
Projects: {
	// teams are the Quay teams of a project's organization, by role, each
	// synced from that role's group (#ProjectRoleGroupPath). Quay team names
	// take no dash, and none may be owners, which Quay makes in every new
	// organization with its creator in it (Quay.ownersTeam); so each is the
	// role's plural after project, as the platform owners' team is
	// platformowners.
	teams: {
		owner: {
			name: "projectowners"
			role: "admin"
		}
		editor: {
			name:                 "projecteditors"
			role:                 "creator"
			repositoryPermission: "write"
		}
		viewer: {
			name:                 "projectviewers"
			role:                 "member"
			repositoryPermission: "read"
		}
	}

	// people are the realm's users a claim may name, by username: the
	// platform's people, whom keycloak-realm's import or a person by hand
	// creates (Keycloak.users, and Quay's controller user), and every
	// project's owners. A username is one person: two emails for one
	// username conflict here, and fail the render of each project that
	// names it, rather than leave holos-controller to report a Keycloak
	// conflict, or holos-authenticator to impersonate the wrong person.
	people: [USERNAME=string]: {
		username: USERNAME
		email:    string
		// platform is whether they are one of the platform's people, for
		// whom a claim renders no User: Keycloak already has them, and a
		// second resource for the same user would only contend for it.
		platform: *false | true
		// service is whether they are a platform service user, not a
		// person, whom no claim may name as an owner (#Person).
		service: *false | true
	}
	people: {
		for U in Keycloak.users {
			(U.username): {email: U.email, platform: true}
		}
		(Quay.controller.username): {email: Quay.controller.email, platform: true, service: true}
		for P in projects for O in P.owners {
			(O.username): email: O.email
		}
	}

	// usernames are the same people by email: one email with two usernames
	// conflicts here, as an owner who is one of the platform's people
	// under another username would, since Keycloak finds a user by email
	// and the token would carry the other username.
	usernames: {
		for U, P in people {(P.email): U}
	}

	// #Person is a username an owner may have: anyone's but a platform
	// service user's (people.<username>.service), such as Quay's controller
	// user, a Quay superuser, or a Keycloak client's service account,
	// service-account-<client>. An owner's username joins
	// holos-authenticator's allowlist and its group gets admin in the
	// project's namespace, so naming one would let a claim make the
	// platform's own credential a kubectl user.
	#Person: !~"^service-account-" & and([for U, P in people if P.service {!=U}])

	// reserved are the names no project may take. A project's name is its
	// namespace, its AppProject and Application in argocd and its Quay
	// organization, and a claim named after one the platform uses would
	// unify with it rather than fail: it would make its owners admins of
	// that namespace. CUE drops a map key whose value is bottom rather than
	// failing, so nothing short of an explicit check refuses the name, and
	// #Unreserved is that check, which the project component applies to its
	// name. Beside these, #Unreserved refuses the prefixes kube- and holos-,
	// which Kubernetes and the Secrets Manager's organizations and projects
	// (SecretsManager.platform) use, and project-, which would let a
	// project's Application collide with another project's component.
	reserved: {
		// Every component's: most components' namespace is their name, and
		// each is an Application in argocd, as a project's is.
		for C in registry {(C.name): true}

		// The platform's namespaces that are not a component's name, from
		// their definitions where one names them, and the rest, which a
		// component names alone, by hand. A component that adds a namespace
		// adds it here.
		for NS in [
			ArgoCD.namespace,
			Istio.namespace,
			IngressGateway.namespace,
			Keycloak.namespace,
			HolosController.namespace,
			HolosAuthenticator.namespace,
			SecretsManager.namespace,
			Quay.namespace,
			Substrate.namespace,
			Substrate.workerPool.namespace,
			AteGateway.namespace,
			Kagent.namespace,
			for W in webhookServices {W.namespace},
			"cilium-secrets",
			"cnpg-system",
			"local-path-storage",
			"podcertificate-controller-system",
			"default",
		] {(NS): true}

		// Argo CD's AppProjects: the platform's, and default, which Argo CD
		// makes itself.
		(ArgoCD.project): true

		// Quay's organizations and users share one namespace, so a project's
		// organization may take neither the name of the platform's own
		// organizations nor of anyone who logs in to Quay: the platform's
		// people and every project's owners.
		for O in Quay.organizations {(O.name): true}
		for U in Quay.superUsers {(U): true}
		for U, _ in people {(U): true}

		// The Substrate shim's atespaces, which
		// atespace-from-the-projectclaim will make from projects.
		for A in AteGateway.atespaces {(A.name): true}
	}

	#Unreserved: !~"^(kube|holos|project)-" & and([for NAME, _ in reserved {!=NAME}])
}
