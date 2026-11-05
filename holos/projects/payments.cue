package projects

projects: "payments": {
	clusterSelector: matchLabels: "holos.run/cluster-name": "treasury"
	owners: "carol@bank.internal": _
}
