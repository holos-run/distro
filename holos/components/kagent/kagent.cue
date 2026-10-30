@extern(embed)

package holos

// kagent is kagent on Agent Substrate (interview Q26), from the holos-run
// fork's kagent chart (Kagent, kagent.cue), at https://kagent.bank.internal
// behind a Keycloak login. kagent-crds, before it, holds its CRDs.
//
// The chart runs the controller, the UI (nginx, which serves the app and
// proxies the API to the controller), the read-only kagent-tools MCP server
// and oauth2-proxy. The controller keeps its state in kagent's own schema and
// roles in Substrate's database, substrate-db, and runs every agent as a
// Substrate actor in the kagent atespace, on the platform's gVisor pool,
// which it selects by the pool's two kagent.dev labels, through a
// placeholder pool of the same name here. It dials the API
// server and the router over mutual TLS with its pod identity certificate,
// whose SPIFFE ID the substrate component already trusts (Kagent.controller).
//
// Beside the chart, in CUE:
//
//   - the namespace, with ate.dev/api-access, which the API server's
//     NetworkPolicy admits, and outside the mesh, so the NetworkPolicies
//     hold at the application ports;
//   - the database: the role Job, a Sync hook in Substrate's namespace, its
//     SQL and its generated passwords there, the NetworkPolicy that admits
//     the Job and the controller to the database, and the two connection
//     strings here;
//   - the login: the Keycloak Client, its ReferenceGrant, the generated
//     cookie secret and the Secret oauth2-proxy reads;
//   - the Anthropic key's copy from the platform secret anthropic-api-key,
//     and the credential provider's grant to read it;
//   - the NetworkPolicies and the route.
//
// The controller decodes bearer tokens without verifying them and has no
// authorizer for users, so oauth2-proxy is the only way in and the network
// keeps everyone else out (Isolation, below).
//
// Every kind's CRD comes from an earlier component: ModelConfig and
// RemoteMCPServer from kagent-crds, WorkerPool from substrate, Client and the security.holos.run
// ReferenceGrant from holos-controller, ExternalSecret, SecretStore and
// Password from external-secrets, HTTPRoute from gateway-api.

let NS = Kagent.namespace
let K = Kagent
let S = Substrate
let DB = S.database
let R = K.database

// The pods' labels, by the chart's selectors, which the NetworkPolicies
// select on.
let Pods = {
	let Instance = {
		"app.kubernetes.io/name":     "kagent"
		"app.kubernetes.io/instance": K.release
	}
	controller: Instance & {"app.kubernetes.io/component": "controller"}
	ui: Instance & {"app.kubernetes.io/component": "ui"}
	proxy: {
		"app.kubernetes.io/name":     "oauth2-proxy"
		"app.kubernetes.io/instance": K.release
	}
	tools: {
		"app.kubernetes.io/name":     "kagent-tools"
		"app.kubernetes.io/instance": K.release
	}
	setup: "app.kubernetes.io/name": "kagent-db-setup"
}

// Secrets made here. users holds the two login users' passwords, one key
// each named for its user, in Substrate's namespace beside the database and
// its superuser, which the role Job reads them with; the connection strings
// here are made from it through the store users. cookie is oauth2-proxy's
// cookie secret, and oidc the Secret oauth2-proxy reads its three keys from.
let Secrets = {
	users:        "kagent-db-users"
	owner:        "kagent-postgres-owner"
	readwrite:    "kagent-postgres-readwrite"
	cookie:       "kagent-oauth2-proxy-cookie"
	oidc:         "kagent-oidc"
	anthropic:    "kagent-anthropic"
	anthropicKey: "ANTHROPIC_API_KEY"
	// platform is the platform secret, in holos-prj-platform, written by
	// hand through the Secrets Manager.
	platform: "anthropic-api-key"
}

// modelKeys are the Secrets here the credential provider may read, the model
// keys agents' egress may carry: kagent-anthropic alone.
let modelKeys = [Secrets.anthropic]

// CAMount is where the private-ca ConfigMap is mounted in the controller and
// in oauth2-proxy.
let CAMount = "/etc/private-ca"
let CACert = "\(CAMount)/\(PrivateCA.bundleKey)"

// DSN is a login user's connection string, verify-full against the private
// root, as Substrate's are. The password is an External Secrets template
// variable; the generated passwords are letters and digits.
let DSN = {
	user:     string
	password: string
	out:      "postgresql://\(user):{{ .\(password) }}@\(DB.host):\(DB.port)/\(DB.database)?sslmode=verify-full&sslrootcert=\(CACert)"
}

// SetupSQL is kagent's setup.sql, go/core/pkg/postgressetup/setup.sql at the
// fork's commit, copied unmodified beside this file. Re-copy it on a bump.
_setupSQL: _ @embed(file=setup.sql, type=text)

// SetupScript runs it as postgressetup's Script does: in one transaction,
// with the role names, schema and passwords as psql variables
// (Config.PSQLArgs), once the database answers. Every statement converges.
let SetupScript = """
	set -eu
	until pg_isready --quiet; do
	  echo "waiting for $PGHOST"
	  sleep 5
	done
	exec psql --no-psqlrc --set=ON_ERROR_STOP=1 --single-transaction \\
	  --set=kagent_schema=\(R.schema) \\
	  --set=kagent_owner_role=\(R.owner.role) \\
	  --set=kagent_owner_user=\(R.owner.user) \\
	  --set=kagent_owner_password="$OWNER_PASSWORD" \\
	  --set=kagent_readwrite_role=\(R.readwrite.role) \\
	  --set=kagent_readwrite_user=\(R.readwrite.user) \\
	  --set=kagent_readwrite_password="$READWRITE_PASSWORD" \\
	  --file=/sql/setup.sql
	"""

// Restricted is the container security context of the role Job.
let Restricted = {
	allowPrivilegeEscalation: false
	readOnlyRootFilesystem:   true
	capabilities: drop: ["ALL"]
}

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: NS
	chart: {
		name:    K.charts.kagent.name
		version: K.version
		release: K.release
	}
	values:    Values
	resources: _Resources
}).artifact]

// Values are the chart's. Every image is pinned by digest: the chart puts a
// tag with an @digest after the colon as it is.
let Values = {
	controller: {
		image: {
			repository: "holos-run/kagent/controller"
			tag:        "\(K.version)@\(K.digests.controller)"
		}
		// The pod identity certificate and the servicedns trust bundle,
		// which set substrate.clientCertFile and substrate.caFile: the
		// controller's mutual TLS to the API server and the router.
		substrateClientCertificate: enabled: true
		// The private root, the connection strings' sslrootcert. Not
		// optional: trust-manager comes earlier in the registry.
		volumes: [{name: "private-ca", configMap: name: PrivateCA.bundle}]
		volumeMounts: [{name: "private-ca", mountPath: CAMount, readOnly: true}]
	}

	ui: {
		image: {
			repository: "holos-run/kagent/ui"
			tag:        "\(K.version)@\(K.digests.ui)"
		}
		// The public URL: share links and the push issuer.
		externalUrl: K.url
		// OpenShift's Route, a no-op off OpenShift, and the chart's
		// HTTPRoute, which would point at the UI and bypass the login, are
		// both off; the route is in CUE, to oauth2-proxy.
		route: enabled:     false
		httpRoute: enabled: false
	}

	// Passwords, not client certificates: the chart's clientCertificate
	// option expects the server to trust Substrate's postgres signer, and
	// CloudNativePG keeps its own client CA. The Secrets are the chart's
	// default names, made here.
	database: postgres: {
		ownerConnectionStringSecretRef: {name: Secrets.owner, key: "ownerConnectionString"}
		readWriteConnectionStringSecretRef: {name: Secrets.readwrite, key: "readWriteConnectionString"}
		clientCertificate: enabled: false
	}

	config: {
		harnessImages: K.harnessImages
		sandboxes: guestImage: K.guestImage

		// trusted-proxy: the controller takes the user from the bearer ID
		// token oauth2-proxy forwards, by its email claim, without
		// verifying it, which oauth2-proxy has done (Isolation, below).
		server: auth: {
			mode:        "trusted-proxy"
			userIdClaim: "email"
		}

		database: {
			owner: role:     R.owner.role
			readWrite: role: R.readwrite.role
			schema:        R.schema
			vectorEnabled: false
		}

		// Substrate by its Services' names. The router is mutual TLS on
		// 443; the chart's default is plain HTTP on 80, which the router
		// does not serve. The actor JWT issuer is the IdP's.
		substrate: {
			apiEndpoint:    "dns:///\(S.api.host):443"
			routerUrl:      S.router.url
			actorJwtIssuer: S.issuer
		}
	}

	// The controller's RBAC and its watch, in this namespace alone: Roles
	// here in place of ClusterRoles. It verifies no token and takes the
	// namespace from the request, so cluster-wide its read of every core
	// resource and its writes to core, apps and batch would be anyone's
	// with a login. Agents, Harnesses, ModelConfigs and the placeholder
	// pool are all here. rbac.namespaces, not global.watchNamespaces,
	// which the tool server's subchart would read too and scope its
	// cluster-wide read to this namespace.
	rbac: namespaces: [NS]

	// The platform's gVisor pool, not the chart's: the agents' Harness
	// names it, gvisor, and the actors land on its workers in ate-workers
	// by its two kagent.dev labels. The placeholder WorkerPool below lets
	// the controller find it by name in this namespace.
	substrateWorkerPool: create: false

	// Anthropic, with the chart's model, through Secret kagent-anthropic,
	// which the ExternalSecret below copies. apiKey stays unset, so the
	// chart renders no Secret of its own.
	providers: {
		default: "anthropic"
		anthropic: {
			apiKeySecretRef: Secrets.anthropic
			apiKeySecretKey: Secrets.anthropicKey
		}
	}

	// The tool server reads the cluster and changes nothing: readOnly
	// binds a ClusterRole of get, list and watch, without Secrets, in
	// place of cluster-admin.
	"kagent-tools": {
		tools: {
			image: tag: "0.3.0@sha256:cb89eb76216195a90cac73846b447525b6e6e33e45154d1ded9621bf11340315"
			// The server's own read-only mode, which leaves out every tool
			// that writes, so an agent is not offered tools the role
			// refuses.
			args: ["--read-only"]
		}
		rbac: readOnly: true
	}

	"oauth2-proxy": {
		enabled: true
		image: tag: "v7.15.5@sha256:8498b0d0ef0a7b29686414000a08aee467f02d0299c9ed1e006a8f33fc017916"
		// client-id, client-secret and cookie-secret, from the
		// ExternalSecret below.
		config: existingSecret: Secrets.oidc
		// The chart's lists are replaced whole, so its entries are
		// repeated: the sign-in template's checksum and mount, and the three
		// URLs. Added: the private root, which oauth2-proxy needs to reach
		// Keycloak through the gateway, as the only trust it has.
		extraEnv: [
			{name: "KAGENT_OAUTH2_PROXY_SIGNIN_TEMPLATE_CHECKSUM", value: "{{ include \"kagent.oauth2ProxySignInHTML\" . | sha256sum }}"},
			{name: "OIDC_ISSUER_URL", value: Keycloak.issuer},
			{name: "OIDC_REDIRECT_URL", value: K.callback},
			{name: "UPSTREAM_URL", value: "http://\(K.ui.service):\(K.ui.port)"},
			{name: "SSL_CERT_FILE", value: CACert},
		]
		extraVolumes: [
			{name: "custom-templates", configMap: name: "kagent-oauth2-proxy-templates"},
			{name: "private-ca", configMap: name: PrivateCA.bundle},
		]
		extraVolumeMounts: [
			{name: "custom-templates", mountPath: "/templates", readOnly: true},
			{name: "private-ca", mountPath: CAMount, readOnly: true},
		]
		// The chart's arguments stay, pass-authorization-header among them,
		// which forwards the ID token, and skip-jwt-bearer-tokens, which
		// admits a bearer ID token oauth2-proxy verifies itself: signed by
		// the realm, unexpired, iss the realm's and aud this client, the
		// same checks as its own login's. No extra-jwt-issuers is set, so
		// no other issuer or audience is accepted, a kubectl token
		// included.
		//
		// Not reverse-proxy: with it oauth2-proxy matches skip-auth-route
		// and skip-auth-regex against X-Forwarded-Uri, which the ingress
		// Gateway passes through from the client, so a request for /api/
		// claiming X-Forwarded-Uri /login would skip the login.
		//
		// cookie-refresh: Keycloak's ID token lives five minutes, and the
		// controller refuses an expired one, so oauth2-proxy redeems the
		// session's refresh token for a new ID token on a request once the
		// session is a minute old. The refresh token is the SSO session's,
		// so a login lasts as long as the realm's session.
		extraArgs: "cookie-refresh": "1m"
		resources: {
			requests: {cpu: "10m", memory: "32Mi"}
			limits: memory: "128Mi"
		}
	}
}

_Resources: #Resources & {
	// Baseline, Talos's default, stated: no pod here may run privileged,
	// mount a host path, add capabilities or run unconfined, which every
	// Substrate worker pod does, so the placeholder pool below could not
	// start one even if it were scaled up.
	Namespace: (NS): metadata: labels: {
		"ate.dev/api-access":                 "true"
		"pod-security.kubernetes.io/enforce": "baseline"
	}

	// The placeholder pool. A Harness's workerPoolRef is a
	// LocalObjectReference (go/api/v1alpha3/runtime_types.go), and the
	// controller reads the pool's sandbox class from the WorkerPool of that
	// name in the Harness's own namespace (go/core/internal/translator/
	// compiler.go, and controller/sandbox_collections.go for a
	// SandboxTemplate), reporting WorkerPoolNotFound when there is none.
	// It places the actors only by the two kagent.dev/worker-pool-* labels,
	// which Substrate matches across every worker in the cluster, so they
	// land on the platform pool's workers in ate-workers, whose pool carries
	// the labels (components/substrate). This pool exists to be found: the
	// same name and sandbox class as the platform's, and no workers of its
	// own. replicas is 0, which Argo CD heals back; it carries no
	// kagent.dev labels, so no actor would select a worker of it; and the
	// namespace's baseline Pod Security refuses a worker pod. ate-controller
	// still makes its worker Deployment, at 0, and the ateworker
	// ServiceAccount, unused, which it owns and leaves in place.
	WorkerPool: (S.workerPool.name): {
		metadata: namespace: NS
		spec: {
			replicas:    0
			workerImage: S.images["ateworker-gvisor"]
			sandboxClasses: [{name: S.workerPool.sandboxClass}]
		}
	}

	// The route: every path of the host to oauth2-proxy, which forwards a
	// logged-in request to the UI. Never to the UI or the controller, which
	// would bypass the login. The https listener takes routes from every
	// namespace, so the Gateway is unchanged.
	HTTPRoute: (K.release): {
		metadata: namespace: NS
		spec: {
			parentRefs: [IngressGateway.parentRef]
			hostnames: [K.host]
			rules: [{backendRefs: [{name: K.proxy.service, port: K.proxy.port}]}]
		}
	}

	// The confidential client: standard flow alone, oauth2-proxy's
	// callback, and the secret delivered once to kagent-oidc-client here.
	// It gets the realm's default scopes, which oauth2-proxy asks for by
	// name: openid, profile, email and groups.
	Client: (K.clientId): {
		metadata: namespace: NS
		spec: {
			clientId:    K.clientId
			type:        "confidential"
			description: "kagent"
			instanceRef: HolosController.instance
			redirectUris: [K.callback]
			secretRef: K.oidcSecret
		}
	}

	// The Client names the Instance in keycloak, another namespace, which
	// holos-controller allows only with a ReferenceGrant there.
	ReferenceGrant: "\(K.release)-clients": {
		apiVersion: "security.holos.run/v1alpha1"
		metadata: namespace: HolosController.instance.namespace
		spec: {
			from: [{
				group:     "keycloak.holos.run"
				kind:      "Client"
				namespace: NS
			}]
			to: [{
				group: "keycloak.holos.run"
				kind:  "Instance"
				name:  HolosController.instance.name
			}]
		}
	}

	// oauth2-proxy's three keys, from the Client's secret and the
	// generated cookie secret, through the store oidc. Owner: it follows
	// its sources.
	ExternalSecret: (Secrets.oidc): {
		metadata: namespace: NS
		spec: {
			refreshInterval: "1h"
			secretStoreRef: {kind: "SecretStore", name: Secrets.oidc}
			target: {
				creationPolicy: "Owner"
				template: {
					engineVersion: "v2"
					mergePolicy:   "Replace"
					data: {
						"client-id":     K.clientId
						"client-secret": "{{ .clientSecret }}"
						"cookie-secret": "{{ .cookieSecret }}"
					}
				}
			}
			data: [
				{secretKey: "clientSecret", remoteRef: {key: K.oidcSecret.name, property: K.oidcSecret.key}},
				{secretKey: "cookieSecret", remoteRef: {key: Secrets.cookie, property: "cookie-secret"}},
			]
		}
	}

	// The model key, from the platform secret anthropic-api-key, key
	// ANTHROPIC_API_KEY, which is written by hand through the Secrets
	// Manager (README.md, kagent). Until it is, this reports an error, and
	// it and the kagent Application are Degraded; an agent cannot resolve
	// its model, and the root Application's own sync waits too, since kagent
	// is the last component before it (registry.cue). Owner, as
	// ceph-csi-rbd's key: the platform secret is the truth.
	ExternalSecret: (Secrets.anthropic): {
		metadata: namespace: NS
		spec: {
			refreshInterval: "1h"
			secretStoreRef: {kind: "SecretStore", name: "platform"}
			target: creationPolicy: "Owner"
			data: [{
				secretKey: Secrets.anthropicKey
				remoteRef: {key: Secrets.platform, property: Secrets.anthropicKey}
			}]
		}
	}

	// The credential provider resolves ate-secret:// references for the
	// kagent atespace in this namespace alone (the substrate component's
	// namespace policy), so the egress gateway can put the model key on a
	// sandbox's requests to Anthropic. The substrate component dropped
	// upstream's cluster-wide binding. Here it may get the model keys by
	// name and nothing else: a ModelConfig names its key Secret, so with
	// the whole namespace an agent's author could point one at the OIDC
	// client or cookie secret, or a connection string, with a base URL of
	// their own, and have the egress gateway send it there. A model key
	// added another way, such as through the UI, must be added to
	// modelKeys. get is the provider's one call (kubeprovider.go).
	Role: "k8s-credential-provider-model-keys": {
		metadata: namespace: NS
		rules: [{
			apiGroups: [""]
			resources: ["secrets"]
			resourceNames: modelKeys
			verbs: ["get"]
		}]
	}
	RoleBinding: "k8s-credential-provider-model-keys": {
		metadata: namespace: NS
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "Role"
			name:     "k8s-credential-provider-model-keys"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "k8s-credential-provider"
			namespace: S.namespace
		}]
	}

	// The connection strings, from the generated passwords in Substrate's
	// namespace, through the store users.
	ExternalSecret: (Secrets.owner): {
		metadata: namespace: NS
		spec: {
			refreshInterval: "1h"
			secretStoreRef: {kind: "SecretStore", name: Secrets.users}
			target: {
				creationPolicy: "Owner"
				template: {
					engineVersion: "v2"
					mergePolicy:   "Replace"
					data: ownerConnectionString: (DSN & {user: R.owner.user, password: "owner"}).out
				}
			}
			data: [{secretKey: "owner", remoteRef: {key: Secrets.users, property: R.owner.user}}]
		}
	}
	ExternalSecret: (Secrets.readwrite): {
		metadata: namespace: NS
		spec: {
			refreshInterval: "1h"
			secretStoreRef: {kind: "SecretStore", name: Secrets.users}
			target: {
				creationPolicy: "Owner"
				template: {
					engineVersion: "v2"
					mergePolicy:   "Replace"
					data: readWriteConnectionString: (DSN & {user: R.readwrite.user, password: "readwrite"}).out
				}
			}
			data: [{secretKey: "readwrite", remoteRef: {key: Secrets.users, property: R.readwrite.user}}]
		}
	}

	// The role Job's SQL, in Substrate's namespace, where the Job runs.
	ConfigMap: "kagent-db-setup": {
		metadata: namespace: S.namespace
		data: "setup.sql":   _setupSQL
	}

	// The role Job: kagent's setup.sql, run with psql as substrate-db's
	// superuser against the -rw Service, as Substrate's own role Job,
	// substrate-db-setup, runs Substrate's. A sibling of that Job rather
	// than a step of it, so the kagent component owns kagent's roles, SQL
	// and passwords, and the superuser's Secret never leaves Substrate's
	// namespace. Every statement converges and ALTER ROLE sets each user's
	// password from its Secret, so it runs on every sync: an Argo CD Sync
	// hook, deleted and re-created each time, and deleted with its pod once
	// it succeeds. Sync, not PostSync: the controller cannot become Healthy
	// until its roles exist. It waits for the database itself.
	Job: "kagent-db-setup": {
		metadata: {
			namespace: S.namespace
			labels:    Pods.setup
			annotations: {
				"argocd.argoproj.io/hook":               "Sync"
				"argocd.argoproj.io/hook-delete-policy": "BeforeHookCreation,HookSucceeded"
			}
		}
		spec: {
			backoffLimit:          6
			activeDeadlineSeconds: 900
			template: {
				metadata: labels: Pods.setup
				spec: {
					restartPolicy:                "OnFailure"
					automountServiceAccountToken: false
					// The image's postgres user.
					securityContext: {
						runAsNonRoot: true
						runAsUser:    26
						runAsGroup:   26
						seccompProfile: type: "RuntimeDefault"
					}
					containers: [{
						name:  "setup"
						image: DB.image
						command: ["/bin/sh", "-c", SetupScript]
						env: [
							{name: "PGHOST", value: DB.host},
							{name: "PGPORT", value: "\(DB.port)"},
							{name: "PGDATABASE", value: DB.database},
							{name: "PGSSLMODE", value: "verify-full"},
							{name: "PGSSLROOTCERT", value: CACert},
							{name: "PGCONNECT_TIMEOUT", value: "5"},
							{name: "PGUSER", valueFrom: secretKeyRef: {name: "\(DB.cluster)-superuser", key: "username"}},
							{name: "PGPASSWORD", valueFrom: secretKeyRef: {name: "\(DB.cluster)-superuser", key: "password"}},
							{name: "OWNER_PASSWORD", valueFrom: secretKeyRef: {name: Secrets.users, key: R.owner.user}},
							{name: "READWRITE_PASSWORD", valueFrom: secretKeyRef: {name: Secrets.users, key: R.readwrite.user}},
						]
						volumeMounts: [
							{name: "sql", mountPath: "/sql", readOnly: true},
							{name: "private-ca", mountPath: CAMount, readOnly: true},
						]
						resources: {
							requests: {cpu: "10m", memory: "32Mi"}
							limits: memory: "128Mi"
						}
						securityContext: Restricted
					}]
					volumes: [
						{name: "sql", configMap: name: "kagent-db-setup"},
						{name: "private-ca", configMap: name: PrivateCA.bundle},
					]
				}
			}
		}
	}

	// Isolation. The controller trusts any bearer token it is handed, so
	// each pod admits only the hop before it, at the application port;
	// the namespace is outside the mesh, so nothing else is in the path.
	// The kubelet's probes come from the node, which Cilium always admits.
	// oauth2-proxy serves metrics on 44180 and the tool server on 8085;
	// nothing scrapes them, and no policy admits them. The controller's
	// metrics are off.
	//
	// The controller: the UI's nginx, which proxies the API to it, and
	// Substrate's egress gateway, through which sandboxed agents call the
	// control plane back with actor tokens: the controlPlaneUrl, the A2A
	// gateway and the kagent-api MCP server are all this port. oauth2-proxy
	// forwards to the UI, and the tool server never calls it.
	NetworkPolicy: "\(K.release)-controller": {
		metadata: namespace: NS
		spec: {
			podSelector: matchLabels: Pods.controller
			policyTypes: ["Ingress"]
			ingress: [{
				from: [
					{podSelector: matchLabels: Pods.ui},
					{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": S.namespace
						podSelector: matchLabels: app:                                 "atenet-egress"
					},
				]
				ports: [{protocol: "TCP", port: K.controller.port}]
			}]
		}
	}
	// The UI: oauth2-proxy alone.
	NetworkPolicy: "\(K.release)-ui": {
		metadata: namespace: NS
		spec: {
			podSelector: matchLabels: Pods.ui
			policyTypes: ["Ingress"]
			ingress: [{
				from: [{podSelector: matchLabels: Pods.proxy}]
				ports: [{protocol: "TCP", port: K.ui.port}]
			}]
		}
	}
	// oauth2-proxy: the ingress Gateway's pods alone.
	NetworkPolicy: "\(K.release)-oauth2-proxy": {
		metadata: namespace: NS
		spec: {
			podSelector: matchLabels: Pods.proxy
			policyTypes: ["Ingress"]
			ingress: [{
				from: [{
					namespaceSelector: matchLabels: "kubernetes.io/metadata.name":      IngressGateway.namespace
					podSelector: matchLabels: "gateway.networking.k8s.io/gateway-name": IngressGateway.name
				}]
				ports: [{protocol: "TCP", port: K.proxy.port}]
			}]
		}
	}
	// The tool server, which reads every namespace: the controller, which
	// lists its tools, and the egress gateway, through which agents call
	// it. Without this any pod in the cluster could read through it.
	NetworkPolicy: "\(K.release)-tools": {
		metadata: namespace: NS
		spec: {
			podSelector: matchLabels: Pods.tools
			policyTypes: ["Ingress"]
			ingress: [{
				from: [
					{podSelector: matchLabels: Pods.controller},
					{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": S.namespace
						podSelector: matchLabels: app:                                 "atenet-egress"
					},
				]
				ports: [{protocol: "TCP", port: 8084}]
			}]
		}
	}

	// The database's door for kagent, beside substrate-db's own policy
	// (components/substrate), which admits Substrate's clients alone: the
	// controller, from this namespace, and the role Job.
	NetworkPolicy: "kagent-db": {
		metadata: namespace: S.namespace
		spec: {
			podSelector: matchLabels: "cnpg.io/cluster": DB.cluster
			policyTypes: ["Ingress"]
			ingress: [{
				from: [
					{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": NS
						podSelector: matchLabels: Pods.controller
					},
					{podSelector: matchLabels: Pods.setup},
				]
				ports: [{protocol: "TCP", port: DB.port}]
			}]
		}
	}
}

// The generated Secrets: the two login users' passwords, in Substrate's
// namespace beside the database, which the role Job sets and the connection
// strings carry, and oauth2-proxy's cookie secret, 32 letters and digits,
// an AES-256 key as oauth2-proxy takes it.
_Resources: (#GeneratedSecret & {
	name:      Secrets.users
	namespace: S.namespace
	generator: spec: secretKeys: [R.owner.user, R.readwrite.user]
}).resources
_Resources: (#GeneratedSecret & {
	name:      Secrets.cookie
	namespace: NS
	generator: spec: secretKeys: ["cookie-secret"]
}).resources

// The stores: users, here, that may get the passwords in Substrate's
// namespace, for the connection strings; oidc, here, that may get the
// Client's secret and the cookie secret in this namespace; and platform,
// that may get the Anthropic key in holos-prj-platform.
_Resources: (#ScopedSecretStore & {
	name:      Secrets.users
	namespace: NS
	source:    S.namespace
	secrets: [Secrets.users]
}).resources
_Resources: (#ScopedSecretStore & {
	name:      Secrets.oidc
	namespace: NS
	source:    NS
	secrets: [K.oidcSecret.name, Secrets.cookie]
}).resources
_Resources: (#ScopedSecretStore & {
	name:      "platform"
	namespace: NS
	secrets: [Secrets.platform]
}).resources
