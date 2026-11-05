package holos

import (
	"list"

	proj "go.holos.run/distro/holos/projects"
)

// collections.cue binds the ProjectClaim collection (projects/) into the root
// of package holos. CUE loads only root-level holos/*.cue files as ancestors
// of the platform and of each component, so the collection, which is a
// package of its own in a subdirectory, is visible to them only through this
// import, as aavis-ops binds its collections. The registry (registry.cue)
// adds a component per claim from here, clusterProjects, below, is which
// claims each cluster takes, the project component (components/project)
// renders each on those clusters, and holos-authenticator's allowlist
// (components/holos-authenticator.cue) reads the owners' groups and usernames
// from the definitions below.
//
// Only what the platform needs is here: the platform instance loads the
// root files and platform/, not components/*.cue, so Keycloak, Quay and the
// other definitions there are out of its reach. The checks that need them,
// which names a claim may not take, are Projects' (components/project.cue),
// which every project component's render evaluates.

// projects is the collection, keyed by project name.
projects: proj.projects

// #ClusterSelected is whether selector selects a cluster with labels, by
// Kubernetes' rules: every requirement holds, so {} selects every cluster;
// NotIn holds of a cluster without the key, as DoesNotExist does.
#ClusterSelected: {
	selector: proj.#ClusterSelector
	labels:   proj.#Labels

	let Keys = [for K, _ in labels {K}]
	let Pairs = [for K, V in labels {"\(K)=\(V)"}]

	// unmet are the requirements that do not hold, by key.
	unmet: [
		for K, V in selector.matchLabels
		if !list.Contains(Pairs, "\(K)=\(V)") {K},

		for R in selector.matchExpressions
		let Found = len([
			if R.values != _|_ for V in R.values
			if list.Contains(Pairs, "\(R.key)=\(V)") {V},
		]) > 0
		let Holds = {
			In:           Found
			NotIn:        !Found
			Exists:       list.Contains(Keys, R.key)
			DoesNotExist: !list.Contains(Keys, R.key)
		}
		if !Holds[R.operator] {R.key},
	]
	selected: len(unmet) == 0
}

// clusterProjects are the claims each cluster takes, by cluster name and then
// project name: the ones whose clusterSelector selects it. Whatever reads the
// collection for a cluster reads this: clusterRegistry (registry.cue), the
// owner definitions below and so holos-authenticator's allowlist, Projects
// (components/project.cue) and AteGateway.claimed. So a claim leaves no trace
// on a cluster it does not select, and a username is per cluster, as a
// Keycloak is (Second_Cluster interview Q2).
//
// It is a map in the root, not a filter on Cluster, because the platform reads
// it through clusterRegistry (clusterRegistry says why). A claim without a
// selector is in no cluster's map, and claimClusters refuses it.
clusterProjects: {
	for CLUSTER, C in clusters {
		(CLUSTER): {
			for NAME, P in projects
			if P.clusterSelector != _|_
			if (#ClusterSelected & {selector: P.clusterSelector, labels: C.metadata.labels}).selected {
				(NAME): P
			}
		}
	}
}

// claimClusters are the clusters each claim lands on, by project name, and
// there is at least one: a claim on no cluster, for want of a selector or
// because its selector selects none, fails cue vet here, with the claim's name
// in the error. holos render platform does not report it: it drops the claim
// and exits 0. A selector left incomplete, such as an expression with no
// operator, leaves all of clusterProjects incomplete, so every claim fails here
// with the same error and the cause goes unnamed.
claimClusters: {
	for NAME, _ in projects {
		(NAME): [for CLUSTER, P in clusterProjects if P[NAME] != _|_ {CLUSTER}] & [_, ...]
	}
}

// #ProjectRoles are the roles every project has a Keycloak group and a Quay
// team for, in that order. Only owner is bound to anything in Kubernetes.
#ProjectRoles: ["owner", "editor", "viewer"]

// #ProjectRoleGroupPath is the one spelling of a project role's Keycloak
// group, which three places must agree on character for character: the
// Group resource that makes it in the realm (components/project), the
// Group subject of the owners' RoleBinding, which the API server compares
// an impersonated group against, and holos-authenticator's allowlist, which
// drops a group in a token that is not on it. Disagreement fails silently:
// a RoleBinding whose subject matches no group grants nothing and reports
// nothing, and an allowlist without the group drops it with an Info log.
// That is the bug holos-substrate's collection has and aavis-ops fixed.
//
// The realm's groups client scope writes full paths, with a leading slash,
// into the groups claim (Keycloak.groupsClaim), so a group is called
// /projects/<project>/roles/<role> once it reaches a token. Hence two
// fields: path, the Group resource's spec.path, written without the slash,
// as holos-controller's API documents it; and claim, the form every
// consumer that compares against a token uses. The platform's own group
// follows the same rule: Keycloak.groups.owners.path is its claim,
// /platform/owners, which a binding or an allowlist names as it is, and
// keycloak-realm trims the slash for its Group. Reach for claim.
#ProjectRoleGroupPath: {
	project: string
	role:    string

	path:  "projects/\(project)/roles/\(role)"
	claim: "/\(path)"
}

// #ProjectOwnerGroupClaims are the claims of the owner group of every project
// a cluster takes, by cluster name, sorted, which holos-authenticator adds to
// the groups it forwards and may impersonate. Only the owner group: nothing
// in the cluster binds the editor or viewer group, and an allowlist entry for
// a group nothing binds would only widen what the impersonator may assert.
// Add a role here when something binds it.
#ProjectOwnerGroupClaims: {
	for CLUSTER, PROJECTS in clusterProjects {
		(CLUSTER): list.SortStrings([
			for NAME, _ in PROJECTS {
				(#ProjectRoleGroupPath & {project: NAME, role: "owner"}).claim
			},
		])
	}
}

// #ProjectOwnerUsernames are the Keycloak usernames of the owners of every
// project a cluster takes, by cluster name, sorted, each once however many
// projects it owns, which holos-authenticator adds to the users it may
// impersonate. Without it an owner's token would be verified and the
// impersonation refused.
#ProjectOwnerUsernames: {
	for CLUSTER, PROJECTS in clusterProjects {
		(CLUSTER): list.SortStrings([
			for USERNAME, _ in {
				for P in PROJECTS for O in P.owners {(O.username): true}
			} {USERNAME},
		])
	}
}

// #ProjectRegistrations are the registry's entries for the collection, one
// per claim, which registry.cue puts after the components they need. Each is
// the component project-<name>, rendered from the one directory
// components/project with the parameter project, so a claim adds a
// component and an Argo CD Application of its own: between Applications
// that already exist a broken claim holds back only its own (interview Q66),
// though a root sync, which walks the waves, waits on it as on any component.
// They are in name order,
// whatever order CUE loads the claims' files in, so a sync wave, which is
// the index in the cluster's own list (clusterRegistry, registry.cue), moves
// only when an entry ahead of it comes or goes: a claim that selects the
// cluster, or a component the cluster starts or stops naming. Each is
// optional, at the top of the stack, but no cluster names one: a claim names
// its clusters instead, and this list is every claim, whichever clusters it
// selects (#OptionalComponents, registry.cue). It reads projects, not
// clusterProjects, since #Cluster.components reads it.
#ProjectRegistrations: [
	for NAME in list.SortStrings([for NAME, _ in projects {NAME}]) {
		name:      "project-\(NAME)"
		component: "project"
		priority:  "optional"
		parameters: project: NAME
	},
]
