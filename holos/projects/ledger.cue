package projects

projects: "ledger": {
	clusterSelector: matchLabels: "holos.run/cluster-name": "treasury"
	owners: "bob@bank.internal": _
}
