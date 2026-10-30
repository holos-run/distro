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

				// The health of a component's Application, as the root
				// Application sees it when it creates them wave by wave
				// (argocd-apps). Argo CD dropped its check for Applications in
				// 1.8. A sync (v3.5.6, gitops-engine/pkg/sync/sync_context.go,
				// Sync) holds a wave while an object in it is anything but
				// Healthy or Degraded: Healthy starts the next wave, and
				// Degraded fails the sync, which the root's retry starts over.
				// An Application's own health counts only the objects that
				// exist (controller/health.go, setApplicationHealth), so one
				// whose sync has created only its Namespace is Healthy. Passed
				// on as it is, that let the root create the next component
				// seconds after quay and after substrate at the 2026-10-30
				// rebuild. So the check is Healthy only once the Application
				// is Healthy and Synced to the source its spec names now,
				// not to one an earlier comparison saw; the root's revision is
				// out of a health check's sight. Otherwise:
				//
				// - No status yet, or a sync asked for or running, retries
				//   included: Progressing, whatever the health. A component
				//   still retrying may come good, and failing the root for it
				//   would spend the root's own retries.
				// - Degraded once its sync has ended: Degraded, so a broken
				//   component shows and the root's sync fails and retries.
				// - OutOfSync after a sync that failed: Degraded. An automated
				//   sync does not retry a revision it failed on, so it gets no
				//   further by itself.
				// - Anything else (Missing, Progressing, Suspended, Unknown,
				//   OutOfSync, or a comparison of an earlier spec):
				//   Progressing, so the root waits.
				//
				// The source comparison is by the fields that say what is
				// synced: repoURL, path, targetRevision, chart and ref, absent
				// counting as empty. A whole-object comparison never matches
				// for some Applications: comparedTo is the spec's Go round
				// trip, which drops zero values the stored spec keeps and
				// writes an empty source for a multi-source one, and such a
				// child would hold the root forever. A source hydrator's
				// Application has no source of its own to compare. Argo CD's
				// Lua has no string library, so only equality and
				// concatenation.
				"resource.customizations.health.argoproj.io_Application": """
					local hs = {}
					local function field(s, k)
					  if s == nil or s[k] == nil then
					    return ""
					  end
					  return s[k]
					end
					local function sameSource(a, b)
					  for _, k in ipairs({"repoURL", "path", "targetRevision", "chart", "ref"}) do
					    if field(a, k) ~= field(b, k) then
					      return false
					    end
					  end
					  return true
					end
					local function current(spec, compared)
					  if spec.sourceHydrator ~= nil then
					    return true
					  end
					  if spec.sources ~= nil and #spec.sources > 0 then
					    local sources = compared.sources or {}
					    if #sources ~= #spec.sources then
					      return false
					    end
					    for i, source in ipairs(spec.sources) do
					      if not sameSource(source, sources[i]) then
					        return false
					      end
					    end
					    return true
					  end
					  return sameSource(spec.source, compared.source)
					end
					if obj.status == nil or obj.status.health == nil or obj.status.sync == nil then
					  hs.status = "Progressing"
					  hs.message = "Waiting for the application controller"
					  return hs
					end
					local health = obj.status.health.status or "Unknown"
					local sync = obj.status.sync.status or "Unknown"
					local op = obj.status.operationState
					local state = health .. ", " .. sync
					if obj.operation ~= nil then
					  hs.status = "Progressing"
					  hs.message = state .. ", sync requested"
					  return hs
					end
					if op ~= nil and op.phase == "Running" then
					  hs.status = "Progressing"
					  hs.message = state .. ", syncing: " .. (op.message or "")
					  return hs
					end
					if health == "Degraded" then
					  hs.status = "Degraded"
					  hs.message = obj.status.health.message or state
					  return hs
					end
					if sync ~= "Synced" and op ~= nil and (op.phase == "Failed" or op.phase == "Error") then
					  hs.status = "Degraded"
					  hs.message = state .. ", sync failed: " .. (op.message or "")
					  return hs
					end
					local compared = obj.status.sync.comparedTo or {}
					if health == "Healthy" and sync == "Synced" and current(obj.spec, compared) then
					  hs.status = "Healthy"
					  hs.message = ""
					  return hs
					end
					hs.status = "Progressing"
					hs.message = state
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

				// approver-policy's CertificateRequestPolicy, which Argo CD has
				// no check for: Healthy once its Ready condition is True,
				// Degraded while it is False, so a policy approver-policy
				// cannot use, and skips, shows on private-ca's Application
				// rather than as requests left unprocessed. Progressing until
				// approver-policy first reports.
				"resource.customizations.health.policy.cert-manager.io_CertificateRequestPolicy": """
					local hs = {}
					if obj.status ~= nil and obj.status.conditions ~= nil then
					  for i, condition in ipairs(obj.status.conditions) do
					    if condition.type == "Ready" and condition.status == "True" then
					      hs.status = "Healthy"
					      hs.message = condition.message
					      return hs
					    end
					    if condition.type == "Ready" and condition.status == "False" then
					      hs.status = "Degraded"
					      hs.message = condition.message
					      return hs
					    end
					  end
					end
					hs.status = "Progressing"
					hs.message = "Waiting for approver-policy"
					return hs
					"""

				// ToolHive's MCPServer (components/toolhive), which Argo CD
				// has no check for: Healthy once the operator has seen the
				// current spec and reports it Ready, which it does once the
				// proxy runner is ready; Degraded when it reports Failed, such
				// as for a missing MCPOIDCConfig or an invalid Cedar policy;
				// Suspended when scaled to zero; otherwise Progressing, so
				// the root waits for the server rather than for the object.
				"resource.customizations.health.toolhive.stacklok.dev_MCPServer": """
					local hs = {}
					if obj.status == nil or obj.status.observedGeneration == nil or obj.status.observedGeneration ~= obj.metadata.generation then
					  hs.status = "Progressing"
					  hs.message = "Waiting for the ToolHive operator"
					  return hs
					end
					local phase = obj.status.phase
					hs.message = obj.status.message or phase or ""
					if phase == "Ready" then
					  hs.status = "Healthy"
					elseif phase == "Failed" then
					  hs.status = "Degraded"
					elseif phase == "Stopped" then
					  hs.status = "Suspended"
					else
					  hs.status = "Progressing"
					end
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
				"policy.csv": "g, \(Keycloak.groups.owners.path), role:admin\n"
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

			// The repo server does not fetch git submodules. deploy/ is
			// rendered before it is committed, and Argo CD syncs only plain
			// manifests from it; holos/vendor/substrate, the Substrate fork,
			// is a submodule only so a render reads the fork's install tree
			// at its pin. Fetching it would cost every refresh a clone of a
			// second repository that nothing synced reads.
			params: "reposerver.enable.git.submodule": "false"

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
