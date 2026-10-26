package holos

import "strings"

// Argo CD syncs the platform from the deploy/ tree of holos-run/distro, this
// component included, once it has been applied by hand (README.md,
// "Bootstrap Argo CD"). argocd-apps holds what it syncs: the AppProject and
// an Application per component.
//
// Chart 10.11.6, the latest stable of argo-helm's argo-cd chart, ships Argo
// CD v3.5.6, the latest release. The images are pinned by digest (the tag is
// kept for the reader). quay.io/argoproj and ecr-public.aws.com allow
// anonymous pulls.
ArgoCDChartVersion: "10.11.6"
ArgoCDVersion:      "v3.5.6"

let ArgoCDImage = "\(ArgoCDVersion)@sha256:8e5cc5bb008df8a09dba439462e58c94c55b7735888d3ebde0c25fc05e4e5335"

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: ArgoCD.namespace
	chart: {
		name:    "argo-cd"
		version: ArgoCDChartVersion
		release: "argocd"
		repository: {
			name: "argo"
			url:  "https://argoproj.github.io/argo-helm"
		}
	}

	// The chart makes Redis's password with a pre-install hook Job that runs
	// `argocd admin redis-initial-password`, which creates Secret
	// argocd-redis in the cluster if it is missing. Without the hook nothing
	// creates the Secret and Redis does not start; rendering the password
	// would put a new one into deploy/ on every render. Argo CD runs the Job
	// and its RBAC as PreSync hooks; applied by hand they run once.
	enableHooks: true

	values: {
		// The hostname the server will have behind the ingress gateway. Until
		// the gateway exists Argo CD is reached with a port-forward; the name
		// is only the URL Argo CD reports for itself.
		global: domain: "argocd.\(Cluster.name).\(Cluster.site.privateDomain)"

		controller: image: tag:      ArgoCDImage
		server: image: tag:          ArgoCDImage
		repoServer: image: tag:      ArgoCDImage
		applicationSet: image: tag:  ArgoCDImage
		notifications: image: tag:   ArgoCDImage
		redisSecretInit: image: tag: ArgoCDImage
		redis: image: tag:           "8.6.4-alpine@sha256:2cc044fc5a07c9b701f8f1255a309ae9ad7856e694ac03513bf3648c01e40763"

		// Login is the local admin, whose initial password the server
		// generates into Secret argocd-initial-admin-secret, until Keycloak
		// gives Argo CD an OIDC client. No Dex.
		dex: enabled: false

		configs: {
			cm: {
				"admin.enabled": true

				// GitHub cannot reach the garage to deliver a webhook
				// (interview Q38), so Argo CD polls: every Application checks
				// main's head every 30 seconds and a merge syncs in under a
				// minute. No jitter: a dozen Applications on one repository
				// are no load worth spreading.
				"timeout.reconciliation":        "30s"
				"timeout.reconciliation.jitter": "0s"

				// The Argo CD 3 default, stated. Label tracking would write
				// application.instanceLabelKey (argocd.argoproj.io/instance)
				// onto every object, and an operator that copies its owner's
				// labels onto the objects it creates would then make Argo CD
				// count those as its own, out of sync and to be pruned. The
				// tracking-id annotation names the object itself, so a copy
				// does not match.
				"application.resourceTrackingMethod": "annotation"

				// An Application reports the health of what it syncs: Missing
				// until its objects exist, then Healthy once they are. It is
				// health, not sync status: a component whose last sync failed
				// but whose objects are healthy counts as Healthy. Argo CD
				// dropped this check for Applications in 1.8; without it the
				// root Application, when it first creates the Applications
				// wave by wave (argocd-apps), would not wait for one component
				// before creating the next.
				"resource.customizations.health.argoproj.io_Application": """
					hs = {}
					hs.status = "Progressing"
					hs.message = ""
					if obj.status ~= nil then
					  if obj.status.health ~= nil then
					    hs.status = obj.status.health.status
					    if obj.status.health.message ~= nil then
					      hs.message = obj.status.health.message
					    end
					  end
					end
					return hs
					"""
			}

			// Diff against the API server's dry run of a server-side apply,
			// not against the manifest: fields another field manager owns,
			// such as the caBundle cert-manager's cainjector writes into
			// webhook configurations, are then not differences.
			params: "controller.diff.server.side": "true"

			// The keys that sign main's commits (ArgoCD.signingKeys), in Argo
			// CD's keyring, so the platform AppProject can require them.
			gpg: keys: {
				for ID, K in ArgoCD.signingKeys {
					(ID): strings.TrimSpace(K.publicKey)
				}
			}
		}
	}

	resources: Namespace: (ArgoCD.namespace): _
}).artifact]
