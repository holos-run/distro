package projects

projects: "lending": {
	clusterSelector: matchLabels: "holos.run/cluster-name": "treasury"
	owners: "dave@bank.internal": _
}
