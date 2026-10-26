package holos

import "encoding/yaml"

// talos is each cluster's Talos machine configuration patches that come from
// the platform's data, as opposed to the cluster-agnostic ones committed in
// providers/proxmox/talos/patches. `cue cmd talos` (talos_tool.cue) writes
// them to providers/proxmox/talos/clusters/<cluster>/, where cluster.sh gen
// adds them to the cluster's machine configs. They are committed, like
// deploy/, so a rebuild needs only the repository.
talos: [CLUSTER=string]: {
	// controlplane is patched into the control plane's machine config.
	controlplane: [...{...}]
	// file is the patch file's path, relative to this directory, and text its
	// content: controlplane as a stream of YAML documents.
	file: "../providers/proxmox/talos/clusters/\(CLUSTER)/controlplane.yaml"
	text: """
		# Rendered from holos/talos.cue by `cue cmd talos` in holos/. Do not edit.
		\(yaml.MarshalStream(controlplane))
		"""
}

for K, C in clusters {
	talos: (K): controlplane: [
		// The API server resolves every webhook hostname (webhooks.cue) to the
		// ingress Gateway's address, where the webhooks listener passes TLS
		// through to the webhook (components/ingress.cue). Host entries rather
		// than the private zone's wildcard record, so the API server reaches
		// its webhooks without the site's resolver. Only the control plane
		// calls webhooks, so the workers have no entries.
		{
			apiVersion: "v1alpha1"
			kind:       "StaticHostConfig"
			name:       C.loadBalancer.gateway
			hostnames: [for _, H in C.webhooks.hosts {H}]
		},
	]
}
