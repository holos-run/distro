package holos

// #AteAPIJob is a Job that calls Substrate's API with grpcurl as the global
// owner, the one way anything in git makes an object in Substrate's database:
// the claim's atespace Job (components/project) and a product's (the Planboard
// actor's, components/product-planboard). What a Job does is its script, and
// the rest is here because it is what makes it safe to run.
//
// In ate-system, under the ate-client ksa, not in the project's namespace.
// can_create_atespace is global owner's alone (Substrate's model.fga has no
// narrower role), and the claim's owner is admin in the project's namespace,
// who reads every Secret there and may run a pod under any ServiceAccount
// there: a token the Job held in that namespace would hand each project's owner
// the whole install. A claim's owner has no access to ate-system, and nothing
// is stored: the token is the pod's own, projected, for the API's audience, for
// the ten minutes that are the shortest the API server issues.
//
// An Argo CD Sync hook, so it runs on every sync, deleted and re-created each
// time (BeforeHookCreation), since a Job's template cannot change in place. It
// holds no password, so the finished Job stays, for its log. It runs alongside
// the Application's other objects and depends on none of them.
//
// A failure fails the Application's sync, after those objects are applied, and
// Argo CD retries the sync (components/argocd-apps), each time with a new Job,
// up to its limit, and then stops. Nothing reports it after that: a hook is
// outside an Application's health and its comparison, so the Application reads
// Synced and Healthy with operationState.phase Failed, the root's health check
// passes it, and an automated sync does not run it again. So the limits here
// are short, as the API server is up by this wave, and the check and the
// recovery, a sync by hand, are in README.md, Checking a project.
#AteAPIJob: {
	// labels mark the Job and its pod as their claim's. The substrate
	// component's NetworkPolicy admits the pod to the API server by the labels
	// added here.
	labels: {[string]: string}
	// script is what the pod runs, which finds its credential in
	// Substrate.atespaceSetup.dir.
	script: string
	// env is the script's, for anything that should not be spliced into its
	// text.
	env: [...{name: string, value: string}]

	let PodLabels = labels & Substrate.atespaceSetup.labels

	job: {
		metadata: {
			namespace: Substrate.namespace
			"labels":  PodLabels
			annotations: {
				"argocd.argoproj.io/hook":               "Sync"
				"argocd.argoproj.io/hook-delete-policy": "BeforeHookCreation"
			}
		}
		spec: {
			// A failing call is retried with the kubelet's back-off, as
			// when the claim's first sync beats substrate's to the
			// NetworkPolicy, on the limits above.
			backoffLimit:          3
			activeDeadlineSeconds: 300
			template: {
				metadata: "labels": PodLabels
				spec: {
					restartPolicy:                "OnFailure"
					serviceAccountName:           Substrate.client.serviceAccount
					automountServiceAccountToken: false
					// The image's grpcurl user, by number, which
					// runAsNonRoot can check.
					securityContext: {
						runAsNonRoot: true
						runAsUser:    100
						runAsGroup:   101
						seccompProfile: type: "RuntimeDefault"
					}
					containers: [{
						name:  "setup"
						image: Substrate.atespaceSetup.image
						command: ["/bin/sh", "-c", script]
						if len(env) > 0 {"env": env}
						volumeMounts: [{name: "api", mountPath: Substrate.atespaceSetup.dir, readOnly: true}]
						resources: {
							requests: {cpu: "10m", memory: "32Mi"}
							limits: memory: "64Mi"
						}
						securityContext: {
							allowPrivilegeEscalation: false
							readOnlyRootFilesystem:   true
							capabilities: drop: ["ALL"]
						}
					}]
					volumes: [{
						name: "api"
						projected: sources: [
							{
								serviceAccountToken: {
									audience:          Substrate.api.audience
									expirationSeconds: 600
									path:              "token"
								}
							},
							{
								clusterTrustBundle: {
									signerName: Substrate.signers.serviceDNS
									labelSelector: matchLabels: "podcert.ate.dev/canarying": "live"
									path: "ca.pem"
								}
							},
						]
					}]
				}
			}
		}
	}
}
