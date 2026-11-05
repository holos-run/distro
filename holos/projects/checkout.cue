package projects

projects: "checkout": {
	clusterSelector: matchLabels: "holos.run/cluster-name": "treasury"
	owners: "alice@bank.internal": _
}
