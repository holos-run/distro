package holos

import "list"

// Planboard names what of a Planboard binding a component other than the
// binding's own reads: the Keycloak client of a claim's board, which
// product-planboard-<claim> makes and logs in through, and whose tokens the
// Substrate shim takes as well as kubectl's (components/substrate-shim). Both
// read the name here, so they cannot disagree.
Planboard: {
	// #Client is the public client of the board of the claim project,
	// planboard-<project>. The realm's client IDs are one namespace, so the
	// claim's name in it keeps one claim's board from another's. It is also
	// the aud of the ID tokens the board's login gets, which the shim admits
	// on that board's host alone (AteGateway.#Rule).
	#Client: {
		project: string
		id:      "planboard-\(project)"
	}

	// clients are the clients of the boards this cluster takes, one per
	// binding of planboard (clusterBindings, collections.cue), and none on a
	// cluster with no such binding.
	clients: list.SortStrings([
		for B in clusterBindings[Cluster.name]
		for R in B.productRefs if R.name == "planboard" {
			(#Client & {project: B.project}).id
		},
	])
}
