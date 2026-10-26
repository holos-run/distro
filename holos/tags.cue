package holos

import (
	"encoding/json"

	"github.com/holos-run/holos/api/core/v1alpha6:core"
)

// Note: tags should have a reasonable default value for cue export.
_Tags: {
	// Standardized parameters
	component: core.#Component & {
		name: string | *"no-name" @tag(holos_component_name, type=string)
		path: string | *"no-path" @tag(holos_component_path, type=string)

		_labels_json: string | *"" @tag(holos_component_labels, type=string)
		_labels: {}
		if _labels_json != "" {
			_labels: json.Unmarshal(_labels_json)
		}
		for k, v in _labels {
			labels: (k): v
		}

		_annotations_json: string | *"" @tag(holos_component_annotations, type=string)
		_annotations: {}
		if _annotations_json != "" {
			_annotations: json.Unmarshal(_annotations_json)
		}
		for k, v in _annotations {
			annotations: (k): v
		}
	}
}

// clusterName is the cluster a component renders for. holos render platform
// injects it from each component's parameters (platform/platform.cue); the
// default lets `holos cue export ./components/<name>` work on its own.
clusterName: string | *"treasury" @tag(clusterName)
