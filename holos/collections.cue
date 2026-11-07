package holos

import (
	"list"

	bnd "go.holos.run/distro/holos/bindings"
	ppl "go.holos.run/distro/holos/people"
	prod "go.holos.run/distro/holos/products"
	proj "go.holos.run/distro/holos/projects"
)

// collections.cue binds the ProjectClaim collection (projects/), the people
// collection (people/), the product collection (products/) and the collection
// of bindings (bindings/) into the root of package holos. CUE loads only
// root-level holos/*.cue files as ancestors of the platform and of each
// component, so a collection, which is a package of its own in a subdirectory,
// is visible to them only through this import, as aavis-ops binds its
// collections. The registry (registry.cue)
// adds a component per claim from here, clusterProjects, below, is which
// claims each cluster takes, the project component (components/project)
// renders each on those clusters, and holos-authenticator's allowlist
// (components/holos-authenticator.cue) reads the owners' groups and usernames
// from the definitions below. clusterPeople, below, is which people each
// cluster has, and keycloak-realm renders a User for each. Nothing here gives a
// person a group or a place on the allowlist: a group is a claim's, for its
// owners, editors and viewers, and a place on the allowlist a claim's for its
// owners alone. A binding binds products to a claim: the registry adds a
// component per binding and product (productBindings, below), bindingValues is
// its values as the product's schema resolves them, clusterBindings is which
// bindings each cluster takes, and the product's component
// (components/product-<product>) renders each on those clusters.
//
// Only what the platform needs is here: the platform instance loads the
// root files and platform/, not components/*.cue, so Keycloak, Quay and the
// other definitions there are out of its reach. The checks that need them,
// which names a claim may not take, are Projects' (components/project.cue),
// which every project component's render evaluates.

// projects is the collection, keyed by project name.
projects: proj.projects

// people is the collection, keyed by email.
people: ppl.people

// products is the collection, keyed by name.
products: prod.products

// bindings is the collection, keyed by name.
bindings: bnd.bindings

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

// clusterPeople are the people each cluster has, by cluster name and then
// email: the ones whose clusterSelector selects it, evaluated as a claim's is
// and a map in the root for the same reason (clusterProjects). Projects
// (components/project.cue) reads it, for the checks and the name reservations
// a person takes part in, and through Projects.collected keycloak-realm, for
// the Users. So a person leaves no trace on a cluster they do not select. The
// owner definitions below do not read it: a person is on holos-authenticator's
// allowlist only as an owner, through a claim.
clusterPeople: {
	for CLUSTER, C in clusters {
		(CLUSTER): {
			for EMAIL, P in people
			if P.clusterSelector != _|_
			if (#ClusterSelected & {selector: P.clusterSelector, labels: C.metadata.labels}).selected {
				(EMAIL): P
			}
		}
	}
}

// personClusters are the clusters each person exists on, by email, and there is
// at least one, as claimClusters requires of a claim and for the same reason: a
// person on no cluster, for want of a selector or because it selects none,
// fails cue vet here, with the email in the error. holos render platform would
// drop them and exit 0.
personClusters: {
	for EMAIL, _ in people {
		(EMAIL): [for CLUSTER, P in clusterPeople if P[EMAIL] != _|_ {CLUSTER}] & [_, ...]
	}
}

// productComponents checks the products' components, by product and then
// component name: each is an optional entry of the registry, since that is all
// a cluster can name (#Cluster.components), and anything else, whether a typo,
// an entry further down the stack or a claim, would keep the product off every
// cluster with every other check passing. products/ cannot see the registry, so
// the check is here, and fails cue vet with both names in the error.
productComponents: {
	for NAME, P in products {
		(NAME): {
			for COMPONENT in P.components {
				(COMPONENT): true & list.Contains(#OptionalComponents, COMPONENT)
			}
		}
	}
}

// bindingRefs checks what each binding refers to, by binding name, and fails
// cue vet with the binding and the offending name in the error: project is a
// claim, each of productRefs is a product, once, and each key of values is one
// of productRefs. A claim or product that does not exist would otherwise only
// leave a reference incomplete, which plain cue vet passes, and a key of values
// naming no product of the binding's, a typo, would do nothing at all.
// bindings/ cannot see either collection, so the checks are here.
bindingRefs: {
	for NAME, B in bindings {
		(NAME): {
			project: (B.project): true & projects[B.project] != _|_
			productRefs: {
				for INDEX, R in B.productRefs {
					(R.name): {
						exists: true & products[R.name] != _|_
						index:  INDEX
					}
				}
			}
			values: {
				for PRODUCT, _ in B.values {
					(PRODUCT): true & list.Contains([for R in B.productRefs {R.name}], PRODUCT)
				}
			}
		}
	}
}

// productBindings are the bindings by registry name, product-<product>-<claim>,
// one per binding and product, with the names of the binding, the product and
// the claim. It holds no more than the names, because the registry reads it and
// every component and the platform read the registry: a mistake in one
// binding's values fails only bindingValues, below, where an error here would
// leave the platform with no components at all, and holos render platform would
// exit 0 with nothing rendered.
//
// Two bindings that come to one name conflict here, and fail cue vet with the
// name in the error: the same claim and product bound twice, or a name that two
// pairs spell, as product a-b with claim c and product a with claim b-c both
// spell product-a-b-c. The registry would otherwise have two entries with one
// name, and only one would render.
productBindings: {
	for BINDING, B in bindings for R in B.productRefs {
		"product-\(R.name)-\(B.project)": {
			binding: BINDING
			product: R.name
			project: B.project
		}
	}
}

// bindingValues are each binding's values for a product, by registry name,
// resolved: a product's #Values is closed and parameterised on the claim's
// name, so this is where a binding's values are refused, failing cue vet with
// the registry name in the error, and where a default that depends on the claim
// gets its value. The product's component reads this (#ProductComponent,
// components/product.cue).
//
// It is written as one expression, not through an embedding of #Values, which
// would reopen the schema, and not with a default of {} for a product the
// binding has no key for, which would drop values the schema refuses instead of
// failing.
bindingValues: {
	for ENTRY, E in productBindings
	let VALUES = bindings[E.binding].values {
		(ENTRY): products[E.product].#Values & {
			#project: E.project
			if VALUES[E.product] != _|_ {VALUES[E.product]}
		}
	}
}

// #BindingMissing are the components each binding lacks on each cluster its
// claim lands on, by cluster and then binding name: the components of the
// binding's products that the cluster does not name, and for a binding the
// cluster can take, none. A binding on no claim or a product that does not
// exist has nothing to look up here, and bindingRefs refuses it.
#BindingMissing: {
	for CLUSTER, C in clusters {
		(CLUSTER): {
			for NAME, B in bindings
			if clusterProjects[CLUSTER][B.project] != _|_ {
				(NAME): [
					for R in B.productRefs
					if products[R.name] != _|_
					for COMPONENT in products[R.name].components
					if !list.Contains(C.components, COMPONENT) {COMPONENT},
				]
			}
		}
	}
}

// clusterBindings are the bindings each cluster takes, by cluster and then
// binding name: the ones whose claim lands on it and whose products' components
// it names, all of them, so a binding of two products lands whole or not at
// all. Whatever reads the collection for a cluster reads this, clusterRegistry
// first, so a binding leaves no trace on a cluster that does not take it. It is
// a map in the root for the reason clusterProjects is.
clusterBindings: {
	for CLUSTER, MISSING in #BindingMissing {
		(CLUSTER): {
			for NAME, COMPONENTS in MISSING
			if len(COMPONENTS) == 0 {
				(NAME): bindings[NAME]
			}
		}
	}
}

// bindingGaps reports a binding that does not land on a cluster its claim lands
// on, by cluster, binding and missing component, each a required field nothing
// sets. So it fails cue vet the way a registry entry without a priority does:
// plain cue vet says only that some instances are incomplete, and cue vet -c
// names the cluster, the binding and the component. It does not stop a render:
// holos render platform reads platform, not this, and clusterBindings has left
// the binding out, so the cluster renders nothing for it and the claim's other
// clusters render as they would.
bindingGaps: {
	for CLUSTER, MISSING in #BindingMissing
	for NAME, COMPONENTS in MISSING
	for COMPONENT in COMPONENTS {
		(CLUSTER): (NAME): (COMPONENT)!: string
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

// #BindingRegistrations are the registry's entries for the bindings, one per
// binding and product (productBindings), which registry.cue puts after every
// claim's own entry and after the components a product can name. Each is the
// component product-<product>-<claim>, rendered from the directory
// components/product-<product> with the parameters project and product, so a
// binding adds a component and an Argo CD Application of its own, as a claim
// does and for the same reason. They are in name order, and optional, and no
// cluster names one, for the reasons #ProjectRegistrations gives: this list is
// every binding, whichever clusters take it (#OptionalComponents,
// registry.cue). Like that list it reads neither clusters nor anything that
// does, clusterProjects and clusterBindings among them, since
// #Cluster.components reads it.
#BindingRegistrations: [
	for NAME in list.SortStrings([for NAME, _ in productBindings {NAME}]) {
		name:      NAME
		component: "product-\(productBindings[NAME].product)"
		priority:  "optional"
		parameters: {
			project: productBindings[NAME].project
			product: productBindings[NAME].product
		}
	},
]
