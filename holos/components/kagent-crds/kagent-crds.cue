package holos

import "encoding/yaml"

// kagent-crds is kagent's CRDs, api.kagent.dev, from the holos-run fork's
// kagent-crds chart (Kagent, kagent.cue), ahead of the kagent component,
// whose chart writes a ModelConfig and a RemoteMCPServer. The chart holds
// nothing but the CRDs.
holos: spec: artifacts: [(#HelmArtifact & {
	namespace: Kagent.namespace
	chart: {
		name:    Kagent.charts.crds.name
		version: Kagent.version
		release: "\(Kagent.release)-crds"
	}

	// Argo CD neither prunes nor deletes a CRD. Deleting one deletes every
	// object of its kind, every Agent and the Secret references they hold,
	// so removing or renaming this component would otherwise delete
	// people's agents.
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
