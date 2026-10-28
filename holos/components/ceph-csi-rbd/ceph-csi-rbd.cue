package holos

import "encoding/yaml"

// ceph-csi-rbd is ceph-csi's RBD driver against the Ceph cluster the site's
// hosts run (Cluster.site.ceph, clusters.cue), and the ceph-rbd
// StorageClass, the cluster's default. Volumes are ReadWriteOnce RBD images
// in the cluster's pool, replicated across the hosts, so a volume survives
// losing a host and follows its pod to any worker. CephFS is left out: the
// Ceph cluster has no filesystem and nothing needs ReadWriteMany.
//
// The driver creates nothing on the Ceph side. It authenticates as
// client.<Cluster.ceph.user>, whose key is in Secret
// <CephCSINamespace>/<Cluster.ceph.secret>. The repository is public, so the
// key is never rendered. It is a platform secret of the same name in the
// management namespace, holos-prj-platform, written there once per cluster
// at bootstrap from ceph auth get-key (README.md, "Storage"), and an
// ExternalSecret copies it into the driver's namespace through a
// per-namespace store (#ScopedSecretStore) that may read that one Secret.
// The copy is Owner, not immutable like a #GeneratedSecret: the management
// namespace is the source of truth, so deleting and re-creating the
// ExternalSecret copies the same key back, and a change at the source
// arrives within the hour, or at once with a forced refresh.
//
// ceph-csi registers no admission webhook and no APIService.
//
// 3.17.1, not the latest, 3.18.1: from 3.18.0 the cephcsi image is built on
// Rocky Linux 10, whose glibc needs x86-64-v3 (AVX2), and the garage's Xeon
// E5-2670 hosts have AVX but no AVX2, so 3.18's plugin exits at once with
// "CPU does not support x86-64-v3". 3.17.1 is the latest release on CentOS
// Stream 9 (x86-64-v2), built with Tentacle's client libraries, the same
// release as the Ceph cluster. Stay on 3.17 until the hosts are replaced.
CephCSIVersion: "3.17.1"

// The node plugin runs privileged with host networking and kubelet's
// plugin paths, which Talos's baseline Pod Security enforcement refuses, so
// the component labels its namespace privileged (ADR 0001).
CephCSINamespace: "ceph-csi-rbd"

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

let Ceph = Cluster.site.ceph

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: CephCSINamespace
	chart: {
		name:    "ceph-csi-rbd"
		version: CephCSIVersion
		release: "ceph-csi-rbd"
		repository: {
			name: "ceph-csi"
			url:  "https://ceph.github.io/csi-charts"
		}
	}
	values: {
		// The Ceph cluster, named by its fsid, which the StorageClass's
		// clusterID refers to.
		csiConfig: [{
			clusterID: Ceph.fsid
			monitors:  Ceph.monitors
		}]

		// The chart's own Secret is off (its default, stated): the
		// ExternalSecret below writes it.
		secret: create: false

		storageClass: {
			create: true
			name:   "ceph-rbd"
			annotations: "storageclass.kubernetes.io/is-default-class": "true"
			clusterID: Ceph.fsid
			pool:      Cluster.ceph.pool
			// The features the Talos kernel's RBD client maps; the chart's
			// default is layering alone.
			imageFeatures:        "layering,exclusive-lock,object-map,fast-diff"
			fstype:               "ext4"
			reclaimPolicy:        "Delete"
			allowVolumeExpansion: true
			// The chart sets no volumeBindingMode, so binding is Immediate,
			// the API's default: an RBD image attaches to any node, so
			// there is no reason to wait for the pod's.
			provisionerSecret:       Cluster.ceph.secret
			controllerExpandSecret:  Cluster.ceph.secret
			controllerPublishSecret: Cluster.ceph.secret
			nodeStageSecret:         Cluster.ceph.secret
		}

		// No snapshot classes until CNPG backups need them.
		volumeSnapshotClass: create:      false
		volumeGroupSnapshotClass: create: false

		// Talos's kubelet directory; the chart's default, stated. RBD is
		// built into the Talos kernel, so the node plugin loads no module;
		// its read-only /lib/modules mount, which the chart always renders,
		// is unused.
		kubeletDir: "/var/lib/kubelet"

		// The node plugin and the provisioner keep off the control plane.
		// The DaemonSet tolerates no taint, so the control plane's
		// NoSchedule taint would keep it off anyway; the affinity states it
		// the way Cilium's DaemonSets do.
		nodeplugin: affinity: offPodNetwork
		// Three replicas, the chart's default. With more than one the chart
		// adds a required pod anti-affinity on the hostname, so they land
		// on the three workers, one each; this affinity sits beside it.
		provisioner: {
			replicaCount: 3
			affinity:     offPodNetwork
		}
	}

	resources: Namespace: (CephCSINamespace): metadata: labels: "pod-security.kubernetes.io/enforce": "privileged"

	// The key, copied from the management namespace. The store's Role and
	// RoleBinding are in holos-prj-platform, which management-namespaces,
	// earlier in the registry, makes; external-secrets, earlier still,
	// brings the CRDs. The keys, userID and userKey, come across as they
	// are, the names the StorageClass's secret parameters read.
	resources: (#ScopedSecretStore & {
		name:      "platform"
		namespace: CephCSINamespace
		secrets: [Cluster.ceph.secret]
	}).resources

	resources: ExternalSecret: (Cluster.ceph.secret): {
		metadata: namespace: CephCSINamespace
		spec: {
			refreshInterval: "1h"
			secretStoreRef: {kind: "SecretStore", name: "platform"}
			target: creationPolicy: "Owner"
			dataFrom: [{extract: key: Cluster.ceph.secret}]
		}
	}

	// The chart always renders the provisioner's csi-snapshotter sidecar,
	// which, without the VolumeSnapshot CRDs, logs a failed watch every
	// few seconds. It comes back with the snapshot controller, when CNPG
	// backups need it.
	patches: [{
		target: {kind: "Deployment", name: "ceph-csi-rbd-provisioner"}
		patch: yaml.Marshal({
			apiVersion: "apps/v1"
			kind:       "Deployment"
			metadata: {
				name:      "ceph-csi-rbd-provisioner"
				namespace: CephCSINamespace
			}
			spec: template: spec: containers: [{name: "csi-snapshotter", "$patch": "delete"}]
		})
	}]
}).artifact]
