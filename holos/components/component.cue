package holos

import (
	"encoding/json"

	core "github.com/holos-run/holos/api/core/v1alpha6:core"
)

// This file is an ancestor of every components/<name> directory, so CUE
// loads it into each component instance. A component sets holos.spec and
// gets the rest of its BuildPlan from here.

_BuildContext: string | *"{}" @tag(holos_build_context, type=string)
BuildContext:  core.#BuildContext & json.Unmarshal(_BuildContext)

// Cluster is the cluster this instance renders for, from clusters.cue.
Cluster: clusters[clusterName]

// ComponentName is the component's name in the platform registry.
ComponentName: _Tags.component.name

// OutputDir is the component's directory in deploy/.
OutputDir: "clusters/\(clusterName)/components/\(ComponentName)"

holos: core.#BuildPlan & {
	apiVersion:   "v1alpha6"
	kind:         "BuildPlan"
	buildContext: BuildContext
	metadata: {
		name: ComponentName
		if _Tags.component.labels != _|_ {
			labels: _Tags.component.labels
		}
		if _Tags.component.annotations != _|_ {
			annotations: _Tags.component.annotations
		}
	}
}

// #HelmArtifact renders a Helm chart into OutputDir, one file per resource.
// The chart is read from the component's vendor/ cache, which Holos fills on
// the first render and which is committed.
#HelmArtifact: {
	chart: core.#Chart
	values: {...}
	namespace: string

	artifact: core.#Artifact & {
		artifact: OutputDir
		generators: [{
			kind:   "Helm"
			output: "helm-output.yaml"
			helm: {
				"chart":     chart
				"values":    values
				"namespace": namespace
				// Capabilities.KubeVersion for the chart's version checks; helm
				// template otherwise assumes its own built-in version.
				kubeVersion: "v\(Cluster.kubernetesVersion)"
			}
		}]
		transformers: [{
			kind: "Command"
			inputs: ["helm-output.yaml"]
			output: OutputDir
			command: args: ["holos", "kubectl-slice", "-f", "\(BuildContext.tempDir)/helm-output.yaml", "-o", "\(BuildContext.tempDir)/\(OutputDir)"]
		}]
	}
}

// #ResourcesArtifact renders CUE resources into OutputDir, one file per
// resource.
#ResourcesArtifact: {
	resources: #Resources

	artifact: core.#Artifact & {
		artifact: OutputDir
		generators: [{
			kind:        "Resources"
			output:      "resources.yaml"
			"resources": resources
		}]
		transformers: [{
			kind: "Command"
			inputs: ["resources.yaml"]
			output: OutputDir
			command: args: ["holos", "kubectl-slice", "-f", "\(BuildContext.tempDir)/resources.yaml", "-o", "\(BuildContext.tempDir)/\(OutputDir)"]
		}]
	}
}
