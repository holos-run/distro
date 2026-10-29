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
// adds a component per claim from here, the project component
// (components/project) renders each, and holos-authenticator's allowlist
// (components/holos-authenticator.cue) reads the owners' groups and
// usernames from the definitions below.
//
// Only what the platform needs is here: the platform instance loads the
// root files and platform/, not components/*.cue, so Keycloak, Quay and the
// other definitions there are out of its reach. The checks that need them,
// which names a claim may not take, are Projects' (components/project.cue),
// which every project component's render evaluates.

// projects is the collection, keyed by project name.
projects: proj.projects

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

// #ProjectOwnerGroupClaims are the claims of every project's owner group,
// sorted, which holos-authenticator adds to the groups it forwards and may
// impersonate. Only the owner group: nothing in the cluster binds the
// editor or viewer group, and an allowlist entry for a group nothing binds
// would only widen what the impersonator may assert. Add a role here when
// something binds it.
#ProjectOwnerGroupClaims: list.SortStrings([
	for NAME, _ in projects {
		(#ProjectRoleGroupPath & {project: NAME, role: "owner"}).claim
	},
])

// #ProjectOwnerUsernames are the Keycloak usernames of every project's
// owners, sorted, each once however many projects it owns, which
// holos-authenticator adds to the users it may impersonate. Without it an
// owner's token would be verified and the impersonation refused.
#ProjectOwnerUsernames: list.SortStrings([
	for USERNAME, _ in {
		for P in projects for O in P.owners {(O.username): true}
	} {USERNAME},
])

// #ProjectRegistrations are the registry's entries for the collection, one
// per claim, which registry.cue puts just before argocd-apps. Each is the
// component project-<name>, rendered from the one directory
// components/project with the parameter project, so a claim adds a
// component and an Argo CD Application of its own: a broken claim holds
// back only its own Application (interview Q66). They are in name order,
// whatever order CUE loads the claims' files in, so a sync wave, which is
// the registry index, moves only when a claim is added or removed before it.
#ProjectRegistrations: [
	for NAME in list.SortStrings([for NAME, _ in projects {NAME}]) {
		name:      "project-\(NAME)"
		component: "project"
		parameters: project: NAME
	},
]
