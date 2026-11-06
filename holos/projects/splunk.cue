package projects

projects: "splunk": {
	clusterSelector: matchLabels: "holos.run/cluster-name": "cartography"
	owners: "alex@bank.internal": _
}
