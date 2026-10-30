package holos

// toolhive-operator is ToolHive's operator (ToolHive, components/toolhive.cue),
// from the release's toolhive-operator chart, in its own namespace. It
// reconciles the toolhive.stacklok.dev kinds of toolhive-crds, before it, in
// the toolhive namespace alone: for each MCPServer a proxy runner, its
// Service and its RBAC, and the proxy runner then creates the MCP server's
// StatefulSet and Service beside it. The toolhive component, after it,
// holds the MCP server and its policies.
let T = ToolHive
let NS = T.operator.namespace

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: NS
	chart: {
		name:    T.charts.operator.name
		version: T.version
		release: T.operator.release
	}
	values:    Values
	resources: _Resources
}).artifact]

let Values = {
	operator: {
		image:               T.images.operator
		toolhiveRunnerImage: T.images.proxyrunner
		vmcpImage:           T.images.vmcp

		// The operator's RBAC and its watch in the server namespace alone:
		// RoleBindings there to its ClusterRole, which reads and writes
		// Secrets, Services, Deployments and RBAC, in place of a
		// ClusterRoleBinding that would give it every namespace's. The
		// storage version migrator re-stores ToolHive objects across the
		// whole cluster and needs the ClusterRoleBinding, so it is off, as
		// the chart requires for this scope: a CRD version bump that drops a
		// stored version must re-store the objects by hand.
		rbac: {
			scope: "namespace"
			allowedNamespaces: [T.server.namespace]
		}
		features: storageVersionMigrator: false

		// No update checks or the usage metrics sent with them: nothing
		// here calls Stacklok.
		env: [{name: "TOOLHIVE_SKIP_UPDATE_CHECK", value: "true"}]
	}
	registryAPI: image: T.images.registryAPI
}

_Resources: #Resources & {
	// Outside the mesh, and restricted: the chart's pod runs as a non-root
	// user with every capability dropped.
	Namespace: (NS): metadata: labels: "pod-security.kubernetes.io/enforce": "restricted"

	// The server namespace is here, not in the toolhive component, because
	// the chart's RoleBinding, which lets the operator manage it, is in it.
	// Outside the mesh too, so the toolhive component's NetworkPolicies
	// hold at the application ports with nothing else in the path.
	// Restricted: the proxy runner's pod and the MCP server's, which the
	// proxy runner makes, both run as non-root users with every capability
	// dropped (components/toolhive).
	Namespace: (T.server.namespace): metadata: labels: "pod-security.kubernetes.io/enforce": "restricted"
}
