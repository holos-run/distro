// Package projects is the ProjectClaim collection (overview §4): one small
// file per project, which a product engineer adds in a pull request with
// the manifests it renders. A claim is
//
//	// holos/projects/my-project.cue
//	package projects
//
//	projects: "my-project": {
//		clusterSelector: matchLabels: "holos.run/cluster-name": "treasury"
//		owners: "alice@bank.internal": _
//	}
//
// and renders, on each cluster its selector selects, through the project
// component (components/project), the project's namespace, its owners'
// Keycloak users and their membership in its owner group, its owner, editor
// and viewer groups, its Quay organization with a team synced from each group,
// its Argo CD AppProject and Application, the RoleBinding that makes its
// owners admins of its namespace, its owner group's entry in
// holos-authenticator's allowlist, and its Substrate atespace, with the
// atespace's route through the Substrate shim.
//
// A claim is a tenant choosing where it lands, so it names its clusters by
// label, and a selector may name several, which matchLabels cannot:
//
//	clusterSelector: matchExpressions: [{
//		key:      "holos.run/cluster-name"
//		operator: "In"
//		values: ["treasury", "cartography"]
//	}]
//
// Every cluster carries holos.run/cluster-name and holos.run/site from its
// data (#Cluster.metadata, clusters.cue). README.md, Projects, is the
// walk-through.
//
// It is ported from holos-run/aavis-ops' Project collection (interview Q6),
// which ProjectClaim and Project name alike here, without what this distro
// has no use for yet: Kargo, OCI config bundles, release control, the
// production admission gate, site-local fields, custodian groups and the
// apps collection.
//
// It is a package of its own because CUE loads only the root-level holos/*.cue
// files of package holos as ancestors of a component: a package holos file
// in this directory would be visible to no component. holos/collections.cue
// imports this package and binds projects into the root, where the registry,
// the project component and holos-authenticator read it. For the same reason
// the schemas of a label and of a selector are here and the evaluation is in
// the root (clusterProjects, collections.cue): this package can see no
// cluster, and #Cluster takes its labels from #Labels through the same import.
package projects

import (
	"regexp"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// #Name is what a project's name may be. The name is used unchanged as its
// namespace, its Argo CD AppProject and Application, its Quay organization,
// the segment of its Keycloak group paths, its atespace and the label of its
// actors' hosts, so it must suit them all: a DNS label, as a namespace is,
// without the consecutive dashes Quay refuses in an organization name, and at
// least two characters, Quay's minimum. At most 54, not a label's 63: the Job
// that makes the atespace is atespace-<name>, and Kubernetes refuses a Job
// whose name would not fit the 63 characters of the label it puts on its
// pods, at the sync rather than at the render.
// Which names are taken is not a matter of shape: Projects.#Unreserved
// (components/project.cue) checks that, when the project component renders
// the claim.
#Name: =~"^[a-z0-9]+(-[a-z0-9]+)*$" & strings.MinRunes(2) & strings.MaxRunes(54)

// #Email is the shape of an owner's key: a non-empty local part, an @ and a
// dotted domain, in lower case. It is not RFC 5322; it exists to refuse an
// empty key or a bare username at render, before it becomes a Keycloak
// user's email. Lower case, because Keycloak keeps every email in lower
// case, and two spellings of one address would otherwise pass for two
// people.
#Email: =~"^[^@[:space:]A-Z]+@[^@[:space:]A-Z]+\\.[^@[:space:]A-Z]+$"

// #Username is the shape of a Keycloak username a claim may give: lower case,
// since Keycloak lower-cases every username, and a valid name for the User
// resource the project component makes for the owner, which is a DNS
// subdomain: runs of letters and digits joined by single dashes or dots, so
// neither a.b. nor a..b nor a-.b, whose dot-separated parts would begin or
// end with a dash or be empty.
#Username: =~"^[a-z0-9]+([-.][a-z0-9]+)*$" & strings.MaxRunes(253)

// #Owner is one of a project's owners, keyed by email in owners.
#Owner: {
	// email is the owners key. It is the Keycloak user's email and what
	// holos-controller finds the user by when it adds them to the owner
	// group.
	email: #Email

	// username is the owner's Keycloak username, which their tokens carry
	// as preferred_username, and so the user holos-authenticator
	// impersonates them as, oidc:<username>, and the name Quay knows them by.
	// It defaults to the email's local part, lower-cased, with each run of
	// anything outside [a-z0-9] turned to a dash and the dashes at either end
	// trimmed, as aavis-ops derives the name of an owner's User:
	// alice.smith@bank.internal is alice-smith. An owner whose username is
	// something else sets it here. An owner who is already one of the
	// realm's people (Keycloak.users) must have the username they have
	// there, and no owner may be one of the platform's service users, which
	// Projects (components/project.cue) checks when the project component
	// renders the claim.
	let Local = strings.ToLower(strings.SplitN(email, "@", 2)[0])
	let Derived = regexp.ReplaceAll("^-+|-+$", regexp.ReplaceAll("[^a-z0-9]+", Local, "-"), "")
	username: #Username & (*Derived | string)
}

// #LabelKey and #LabelValue are Kubernetes' rules for a label: a key is a name
// of at most 63 characters beginning and ending with a letter or digit, under
// an optional DNS subdomain prefix of at most 253, and a value is such a name
// or empty.
let LabelName = "[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?"
let DNSLabel = "[a-z0-9]([-a-z0-9]*[a-z0-9])?"

#LabelKey:   =~"^(\(DNSLabel)(\\.\(DNSLabel))*/)?\(LabelName)$" & !~"^[^/]{254,}/"
#LabelValue: =~"^(\(LabelName))?$"

// #Labels is a metadata.labels map. It is closed by being a definition, so a
// key outside the pattern is refused, where an open struct would only skip
// the pattern and keep the key.
#Labels: [#LabelKey]: #LabelValue

// #ClusterSelector is Kubernetes' LabelSelector over clusters' labels:
// matchLabels and matchExpressions, every requirement of both ANDed, and {}
// selecting every cluster. Unlike the vendored type's, its two fields always
// exist, so what evaluates a selector need not ask.
#ClusterSelector: metav1.#LabelSelector & {
	matchLabels: #Labels
	matchExpressions: [...metav1.#LabelSelectorRequirement & {
		key: #LabelKey
		// The vendored type is a plain string, so a misspelled operator would
		// otherwise reach #ClusterSelected (collections.cue).
		operator: "In" | "NotIn" | "Exists" | "DoesNotExist"
		values?: [...#LabelValue]

		// In and NotIn take at least one value, and Exists and DoesNotExist
		// none, as the API server requires of any LabelSelector. An empty
		// NotIn would select every cluster.
		let Values = *values | []
		if len(Values) > 0 {operator: "In" | "NotIn"}
		if len(Values) == 0 {operator: "Exists" | "DoesNotExist"}
	}]
}

// #Project is one claim.
#Project: {
	// name is the projects key, the project's one name: its namespace,
	// AppProject, Application, Quay organization and group paths are all
	// named exactly this, with nothing added or derived.
	name: #Name

	// clusterSelector selects the clusters the claim lands on, by their
	// labels. It is required: a field with a default would make a forgotten
	// selector {} and land the claim on every cluster. A claim without one,
	// or whose selector selects no cluster, fails cue vet (claimClusters,
	// collections.cue). Nothing yet lets a cluster refuse a claim that
	// selects it.
	clusterSelector!: #ClusterSelector

	// ownerAccess is the built-in ClusterRole the project's owner group is
	// bound to in the project's namespace: admin by default, to create,
	// change and delete anything namespaced, including RBAC within the
	// namespace; edit, the same without RBAC; or view, read only. It is
	// Kubernetes' own vocabulary, so a claim chooses among roles every
	// cluster has.
	ownerAccess: *"admin" | "edit" | "view"

	// owners are the project's owners by email, at least one, which the
	// project component checks (components/project): a constraint here
	// would make the schema itself unsatisfiable, since its owners are
	// empty until a claim fills them. A pattern constraint alone does not
	// reject a key that does not match it, so the key is unified into
	// email, where #Email does.
	owners: [EMAIL=string]: #Owner & {email: EMAIL}
}

// projects is the collection, keyed by name. The key is unified into name,
// where #Name refuses a malformed one: a pattern constraint on the key alone
// would skip it rather than fail.
projects: [NAME=string]: #Project & {name: NAME}
