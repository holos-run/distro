package holos

import "encoding/yaml"

// toolhive-crds is ToolHive's CRDs, toolhive.stacklok.dev, from the
// release's toolhive-operator-crds chart (ToolHive, components/toolhive.cue),
// ahead of the operator, which watches them, and the toolhive component,
// which writes an MCPServer, an MCPOIDCConfig and an MCPAuthzConfig. The
// chart holds nothing but the CRDs.
holos: spec: artifacts: [(#HelmArtifact & {
	namespace: ToolHive.operator.namespace
	chart: {
		name:    ToolHive.charts.crds.name
		version: ToolHive.version
		release: "\(ToolHive.operator.release)-crds"
	}

	// Argo CD neither prunes nor deletes a CRD. Deleting one deletes every
	// object of its kind, so removing or renaming this component would
	// otherwise delete every MCP server and its policies.
	patches: [{
		target: {
			group: "apiextensions.k8s.io"
			kind:  "CustomResourceDefinition"
		}
		patch: yaml.Marshal({
			apiVersion: "apiextensions.k8s.io/v1"
			kind:       "CustomResourceDefinition"
			metadata: {
				name: "any"
				annotations: "argocd.argoproj.io/sync-options": "Prune=false,Delete=false"
			}
		})
	}]
}).artifact]
