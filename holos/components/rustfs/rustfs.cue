package holos

import "strings"

// rustfs is RustFS standalone, one pod and one volume, the base's one S3 store
// (interview Q12): Substrate's snapshots, Quay's blobs, and later anything
// else that needs S3. Its S3 endpoint is the ClusterIP Service
// rustfs-svc.rustfs.svc:9000, path-style, region us-east-1; no route reaches
// it, or its console, from outside the cluster.
//
// RustFS 1.0.4 from chart 1.0.4, the latest release of the rustfs chart at
// https://charts.rustfs.com, with the image pinned by tag on docker.io. The
// chart's standalone mode is a Deployment and one PersistentVolumeClaim; the
// Deployment tolerates no taint, so the control plane's NoSchedule taint keeps
// it on the workers. The namespace is in the mesh, like hello's: clients reach
// it through ztunnel, over HBONE from the mesh and in plaintext from outside.
//
// Every credential is generated in the cluster (#GeneratedSecret): rustfs-root,
// the root user RustFS starts with, and rustfs-substrate and rustfs-quay, an
// access key and a secret key for each consumer. The rustfs-register Job reads
// all three and registers the consumers' buckets, users and policies; it mints
// nothing. The consumers' copies, in their own namespaces, are made by the
// per-namespace stores, not here.
RustFSVersion: "1.0.4"

// Name is the namespace and the Helm release, so the chart names its objects
// rustfs, rustfs-svc and rustfs-data.
let Name = "rustfs"

// Endpoint is the S3 endpoint, the chart's Service: the release's full name,
// then -svc.
let Endpoint = "http://rustfs-svc.\(Name).svc:9000"

// Consumers are the buckets the Job registers, one per consumer, each with a
// user whose keys are Secret rustfs-<bucket> and a policy of the same name
// that allows that user to list, read, write and delete objects in that
// bucket and nothing else.
let Consumers = ["substrate", "quay"]

// RootKeys are the variables RustFS reads its root user from; the chart
// passes the root Secret to the container whole, with envFrom.
let RootKeys = ["RUSTFS_ACCESS_KEY", "RUSTFS_SECRET_KEY"]

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: Name
	chart: {
		name:    "rustfs"
		version: RustFSVersion
		release: Name
		repository: {
			name: "rustfs"
			url:  "https://charts.rustfs.com"
		}
	}
	values: {
		// One pod, one volume. The chart's default is distributed, a
		// StatefulSet of four.
		mode: {
			standalone: enabled:  true
			distributed: enabled: false
		}
		replicaCount: 1

		image: {
			rustfs: {
				repository: "docker.io/rustfs/rustfs"
				tag:        RustFSVersion
			}
			// The init container only creates /data; its default tag is
			// stable, which moves.
			initImage: {
				repository: "docker.io/library/busybox"
				tag:        "1.37.0"
			}
		}

		// The root user is rustfs-root, below. Without existingSecret the
		// chart renders the keys into a Secret from its values, which would
		// put them in git.
		secret: existingSecret: "rustfs-root"

		config: rustfs: {
			// Logs go to stdout, not to a second volume. The chart's default,
			// /logs, claims one and sends the logs only there. RustFS treats
			// production as a reason to turn stdout off, so the environment
			// stays the chart's default, development.
			obs_log_directory: ""
			obs_environment:   "development"
			// Path-style requests only; the chart's default, stated.
			domains: ""
			region:  "us-east-1"
		}

		// RustFS checks GitHub for a newer release at startup and logs the
		// result. The version is pinned here, so it is off.
		extraEnv: [{name: "RUSTFS_CHECK_UPDATE", value: "false"}]

		// No Ingress: the cluster has none, and nothing outside it needs S3
		// yet. A route would go on the ingress Gateway.
		ingress: enabled: false

		// The volume is on the default class, ceph-rbd, replicated across
		// the hosts and expandable in place. Argo CD neither prunes nor
		// deletes it: ceph-rbd reclaims with Delete, so removing or renaming
		// this component would otherwise drop every bucket. The chart's
		// helm.sh/resource-policy: keep only Helm reads.
		storageclass: {
			name:            "ceph-rbd"
			dataStorageSize: "50Gi"
			pvcAnnotations: data: "argocd.argoproj.io/sync-options": "Prune=false,Delete=false"
		}

		// RustFS does not call the Kubernetes API.
		serviceAccount: automount: false

		podSecurityContext: seccompProfile: type: "RuntimeDefault"
		resources: {
			requests: {cpu: "100m", memory: "256Mi"}
			limits: memory: "2Gi"
		}
	}

	resources: #Resources & {
		Namespace: (Name): metadata: labels: Istio.ambient

		// The Job's script, mounted rather than inlined, so a change to it
		// is a diff of a file and the Job's command stays short.
		ConfigMap: "rustfs-register": {
			metadata: namespace: Name
			data: "register.sh": RegisterScript
		}

		// rustfs-register registers the consumers with RustFS: their
		// buckets, a user per consumer with the keys in its Secret, and a
		// policy limiting that user to its bucket. Every step converges, so
		// it runs on every sync: an Argo CD PostSync hook, after RustFS is
		// Healthy, deleted and re-created each time (BeforeHookCreation),
		// since a Job's template cannot change in place. A rebuilt
		// cluster, whose Secrets are new, ends up with users that match.
		//
		// It is deleted as soon as it succeeds (HookSucceeded), its pod with
		// it. The kubelet does not watch an immutable Secret: it keeps the
		// copy it has for as long as any pod on the node names the Secret,
		// and hands that copy to every new pod there. A completed pod left
		// behind would hand a rotated key's old value to the next run on
		// its node. A failed Job stays until the next sync, for its logs.
		Job: "rustfs-register": {
			metadata: {
				namespace: Name
				annotations: {
					"argocd.argoproj.io/hook":               "PostSync"
					"argocd.argoproj.io/hook-delete-policy": "BeforeHookCreation,HookSucceeded"
				}
			}
			spec: {
				backoffLimit: 6
				// The script waits five minutes at most for RustFS; the
				// rest is a few seconds of requests.
				activeDeadlineSeconds: 600
				template: spec: {
					restartPolicy:                "OnFailure"
					automountServiceAccountToken: false
					securityContext: {
						runAsNonRoot: true
						runAsUser:    10001
						runAsGroup:   10001
						seccompProfile: type: "RuntimeDefault"
					}
					containers: [{
						name: "register"
						// RustFS's own client, rc. Its admin commands speak
						// RustFS's IAM API; MinIO's mc admin does not.
						image: "docker.io/rustfs/rc:v0.1.36"
						command: ["/bin/sh", "/scripts/register.sh"]
						env: [
							for K in RootKeys {
								name: K
								valueFrom: secretKeyRef: {name: "rustfs-root", key: K}
							},
							// rc reads an alias from RC_HOST_<alias>. The
							// generated keys are letters and digits, so
							// they need no escaping in the URL.
							{
								name:  "RC_HOST_rustfs"
								value: strings.Replace(Endpoint, "://", "://$(RUSTFS_ACCESS_KEY):$(RUSTFS_SECRET_KEY)@", 1)
							},
							{name: "RC_CONFIG_DIR", value: "/tmp/rc"},
							for C in Consumers for K in ["access-key", "secret-key"] {
								name: strings.ToUpper("\(C)_\(strings.Replace(K, "-", "_", -1))")
								valueFrom: secretKeyRef: {name: "rustfs-\(C)", key: K}
							},
						]
						volumeMounts: [
							{name: "scripts", mountPath: "/scripts"},
							{name: "tmp", mountPath: "/tmp"},
						]
						resources: {
							requests: {cpu: "10m", memory: "32Mi"}
							limits: memory: "128Mi"
						}
						securityContext: {
							allowPrivilegeEscalation: false
							readOnlyRootFilesystem:   true
							capabilities: drop: ["ALL"]
						}
					}]
					volumes: [
						{name: "scripts", configMap: name: "rustfs-register"},
						{name: "tmp", emptyDir: {}},
					]
				}
			}
		}
	}

	// The root user, under the names RustFS reads.
	resources: (#GeneratedSecret & {
		name:      "rustfs-root"
		namespace: Name
		generator: spec: secretKeys: RootKeys
	}).resources

	// Each consumer's access key and secret key. Both are 32 letters and
	// digits; the access key is the user's name in RustFS.
	for C in Consumers {
		resources: (#GeneratedSecret & {
			name:      "rustfs-\(C)"
			namespace: Name
			generator: spec: secretKeys: ["access-key", "secret-key"]
		}).resources
	}
}).artifact]

// RegisterScript is rustfs-register's script. For each consumer it creates the
// bucket, writes the policy, adds the user (which resets the secret key of a
// user that exists), attaches the policy, and removes any other user holding
// that policy: the user of a rotated key, whose access key, its name, has
// changed. Its consumers come from the environment the Job sets.
let RegisterScript = """
	#!/bin/sh
	# Registers each consumer's bucket, user and policy with RustFS. Every
	# step converges, so it is safe to run again.
	set -euo pipefail

	# Wait for the S3 API; on a cold start the Job can run first.
	i=0
	until rc ready rustfs >/dev/null 2>&1; do
	  i=$((i + 1))
	  [ "$i" -lt 60 ] || { echo "rustfs is not ready"; exit 1; }
	  sleep 5
	done

	register() {
	  bucket=$1 access_key=$2 secret_key=$3
	  rc mb --ignore-existing "rustfs/$bucket"
	  cat >"/tmp/$bucket.json" <<EOF
	{
	  "Version": "2012-10-17",
	  "Statement": [{
	    "Effect": "Allow",
	    "Action": [
	      "s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads",
	      "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
	      "s3:ListMultipartUploadParts", "s3:AbortMultipartUpload"
	    ],
	    "Resource": ["arn:aws:s3:::$bucket", "arn:aws:s3:::$bucket/*"]
	  }]
	}
	EOF
	  rc admin policy create rustfs "$bucket" "/tmp/$bucket.json"
	  rc admin user add rustfs "$access_key" "$secret_key"
	  rc admin policy attach rustfs "$bucket" --user "$access_key"
	  # Any other user with this policy has a key that was rotated away.
	  # Under pipefail, a failed listing fails the Job.
	  holders=$(rc admin policy entities rustfs --policy "$bucket" --json |
	    jq -er --arg p "$bucket" '.data.policy_mappings[] | select(.policy == $p) | .users[]')
	  for user in $holders; do
	    [ "$user" = "$access_key" ] || rc admin user remove rustfs "$user"
	  done
	  echo "registered $bucket"
	}

	\(strings.Join([for C in Consumers {
	let V = strings.ToUpper(C)
	"register \(C) \"$\(V)_ACCESS_KEY\" \"$\(V)_SECRET_KEY\""
}], "\n"))

	"""
