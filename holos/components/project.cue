package holos

// Projects holds what the project component (components/project) renders
// every ProjectClaim with, beside the collection itself (collections.cue):
// the Quay teams a project's groups sync to, the realm's people a claim
// may name, and the names a claim may not take. It is here rather than in
// collections.cue because it reads Keycloak, Quay and the other definitions
// in components/, which the platform instance does not load. Every project
// component's render evaluates it, so a claim that breaks one of its checks
// fails `holos render platform`. It is the cluster's: each cluster has a
// realm and a Quay of its own, so it reads the claims the cluster takes
// (clusterProjects, collections.cue), and a claim's mistake fails only the
// renders of the clusters it selects, though one of those fails holos render
// platform as a whole. cue vet evaluates this for the default cluster,
// treasury, or the one -t clusterName names, and with no project named, so it
// reports a conflict over a person there; a check on one claim, such as
// Projects.#Person, only the render reports. The people collection
// (clusterPeople) takes part as members do, and keycloak-realm reads collected,
// below, so its checks fail the render of every cluster the person selects,
// whether or not a claim names them.
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
	// creates (Keycloak.users, and Quay's controller user), the owners, editors
	// and viewers of every project the cluster takes, and the people of the
	// collection the cluster has (clusterPeople). A username is one person on a
	// cluster, where one Keycloak holds it: two emails for one username conflict
	// here, and fail the render of each project on the cluster that names it,
	// rather than leave holos-controller to report a Keycloak conflict, or
	// holos-authenticator to impersonate the wrong person.
	people: [USERNAME=string]: {
		username: USERNAME
		email:    string
		// platform is whether they are one of the platform's people, for
		// whom a claim renders no User: Keycloak already has them, and a
		// second resource for the same user would only contend for it.
		platform: *false | true
		// service is whether they are a platform service user, not a
		// person, whom no claim may name as a member (#Person).
		service: *false | true
		// person is whether they are in the people collection on this
		// cluster, for whom a claim renders no User either: keycloak-realm
		// renders theirs, which a second resource would contend for.
		person: *false | true
	}
	people: {
		for U in Keycloak.users {
			(U.username): {email: U.email, platform: true}
		}
		(Quay.controller.username): {email: Quay.controller.email, platform: true, service: true}
		for P in clusterProjects[Cluster.name]
		for MEMBERS in [P.owners, P.editors, P.viewers]
		for O in MEMBERS {
			(O.username): email: O.email
		}
		for P in clusterPeople[Cluster.name] {
			(P.username): {email: P.email, person: true}
		}
	}

	// usernames are the same people by email: one email with two usernames
	// conflicts here, as a member who is one of the platform's people
	// under another username would, since Keycloak finds a user by email
	// and the token would carry the other username.
	usernames: {
		for U, P in people {(P.email): U}
	}

	// #Person is a username a project's member, or a person of the collection,
	// may have: anyone's but a platform service user's
	// (people.<username>.service), such as Quay's controller user, a Quay
	// superuser, or a Keycloak client's service account,
	// service-account-<client>. An owner's username joins
	// holos-authenticator's allowlist and its group gets admin in the
	// project's namespace, so naming one would let a claim make the
	// platform's own credential a kubectl user. An editor or a viewer gets
	// neither and is refused all the same: a service user is not a person, and
	// no claim has a reason to put the platform's credential in its groups.
	#Person: !~"^service-account-" & and([for U, P in people if P.service {!=U}])

	// collected are the people of the collection this cluster has, by email,
	// which keycloak-realm renders a User for. Each is checked as the project
	// component checks a member, the checks folded into username and email,
	// which that User always reads: a username that is someone else's, an
	// email someone else has under another username, or a service user's. Nor
	// may a person be one of the platform's people, however exactly they
	// match. Those are on every cluster and the import owns them, so the
	// collection's selector would mean nothing and its User would contend for
	// them, and a claim can name them without it. Nor may a person have the
	// name of one of Quay's organizations, on any cluster, since Quay's users
	// and organizations share a namespace and their first login there would
	// collide with it.
	collected: {
		for EMAIL, P in clusterPeople[Cluster.name] {
			(EMAIL): {
				let USERNAME = P.username & usernames[EMAIL] & #Person &
				and([for U, O in people if O.platform {!=U}]) &
				and([for NAME, _ in Quay.organizations {!=NAME}])
				username: USERNAME
				email:    EMAIL & people[USERNAME].email
			}
		}
	}

	// reserved are the names no project may take. A project's name is its
	// namespace, its AppProject and Application in argocd and its Quay
	// organization, and a claim named after one the platform uses would
	// unify with it rather than fail: it would make its owners admins of
	// that namespace. CUE drops a map key whose value is bottom rather than
	// failing, so nothing short of an explicit check refuses the name, and
	// #Unreserved is that check, which the project component applies to its
	// name. Beside these, #Unreserved refuses the prefixes kube- and
	// <slug>- (Brand.slug), which Kubernetes, the platform's controllers and
	// the Secrets Manager's organizations and projects
	// (SecretsManager.platform) use, and project-, which would let a
	// project's Application collide with another project's component.
	reserved: {
		// Every component's: most components' namespace is their name, and
		// each is an Application in argocd, as a project's is. The whole
		// registry, not a cluster's list (clusterRegistry), so a name is
		// reserved whether or not a cluster takes it.
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
			PlatformController.namespace,
			PlatformAuthenticator.namespace,
			SecretsManager.namespace,
			Quay.namespace,
			Substrate.namespace,
			Substrate.workerPool.namespace,
			AteGateway.namespace,
			Kagent.namespace,
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
		// people, the owners, editors and viewers of every project on the
		// cluster and the people of the collection it has. Only on that
		// cluster: a person is not reserved where they do not exist.
		for O in Quay.organizations {(O.name): true}
		for U in Quay.superUsers {(U): true}
		for U, _ in people {(U): true}

		// The atespaces the platform lists for the shim. A claim makes an
		// atespace of its own name (AteGateway.claimed), so one with the name
		// of a listed atespace would be handed that atespace and its actors,
		// and its listener would collide with the Gateway's.
		for A in AteGateway.atespaces {(A.name): true}

		// The shim's zone's label. A claim with a binding gets a zone of its
		// own on the ingress Gateway, *.<claim>.<ingressDomain>
		// (IngressGateway.#Claim), and one named ate would have the ate
		// listener's hostname, *.ate.<ingressDomain>, on the same port, an
		// HTTPS listener over the shim's passthrough. Istio keeps the
		// Gateway's own listener and marks the ListenerSet's Conflicted, so
		// the claim's zone would never be programmed and its board would have
		// no host.
		(AteGateway.label): true
	}

	#Unreserved: !~"^(kube|\(Brand.slug)|project)-" & and([for NAME, _ in reserved {!=NAME}])
}

// #ProjectDirectory is the one spelling of a project's own directory in deploy/,
// which its Application syncs: the project component's second artifact
// (components/project), and a product's project bucket (#ProductComponent,
// components/product.cue) renders into the same directory. It is outside
// deploy/clusters/<cluster>/components, where only the platform's Applications
// look, and inside deploy/clusters, so a render from a clean deploy/clusters
// writes it again.
#ProjectDirectory: {
	project: string
	path:    "clusters/\(Cluster.name)/projects/\(project)"
}
