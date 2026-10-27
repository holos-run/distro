package holos

// #GeneratedSecret is a Secret the platform generates for itself, in the
// cluster, with an External Secrets generator (interview Q46 to Q48): a
// generator resource and the ExternalSecret that writes its output once into
// a Secret of the same name, in the same namespace. A component renders it
// into its resources:
//
//	resources: (#GeneratedSecret & {
//		name:      "rustfs-root"
//		namespace: "rustfs"
//	}).resources
//
// and the Secret holds one key, password, 32 letters and digits. Unify more
// than one into resources for more Secrets, and set generator to change the
// password or to use another kind of generator:
//
//	generator: spec: {length: 48, secretKeys: ["access-key", "secret-key"]}
//	generator: {kind: "UUID", spec: {}}
//
// Set username to make the Secret a login, for a consumer that reads a
// kubernetes.io/basic-auth Secret, such as CloudNativePG's initdb or the
// Keycloak Operator's bootstrap admin:
//
//	username: "keycloak"
//
// The Secret is then of type kubernetes.io/basic-auth, with the username,
// as written here, under username beside the generated password under
// password. The ExternalSecret writes it through its target template, so it
// is written once and immutable like any other; the username is in git and
// the password is not. A username needs the default generator, a Password
// with the one key, password.
//
// The Secret survives a delete and re-create of its ExternalSecret or its
// generator, and is regenerated only when the cluster is rebuilt (Q47).
// Three layers hold it (Q48):
//
//   - The ExternalSecret writes once and lets go. refreshPolicy CreatedOnce
//     generates only while the ExternalSecret has never synced;
//     creationPolicy Orphan gives the Secret no owner reference, so deleting
//     the ExternalSecret leaves it; target.immutable makes the API server
//     refuse any change to its data. A re-created ExternalSecret finds the
//     Secret, and ESO, seeing an immutable target, leaves its data alone
//     and reports it synced.
//   - Both resources carry argocd.argoproj.io/sync-options
//     Prune=false,Delete=false, so a prune, a rename or a deleted Application
//     never deletes them in the first place.
//   - Argo CD's health check for ExternalSecret (components/argocd) reports
//     Healthy for one refused only because its target is immutable, so such
//     a refusal does not hold up a rebuild. ESO 2.14 refuses only one that
//     would change an immutable Secret's data, such as one re-created
//     without target.immutable; every other error is Degraded.
//
// To rotate, first make sure no pod on any node names the Secret: scale its
// workloads to 0 and delete finished Job pods, and wait for the pods to be
// gone. The kubelet does not watch an immutable Secret; it keeps the copy it
// fetched for as long as any pod on the node names it, and gives that copy,
// the old value, to every new pod there. Then delete the Secret by hand, then
// the ExternalSecret: an ExternalSecret that has synced never writes again,
// even with its Secret gone, but the one Argo CD re-creates has not. Then
// start the workloads again (README.md, External Secrets).
#GeneratedSecret: {
	// name is the Secret's, the ExternalSecret's and the generator's.
	name: string
	// namespace is where all three live.
	namespace: string
	// username, if set, is the login's fixed username, and the Secret is
	// kubernetes.io/basic-auth (above).
	username?: string

	// generator is the generator resource the ExternalSecret reads, a
	// namespaced kind from generators.external-secrets.io. spec is the
	// kind's spec, from its CRD in the external-secrets component's chart.
	generator: {
		// #GeneratorKinds is in resources.cue, beside the entries that let
		// each kind render.
		kind: *"Password" | or(#GeneratorKinds)
		spec: {...}

		// A Password is 32 characters from letters and digits, about 187
		// bits, with no symbols, so it needs no quoting in a URI, a
		// connection string or a shell. The three fields the CRD requires
		// are always set.
		if kind == "Password" {
			spec: {
				length:      int | *32
				allowRepeat: bool | *true
				noUpper:     bool | *false
				symbols:     int | *0
			}
		}
	}

	// The template reads the generator's password key, so with a username
	// the generator is a Password with no other keys.
	if username != _|_ {
		generator: {
			kind: "Password"
			spec: secretKeys?: ["password"]
		}
	}

	let Name = name
	let Namespace = namespace
	let Generator = generator
	let Username = username
	let Login = username != _|_
	let Metadata = {
		name:      Name
		namespace: Namespace
		annotations: "argocd.argoproj.io/sync-options": "Prune=false,Delete=false"
	}

	resources: #Resources & {
		(Generator.kind): (Name): {
			apiVersion: "generators.external-secrets.io/v1alpha1"
			kind:       Generator.kind
			metadata:   Metadata
			spec:       Generator.spec
		}

		ExternalSecret: (Name): {
			metadata: Metadata
			spec: {
				refreshPolicy: "CreatedOnce"
				target: {
					name:           Name
					creationPolicy: "Orphan"
					immutable:      true
					// The template replaces the generator's output with
					// the Secret's whole data: the username as written,
					// and the generated password.
					if Login {
						template: {
							type:          "kubernetes.io/basic-auth"
							engineVersion: "v2"
							mergePolicy:   "Replace"
							data: {
								username: Username
								password: "{{ .password }}"
							}
						}
					}
				}
				dataFrom: [{
					sourceRef: generatorRef: {
						apiVersion: "generators.external-secrets.io/v1alpha1"
						kind:       Generator.kind
						name:       Name
					}
				}]
			}
		}
	}
}
