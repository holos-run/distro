package holos

import "list"

// The platform AppProject and an Argo CD Application for every component this
// cluster takes (clusterRegistry, registry.cue), each syncing the
// component's directory in deploy/ from main. This component's own
// Application is among them: it is the root Application, which syncs the
// directory these are rendered to, so an Application rendered for a new
// component is created by Argo CD from the merge alone, and so is a change to
// any of them. It is applied by hand once (README.md, "Bootstrap Argo CD").
//
// holos v1alpha6 has no Argo CD support of its own: its author schemas'
// ArgoConfig ended with v1alpha4, and the documented v1alpha5 pattern mixes
// an Application artifact into each BuildPlan. Rendering them all here, from
// the registry, keeps the components unchanged and puts the sync order and
// sync options next to the order's reasons.

// SyncOptions apply to every Application. Server-side apply, because a
// client-side apply's last-applied annotation cannot hold the Gateway API's
// 429KB HTTPRoute CRD, and because the hand applies are server-side too.
// Argo CD applies as field manager argocd-controller and forces conflicts,
// so it takes over objects applied by hand with the same manifests without
// a conflict (README.md, "Taking objects over from the hand applies").
let SyncOptions = ["ServerSideApply=true"]

// BoundClaims are the claims with a binding on this cluster (clusterBindings,
// collections.cue). Read here, where the cluster is known, and not in
// #ProjectRegistrations, which reads projects alone because #Cluster.components
// reads it.
let BoundClaims = {for B in clusterBindings[Cluster.name] {(B.project): true}}

// OwnerSyncPolicy is what a bound claim's project-<claim> leaves to the claim's
// owners: the automated block of the claim's own Application, <claim>, which
// Argo CD's Sync Policy panel writes whole when an owner checks or unchecks
// auto-sync, prune or self-heal (components/project, OwnerPolicies). Without
// it, project-<claim>'s self-heal would put selfHeal: true back within
// minutes; with it, the owner can leave self-heal off while they edit the
// claim's policy live, and turn it on again to return the policy to the
// render (README.md, Editing a bound claim's policy live). ignoreDifferences
// alone keeps the field from being a difference, which self-heal never
// syncs; RespectIgnoreDifferences=true also keeps any sync of project-<claim>,
// such as one a commit changing its render starts, from applying the render's value
// over the owner's: Argo CD copies the live value of an ignored field into
// what it applies (v3.5.7, controller/sync.go, normalizeTargetResources).
//
// Only automated, not the whole of syncPolicy: syncOptions, such as
// ServerSideApply=true, and retry stay the render's, since working on the
// policy needs neither changed. A rebuild renders the Application afresh, so every claim
// starts enforced, and a change to automated in the render no longer reaches
// a bound claim's Application that exists already. Only where the claim is
// bound, as the owner role is, so a cluster with no binding renders as it did
// (Second_Cluster Q6).
let OwnerSyncPolicy = {
	project: string
	ignoreDifferences: [{
		group:     "argoproj.io"
		kind:      "Application"
		name:      project
		namespace: ArgoCD.namespace
		jsonPointers: ["/spec/syncPolicy/automated"]
	}]
	syncOptions: ["RespectIgnoreDifferences=true"]
}

holos: spec: artifacts: [(#ResourcesArtifact & {
	resources: {
		// The project every platform Application belongs to. Argo CD syncs a
		// commit only if it is signed by one of signatureKeys, whose public
		// keys the argocd component puts in Argo CD's keyring. Wave -1, so the
		// root Application creates it before the Applications that name it.
		AppProject: (ArgoCD.project): {
			metadata: {
				namespace: ArgoCD.namespace
				annotations: "argocd.argoproj.io/sync-wave": "-1"
			}
			spec: {
				description: "The \(Brand.name) platform's components, synced from \(ArgoCD.repoURL)"
				sourceRepos: [ArgoCD.repoURL]
				destinations: [{
					server:    "https://kubernetes.default.svc"
					namespace: "*"
				}]
				clusterResourceWhitelist: [{group: "*", kind: "*"}]
				signatureKeys: [for K in ArgoCD.signingKeys {keyID: K.id}]
			}
		}

		// The sync wave is the index in this cluster's own list, so an entry
		// it does not take can never move its waves. Nothing else reads the
		// index.
		for WAVE, C in clusterRegistry[Cluster.name] {
			// The owner's part of a bound claim's own Application, on that
			// claim's project-<claim> (OwnerSyncPolicy), and nothing on
			// every other entry.
			let Owner = [
				if C.component == "project"
				if BoundClaims[C.parameters.project] != _|_ {
					OwnerSyncPolicy & {project: C.parameters.project}
				},
			]
			let Ignore = list.Concat([C.ignoreDifferences, for O in Owner {O.ignoreDifferences}])
			let Options = list.Concat([SyncOptions, C.syncOptions, for O in Owner {O.syncOptions}])

			// No resources-finalizer: deleting an Application, or the root
			// pruning one the platform stopped rendering, leaves the
			// component's objects in place rather than deleting them.
			Application: (C.name): {
				metadata: {
					namespace: ArgoCD.namespace
					annotations: "argocd.argoproj.io/sync-wave": "\(WAVE)"
				}
				spec: {
					project: ArgoCD.project
					destination: server: "https://kubernetes.default.svc"
					source: {
						repoURL:        ArgoCD.repoURL
						targetRevision: ArgoCD.targetRevision
						// The component's OutputDir (components/component.cue).
						path: "holos/deploy/clusters/\(Cluster.name)/components/\(C.name)"
					}
					if len(Ignore) > 0 {
						ignoreDifferences: Ignore
					}
					syncPolicy: {
						// Every commit on main is synced as it is seen, and a
						// change made by hand is reverted. Pruning deletes only
						// objects carrying this Application's tracking
						// annotation, so taking over objects applied by hand
						// deletes nothing.
						automated: {
							prune:    true
							selfHeal: true
						}
						syncOptions: Options
						// An automated sync is not retried for a commit it
						// failed on, and after bootstrap the components sync in
						// parallel, so a component whose dependency is not
						// ready yet (cert-manager's CRDs and webhook for
						// private-ca, the Bundle CRD for private-ca-bundle, a CRD
						// the Cilium operator registers when it starts) retries
						// until it is: 10 attempts, 5s doubling to 3m, about 17
						// minutes, enough for a cold cluster's image pulls and
						// controller starts several times over. Bounded,
						// because a retrying sync holds its commit: a fix merged
						// meanwhile waits for it to end, or for `argocd app
						// terminate-op`.
						retry: {
							limit: 10
							backoff: {
								duration:    "5s"
								factor:      2
								maxDuration: "3m"
							}
						}
					}
				}
			}
		}
	}
}).artifact]
