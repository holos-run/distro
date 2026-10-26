package holos

// The platform renders every component in the registry (registry.cue) once
// per cluster in clusters (clusters.cue), into
// deploy/clusters/<cluster>/components/<name>. Inspect the result with
// `holos show platform`.
//
// See https://holos.run/docs/api/author/v1alpha6/#Platform
platform: name: "distro"

for CLUSTER in clusters for C in registry {
	platform: components: "\(CLUSTER.name):\(C.name)": {
		name: C.name
		path: "components/\(C.name)"
		parameters: clusterName: CLUSTER.name
		labels: {
			cluster:   CLUSTER.name
			component: C.name
		}
		annotations: "app.holos.run/description": "\(C.name) for cluster \(CLUSTER.name)"
	}
}
