package holos

// The platform renders every component in the registry (registry.cue) once
// per cluster in clusters (clusters.cue), into
// deploy/clusters/<cluster>/components/<name>, from its directory under
// components/ with its parameters and the cluster's name as CUE tags.
// Inspect the result with `holos show platform`.
//
// See https://holos.run/docs/api/author/v1alpha6/#Platform
platform: name: "distro"

for CLUSTER in clusters for C in registry {
	platform: components: "\(CLUSTER.name):\(C.name)": {
		name: C.name
		path: "components/\(C.component)"
		parameters: C.parameters & {clusterName: CLUSTER.name}
		labels: {
			cluster:   CLUSTER.name
			component: C.name
		}
		annotations: "app.holos.run/description": "\(C.name) for cluster \(CLUSTER.name)"
	}
}
