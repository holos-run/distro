// Package people is the people collection: one small file per person, keyed
// by email, which someone adds in a pull request with the manifests it
// renders. A person is
//
//	// holos/people/my-person.cue
//	package people
//
//	people: "my.person@bank.internal": {
//		firstName: "My"
//		lastName:  "Person"
//		clusterSelector: matchLabels: "holos.run/cluster-name": "cartography"
//	}
//
// and renders, on each cluster its selector selects, a Keycloak User in the
// Instance's namespace, through the keycloak-realm component, and nothing else:
// no group, no RoleBinding and no entry in holos-authenticator's allowlist. So
// a person can log in to their cluster's realm and nothing grants them
// anything, until a claim or a group names them, and they reach only what
// admits any realm user (README.md, People). On a cluster their selector does
// not select they do not exist, as a claim leaves no trace on a cluster it does
// not select.
//
// A claim names a person as it names anyone, by email, as an owner, an editor
// or a viewer. A member who is a person on the cluster is adopted: the claim
// renders them no User, since this one exists and a second resource would
// contend for it, and they join the role's group through the claim, and the
// allowlist too if they are an owner. A member who is not renders a User in the
// claim's namespace (Projects, components/project.cue, README.md, Adding a
// person). A claim therefore does not depend on this collection, and listing a
// person here changes no claim that does not name them, unless the claim has
// their username for its name, which fails its render.
//
// firstName and lastName are here for whoever adds the person, and for what
// comes after holos-controller 0.22.0: the User resource has no field for
// either, and none for a password, so they are set in Keycloak by hand.
//
// It is a package of its own, beside projects/, for the reason that one is:
// CUE loads only the root-level holos/*.cue files of package holos as ancestors
// of a component, so holos/collections.cue imports this package and binds
// people into the root, where clusterPeople evaluates each selector and
// Projects (components/project.cue) and keycloak-realm read the result. This
// package can see no cluster. It imports projects for what a person and a
// project's member share, so the two cannot drift: the shape of an email and a
// username, and the derivation of one from the other.
package people

import (
	"strings"

	proj "go.holos.run/distro/holos/projects"
)

// #Person is one person. A member's fields, email and username, are theirs
// too, with the same derivation (proj.#Owner), because a claim finds a person
// by email and the two must agree on the username: set it here when the email's
// local part does not give the right one.
#Person: {
	proj.#Owner

	// firstName and lastName are the name to set in Keycloak (the package
	// comment says why it is by hand). They are required because the realm is:
	// Keycloak's VERIFY_PROFILE form stops a user with no name at first login.
	firstName!: strings.MinRunes(1)
	lastName!:  strings.MinRunes(1)

	// clusterSelector selects the clusters the person exists on, by their
	// labels, as a claim's does (proj.#Project). It is required for the same
	// reason: a default would put a forgotten person on every cluster. A person
	// without one, or whose selector selects no cluster, fails cue vet
	// (personClusters, collections.cue).
	clusterSelector!: proj.#ClusterSelector
}

// people is the collection, keyed by email. The key is unified into email,
// where #Email refuses a malformed one, as owners do: a pattern constraint on
// the key alone would skip it rather than fail.
people: [EMAIL=string]: #Person & {email: EMAIL}
