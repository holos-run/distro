package holos

import (
	"encoding/yaml"
	"strings"
)

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
		// The server's hostname on the ingress gateway (ingress-gateway
		// renders its HTTPRoute), and the URL Argo CD reports for itself.
		global: domain: IngressGateway.hosts.argocd

		controller: image: tag:      ArgoCDImage
		server: image: tag:          ArgoCDImage
		repoServer: image: tag:      ArgoCDImage
		applicationSet: image: tag:  ArgoCDImage
		notifications: image: tag:   ArgoCDImage
		redisSecretInit: image: tag: ArgoCDImage
		redis: image: tag:           "8.6.4-alpine@sha256:2cc044fc5a07c9b701f8f1255a309ae9ad7856e694ac03513bf3648c01e40763"

		// Login is through Keycloak, the realm's argocd client, and the
		// local admin, whose initial password the server generates into
		// Secret argocd-initial-admin-secret, stays until the milestone's
		// login through Keycloak has passed. No Dex: Argo CD talks to
		// Keycloak itself (oidc.config below).
		dex: enabled: false

		// The server checks Keycloak's certificate, the private CA's, when
		// it fetches the issuer's discovery document and keys and when it
		// redeems a code from the CLI. Rather than oidc.config's rootCA,
		// which would put the root, minted in the cluster, into git, the
		// server trusts the private-ca ConfigMap trust-manager keeps in
		// the namespace, beside the image's public roots: Go reads every
		// file in each SSL_CERT_DIR directory, after its bundle file. With
		// rootCA unset, Argo CD's OIDC client uses that system pool. Go
		// reads the pool once, at start. The mount is optional because
		// argocd syncs in an early wave and trust-manager makes the
		// ConfigMap later: a required mount would hold the server in
		// ContainerCreating, and the root, waiting for argocd to report
		// Healthy, would never reach trust-manager. On a rebuilt cluster
		// the server is therefore restarted once private-ca-bundle is
		// Healthy (README, Bootstrap Argo CD).
		server: {
			volumes: [{name: "private-ca", configMap: {name: PrivateCA.bundle, optional: true}}]
			volumeMounts: [{name: "private-ca", mountPath: "/etc/ssl/private-ca", readOnly: true}]
			env: [{name: "SSL_CERT_DIR", value: "/etc/ssl/certs:/etc/ssl/private-ca"}]
		}

		configs: {
			cm: {
				"admin.enabled": true

				// Keycloak's realm holos, through the public argocd client
				// with PKCE, S256 (interview Q51): the UI and the CLI keep
				// no secret, so there is none here. Its groups scope is a
				// realm default, but a client may still ask for it by name;
				// it puts the user's groups, by full path, in the groups
				// claim (Q6), which the policy below and scopes read. url,
				// the base of the redirects, is the chart's, from
				// global.domain.
				"oidc.config": yaml.Marshal({
					name:                     "Keycloak"
					issuer:                   Keycloak.issuer
					clientID:                 Keycloak.clients.argocd
					enablePKCEAuthentication: true
					requestedScopes: ["openid", "profile", "email", Keycloak.groupsClaim]
				})

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

				// Argo CD's built-in check for ExternalSecret (v3.5.6,
				// resource_customizations/external-secrets.io/ExternalSecret),
				// which the first Ready condition decides, with one
				// exception: the Ready=False ESO 2.14 sets only because the
				// target Secret is immutable and the ExternalSecret would
				// change its data is Healthy. A generated secret
				// (#GeneratedSecret) is immutable on purpose, and an
				// ExternalSecret re-created onto it must not hold up a sync
				// or a rebuild for keeping it. The match is the reason,
				// SecretImmutable, and the whole message ESO writes for it
				// (msgErrorUpdateImmutable, then errUpdate wrapping
				// ErrSecretImmutable) for this ExternalSecret's target, built
				// by concatenation: Argo CD's Lua has no string library.
				// Every other Ready=False is Degraded, as before.
				"resource.customizations.health.external-secrets.io_ExternalSecret": """
					local hs = {}
					local target = obj.metadata.name
					if obj.spec ~= nil and obj.spec.target ~= nil and obj.spec.target.name ~= nil and obj.spec.target.name ~= "" then
					  target = obj.spec.target.name
					end
					local immutable = "could not update secret, target is immutable: unable to update secret " .. target .. ": secret is immutable"
					if obj.status ~= nil then
					  if obj.status.conditions ~= nil then
					    for i, condition in ipairs(obj.status.conditions) do
					      if condition.type == "Ready" and condition.status == "False" then
					        if condition.reason == "SecretImmutable" and condition.message == immutable then
					          hs.status = "Healthy"
					          hs.message = "Secret " .. target .. " is immutable and kept as it is"
					          return hs
					        end
					        hs.status = "Degraded"
					        hs.message = condition.message
					        return hs
					      end
					      if condition.type == "Ready" and condition.status == "True" then
					        hs.status = "Healthy"
					        hs.message = condition.message
					        return hs
					      end
					    end
					  end
					end
					hs.status = "Progressing"
					hs.message = "Waiting for ExternalSecret"
					return hs
					"""
			}

			// /platform/owners, the group the keycloak-realm component makes
			// and puts jeff in, is admin; nobody else from Keycloak gets a
			// role (policy.default stays empty). A group is matched by the
			// full path the groups claim carries, leading slash and all.
			// scopes, the claims a policy line's subject is matched
			// against, is the chart's default, [groups], stated.
			rbac: {
				"policy.csv": "g, /platform/owners, role:admin\n"
				scopes:       "[\(Keycloak.groupsClaim)]"
			}

			// Diff against the API server's dry run of a server-side apply,
			// not against the manifest: fields another field manager owns,
			// such as the caBundle cert-manager's cainjector writes into
			// webhook configurations, are then not differences.
			params: "controller.diff.server.side": "true"

			// The gateway terminates TLS with the private CA's wildcard and
			// sends plain HTTP to the server, so the server serves no TLS of
			// its own. It still answers on its Service's port 443, unencrypted.
			params: "server.insecure": true

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
