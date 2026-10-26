package holos

import (
	"encoding/json"
	"encoding/yaml"
)

// local-path is Rancher's local-path-provisioner and its local-path
// StorageClass: a volume is a directory on one node's disk, and its pod is
// pinned to that node. It is installed as the fallback but not used without
// a compelling reason; ceph-rbd is the default class (README.md, "Storage").
// The class is not the default: the release manifest gives it no default
// annotation, and nothing here adds one.
//
// vendor/v0.0.37/local-path-storage.yaml is the release's manifest,
// unmodified; the patches below make it fit Talos:
// https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
// sha256:9781b39c24f3f651bd6d6e41b561e04e4904bbdb6d4f8c7a6009df3a702dcd65
LocalPathVersion: "v0.0.37"

// The manifest's namespace. The provisioner's helper pods mount the node's
// volume directory as a hostPath, which Talos's baseline Pod Security
// enforcement refuses, so the component labels it privileged (ADR 0001).
LocalPathNamespace: "local-path-storage"

// The volumes' directory on every node. Talos's /opt, the manifest's
// default, is an overlay; /var is the node's persistent partition. The
// kubelet runs in its own mount namespace and does not see this directory,
// which works for the manifest's hostPath volumes (DirectoryOrCreate) but not
// for volumeType local, whose path the kubelet checks; that would need a
// kubelet extraMounts entry in the workers' machine config. /var/mnt, which
// the kubelet does see, is read-only there.
LocalPathDir: "/var/local-path-provisioner"

// offPodNetwork keeps a pod off nodes labeled holos.run/pod-network=none,
// the control plane (ADR 0001), as Cilium's pods are kept off it.
let offPodNetwork = {
	nodeAffinity: requiredDuringSchedulingIgnoredDuringExecution: nodeSelectorTerms: [{
		matchExpressions: [{
			key:      "holos.run/pod-network"
			operator: "NotIn"
			values: ["none"]
		}]
	}]
}

holos: spec: artifacts: [(#FileArtifact & {
	file: "vendor/\(LocalPathVersion)/local-path-storage.yaml"
	patches: [
		{
			target: {kind: "Namespace", name: LocalPathNamespace}
			patch: yaml.Marshal({
				apiVersion: "v1"
				kind:       "Namespace"
				metadata: {
					name: LocalPathNamespace
					labels: "pod-security.kubernetes.io/enforce": "privileged"
				}
			})
		},
		{
			// Every node's volumes under LocalPathDir. The other keys of the
			// ConfigMap, the helper pod and its scripts, are as released.
			target: {kind: "ConfigMap", name: "local-path-config"}
			patch: yaml.Marshal({
				apiVersion: "v1"
				kind:       "ConfigMap"
				metadata: {
					name:      "local-path-config"
					namespace: LocalPathNamespace
				}
				data: "config.json": json.Indent(json.Marshal({
					nodePathMap: [{
						node: "DEFAULT_PATH_FOR_NON_LISTED_NODES"
						paths: [LocalPathDir]
					}]
				}), "", "  ")
			})
		},
		{
			// The provisioner keeps off the control plane. Its helper pods
			// are scheduled to the volume's node by name.
			target: {kind: "Deployment", name: "local-path-provisioner"}
			patch: yaml.Marshal({
				apiVersion: "apps/v1"
				kind:       "Deployment"
				metadata: {
					name:      "local-path-provisioner"
					namespace: LocalPathNamespace
				}
				spec: template: spec: affinity: offPodNetwork
			})
		},
	]
}).artifact]
