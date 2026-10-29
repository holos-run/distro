package holos

// #ScopedSecretStore is a per-namespace store (interview Q18): an External
// Secrets SecretStore of the kubernetes provider, in a consumer's namespace,
// that may read the named Secrets in one source namespace and nothing else.
// A component renders it into its resources beside its own ExternalSecrets:
//
//	resources: (#ScopedSecretStore & {
//		name:      "platform"
//		namespace: "ceph-csi-rbd"
//		secrets: ["ceph-client-k8s"]
//	}).resources
//
// and then writes an ExternalSecret against it, naming the store and a
// Secret in the list:
//
//	ExternalSecret: "ceph-client-k8s": {
//		metadata: namespace: "ceph-csi-rbd"
//		spec: {
//			refreshInterval: "1h"
//			secretStoreRef: {kind: "SecretStore", name: "platform"}
//			target: creationPolicy: "Owner"
//			dataFrom: [{extract: key: "ceph-client-k8s"}]
//		}
//	}
//
// creationPolicy Owner, since the source is the truth and the copy follows
// it: deleting the ExternalSecret deletes the copy, and a forced refresh or
// the next refreshInterval picks up a change at the source. Unlike a
// #GeneratedSecret the copy is not immutable.
//
// The source defaults to the platform's management namespace,
// holos-prj-platform (SecretsManager.platform, interview Q54), where
// platform secrets are made through the Secrets Manager; set source for a
// Secret a component generated in its own namespace, as keycloak-realm does
// for holos-controller's credential.
//
// Four resources:
//
//   - A ServiceAccount, reader, by default <namespace>-<name>-reader, in
//     the consumer's namespace, that the store authenticates as. External
//     Secrets requests short-lived tokens for it from the API server
//     (TokenRequest), so nothing mounts it and no token Secret exists.
//   - A Role, reader, in the source namespace, allowed to get the named
//     Secrets alone: resourceNames, and no list or watch, which
//     resourceNames cannot narrow.
//   - A RoleBinding, reader, in the source namespace, granting the Role to
//     the ServiceAccount.
//   - The SecretStore, name, in the consumer's namespace, reading the source
//     namespace through the API server's in-cluster address, which it
//     verifies against the cluster CA in kube-root-ca.crt, a ConfigMap
//     Kubernetes keeps in every namespace.
//
// There is no ClusterSecretStore, and no store a consumer writes for
// itself: a project Owner with admin in their namespace could otherwise
// write an ExternalSecret that copies the Keycloak admin credential or
// holos-controller's Quay token (Q18). The Role is in the source namespace,
// which no consumer controls, so what a store may read is decided where the Secrets
// are. An ExternalSecret against the store naming any other Secret is
// refused by the API server, 403, and reports SecretSyncedError. The store
// reports ReadWrite capabilities, as every kubernetes-provider store does,
// but its Role may only get, so a PushSecret through it is refused too.
#ScopedSecretStore: {
	// name is the SecretStore's, which the consumer's ExternalSecrets name
	// in secretStoreRef.
	name: string
	// namespace is the consumer's, where the store, its ServiceAccount and
	// the copies are.
	namespace: string
	// source is the namespace the Secrets are read from.
	source: string | *SecretsManager.platform.namespace
	// secrets are the Secrets in source the store may read, by name.
	secrets: [string, ...string]
	// reader is the ServiceAccount's, the Role's and the RoleBinding's name.
	// The ServiceAccount is in the consumer's namespace, but the Role and
	// the RoleBinding are in the source namespace, which every consumer of
	// it shares, so the default names the consumer's namespace too: two
	// consumers both calling their store platform get a Role each.
	reader: string | *"\(namespace)-\(name)-reader"

	let Name = name
	let Namespace = namespace
	let Source = source
	let Secrets = secrets
	let Reader = reader

	resources: #Resources & {
		ServiceAccount: (Reader): metadata: namespace: Namespace
		Role: (Reader): {
			metadata: namespace: Source
			rules: [{
				apiGroups: [""]
				resources: ["secrets"]
				resourceNames: Secrets
				verbs: ["get"]
			}]
		}
		RoleBinding: (Reader): {
			metadata: namespace: Source
			roleRef: {
				apiGroup: "rbac.authorization.k8s.io"
				kind:     "Role"
				name:     Reader
			}
			subjects: [{
				kind:      "ServiceAccount"
				name:      Reader
				namespace: Namespace
			}]
		}
		SecretStore: (Name): {
			metadata: namespace: Namespace
			spec: provider: kubernetes: {
				remoteNamespace: Source
				server: caProvider: {
					type: "ConfigMap"
					name: "kube-root-ca.crt"
					key:  "ca.crt"
				}
				auth: serviceAccount: name: Reader
			}
		}
	}
}
