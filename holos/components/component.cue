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
// the first render and which is committed. Helm hooks are not rendered
// (holos runs helm template --no-hooks).
//
// resources, if set, are rendered beside the chart, and patches, if any, are
// Kustomize patches applied to both; either routes the output through
// kubectl kustomize before it is sliced.
#HelmArtifact: {
	chart: core.#Chart
	values: {...}
	namespace:   string
	enableHooks: bool | *false
	resources?:  #Resources
	patches: [...#KustomizePatch]

	let HasResources = resources != _|_
	let Kustomized = HasResources || len(patches) > 0
	let SliceInput = [if Kustomized {"kustomize-output.yaml"}, "helm-output.yaml"][0]

	artifact: core.#Artifact & {
		artifact: OutputDir
		generators: [
			{
				kind:   "Helm"
				output: "helm-output.yaml"
				helm: {
					"chart":       chart
					"values":      values
					"namespace":   namespace
					"enableHooks": enableHooks
					// Capabilities.KubeVersion for the chart's version checks;
					// helm template otherwise assumes its own built-in version.
					kubeVersion: "v\(Cluster.kubernetesVersion)"
				}
			},
			if HasResources {
				kind:        "Resources"
				output:      "resources.yaml"
				"resources": resources
			},
		]
		transformers: [
			if Kustomized {
				kind: "Kustomize"
				inputs: ["helm-output.yaml", if HasResources {"resources.yaml"}]
				output: "kustomize-output.yaml"
				kustomize: kustomization: {
					"resources": inputs
					"patches":   patches
				}
			},
			{
				kind: "Command"
				inputs: [SliceInput]
				output: OutputDir
				command: args: ["holos", "kubectl-slice", "-f", "\(BuildContext.tempDir)/\(SliceInput)", "-o", "\(BuildContext.tempDir)/\(OutputDir)"]
			},
		]
	}
}

// #KustomizePatch is one entry of a kustomization's patches: a strategic
// merge or JSON 6902 patch, inline, and the objects it applies to.
#KustomizePatch: {
	target: {
		group?:   string
		version?: string
		kind:     string
		name?:    string
	}
	patch: string
}

// #FileArtifact renders a vendored manifest file into OutputDir, one file
// per resource. file is relative to the component's directory. Documents
// that are not Kubernetes objects, such as a release file's comment-only
// license header, are dropped.
#FileArtifact: {
	file: string

	artifact: core.#Artifact & {
		artifact: OutputDir
		generators: [{
			kind:   "File"
			output: "file-output.yaml"
			"file": source: file
		}]
		transformers: [{
			kind: "Command"
			inputs: ["file-output.yaml"]
			output: OutputDir
			command: args: ["holos", "kubectl-slice", "--skip-non-k8s", "-f", "\(BuildContext.tempDir)/file-output.yaml", "-o", "\(BuildContext.tempDir)/\(OutputDir)"]
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
