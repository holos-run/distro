package projects

// choria is the Self-hosted machines demo tenant. It has no editor on purpose:
// an editor could overwrite or take the owner's git credential (planning
// board, security-a-kagent-user-can-send-a-bound-claims-secrets-to). Names
// other than R.I. Pienaar's are invented.
projects: "choria": {
	clusterSelector: matchLabels: "holos.run/cluster-name": "marina"
	owners: "ri.pienaar@bank.internal": _
	viewers: "sam.okafor@bank.internal": _
	runtime: {name: "substrate", sandboxClass: "microvm"}
}
