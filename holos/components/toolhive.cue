package holos

// ToolHive is Stacklok's MCP server operator (interview Q3, last and best
// effort): its pins and the names the toolhive-crds, toolhive-operator and
// toolhive components share. The operator runs in its own namespace and
// manages MCP servers in server.namespace alone, where each MCPServer is a
// proxy runner, which authenticates and authorizes every request, in front
// of the MCP server's own pod, which only the proxy reaches.
//
// To bump a cluster, set its pins.toolhive: version to the new release's, the
// operator, proxy runner and vMCP index digests from ghcr.io/stacklok/toolhive
// and the registry API's from its own repository; then re-read the
// operator chart's values.yaml against the toolhive-operator component's
// and the CRDs against the toolhive component's, and re-render: holos pulls
// the charts by version into the components' vendor/ caches, which are
// committed.
ToolHive: {
	// version is the release's, which is also its charts' version and,
	// with a v, its images' tag.
	version:  Cluster.pins.toolhive.version
	registry: "ghcr.io/stacklok/toolhive"

	// charts are the release's two OCI charts. The digests are for the
	// reader: holos pulls by version.
	charts: {
		crds: {
			name:   "oci://\(registry)/toolhive-operator-crds"
			digest: Cluster.pins.toolhive.charts.crds
		}
		operator: {
			name:   "oci://\(registry)/toolhive-operator"
			digest: Cluster.pins.toolhive.charts.operator
		}
	}

	// images are the operator's, the proxy runner's it starts for each
	// MCPServer, and the Virtual MCP server's and the registry API's, which
	// nothing here runs but which the chart hands the operator, by index
	// digest. The registry API has its own version, the chart's default.
	images: {
		operator:    "\(registry)/operator:v\(version)@\(Cluster.pins.toolhive.digests.operator)"
		proxyrunner: "\(registry)/proxyrunner:v\(version)@\(Cluster.pins.toolhive.digests.proxyrunner)"
		vmcp:        "\(registry)/vmcp:v\(version)@\(Cluster.pins.toolhive.digests.vmcp)"
		registryAPI: "ghcr.io/stacklok/thv-registry-api:\(Cluster.pins.toolhive.registryAPI.version)@\(Cluster.pins.toolhive.registryAPI.digest)"
	}

	// operator is the operator's namespace and Helm release.
	operator: {
		namespace: "toolhive-system"
		release:   "toolhive-operator"
	}

	// server is the one MCP server and where it runs. Its namespace is
	// the only one the operator watches. name is the MCPServer's, which
	// the operator names the proxy runner's Deployment and Service after,
	// mcp-<name>-proxy, and the proxy runner names the MCP server's
	// StatefulSet and its Service after, <name> and mcp-<name>.
	server: {
		namespace: "toolhive"
		name:      "everything"
		// The MCP reference server's "everything", as Stacklok's dockyard
		// packages it for the ToolHive catalog (stacklok/toolhive-catalog,
		// registries/toolhive/servers/everything), by index digest. It
		// needs no network: npx runs the package from the image's own
		// node_modules. Its streamableHttp argument serves MCP over HTTP at
		// /mcp on port, below, so the proxy reaches it over the network, which
		// the NetworkPolicy can hold, rather than by attaching to its stdio
		// through the API server.
		image: "ghcr.io/stacklok/dockyard/npx/server-everything:\(Cluster.pins.toolhive.everything.version)@\(Cluster.pins.toolhive.everything.digest)"
		port:  3001
		// proxy is the proxy runner's port and Service, which the ingress
		// Gateway routes to.
		proxy: {
			port:    8080
			service: "mcp-\(name)-proxy"
		}
		// host and url are the server's public name, under the ingress
		// Gateway's wildcard certificate; MCP clients use url/mcp.
		host: IngressGateway.hosts.toolhive
		url:  "https://\(host)"
	}
}
