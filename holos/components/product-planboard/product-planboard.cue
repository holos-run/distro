package holos

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"list"
	"strings"
)

// product-planboard renders one binding of the Planboard product
// (products/planboard.cue), as the component product-planboard-<project>: the
// registry adds one per binding (#BindingRegistrations), a cluster takes the
// ones whose claim lands on it and whose components it names (clusterBindings),
// and argocd-apps gives each an Application in the platform AppProject
// (#ProductComponent, components/product.cue). Planboard's code is not here: the
// Dockerfile beside this file builds the images, and products/planboard.cue
// pins them.
//
// Everything is in the platform bucket, since none of it is the owner's to
// change in git. The Substrate objects are in the atespace, which the owner
// also owns through the claim's ServiceAccount, so the hook writes them again on
// every sync:
//
//   - the claim's three public Quay repositories, which the images are pushed to
//     (README.md, Building the Planboard images) and atelet pulls from
//     anonymously;
//   - the credential provider's reading of the two Secrets the owner makes, by
//     name, beside its namespace policy, which the substrate component reads
//     from clusterBindings;
//   - a rule on the shim's Gateway admitting the claim's members to the board's
//     hostname, and to no other actor of the atespace;
//   - a Sync hook that makes the board's ActorTemplate, its Actor and its
//     EgressPolicy through Substrate's API, since none is a Kubernetes object;
//   - a ConfigMap beside the hook that nothing reads, since a hook is outside
//     the Application's comparison and this is what makes a change to it a
//     difference, so the automated sync runs it;
//   - the board's hostname on the ingress Gateway,
//     planboard.<claim>.<domain>, an HTTPRoute in the claim's namespace on the
//     claim's zone (IngressGateway.#Claim), to the board's login;
//   - the login: oauth2-proxy in the claim's namespace, its ServiceAccount,
//     Service and generated cookie secret, an Istio AuthorizationPolicy that
//     admits the ingress Gateway to it and nothing else, and the Keycloak
//     public client planboard-<claim> (Planboard.#Client) it logs in through
//     with PKCE, so no client secret exists anywhere.
//
// README.md, The board as an actor, has what the owner does by hand, and The
// board's login what the login does.

// ProjectName and ProductName are the binding this instance renders, the
// parameters its registry entry passes. Without them, as `cue vet ./...`
// evaluates this directory, each is empty and the instance renders nothing.
ProjectName: string | *"" @tag(project)
ProductName: string | *"" @tag(product)

// SyncScript is the template's sync container: the planning repository at
// /data/repo, kept at the head of its branch, in place, because Planboard opens
// its root once and a swapped directory would leave it serving a deleted one.
// The clone lands by a rename, so board cannot see half a checkout. An actor
// keeps /data across a new template, so a repository the binding changed is
// taken up from the remote's URL on every start. Git's credential is not in the
// sandbox: /etc/gitconfig sends a placeholder Authorization, which the egress
// gateway replaces (EgressRules, below). A failure is logged and tried again,
// since the board can go on serving what it has, and a stalled transfer is a
// failure, by the low speed limits in the container's environment. This is the
// only process that writes the checkout, so a lock it finds at the start is
// its own, left by a suspend, and git would otherwise refuse every reset from
// then on.
let SyncScript = """
	set -u
	repo=/data/repo
	if [ ! -d "$repo" ]; then
	  rm -rf /data/clone
	  until git clone --branch "$REPO_REF" --single-branch "$REPO_URL" /data/clone; do
	    rm -rf /data/clone
	    sleep 5
	  done
	  mv /data/clone "$repo"
	fi
	find "$repo/.git" -name '*.lock' -type f -delete
	git -C "$repo" remote set-url origin "$REPO_URL"
	while :; do
	  git -C "$repo" fetch origin "+refs/heads/$REPO_REF:refs/remotes/origin/$REPO_REF" &&
	    git -C "$repo" reset --hard "origin/$REPO_REF"
	  sleep 30
	done
	"""

// BoardScript is the template's board container. Planboard exits when its root
// is missing, and a template has no init containers, so it waits for the
// checkout. Port 80, because Substrate's router dials an actor there unless a
// CONNECT names another.
let BoardScript = """
	root="/data/repo$REPO_PATH"
	until [ -d "$root" ]; do sleep 1; done
	exec planboard --listen 0.0.0.0:80 --no-open "$root"
	"""

// ActorScript is the hook's. Its requests are in its environment, so nothing a
// binding sets is ever part of the script's text, and it reads the API's JSON
// with sed, since the image has no jq; an object's metadata comes first in it.
// grpcurl exits with 64 plus a call's gRPC status code, so 69 is NotFound and 70
// AlreadyExists.
//
// Every step can run again. The template's name carries its content, so a new
// image or a new value is a new template, and the same ones find it already
// there. Templates are immutable, and an actor changes its template only while
// suspended, so an actor on another template is suspended and repointed, which
// boots the new containers cold on its durable data at the next request. A
// crashed actor is reverted to suspended first, whatever its template, because
// the router cannot wake it: that is how a wake before the owner made
// planboard-git ends, the clone failing until the probe gives up. The egress
// policy is written on every sync, so it is always this render's. Last, only
// templates with this component's own shape of name are deleted, since the
// atespace is the owner's too. Substrate does not refuse to delete a template in
// use, so a name of this shape is the hook's alone: another actor must not be
// made from one.
let ActorScript = """
	set -eu
	ATE_TOKEN=$(cat \(Substrate.atespaceSetup.dir)/token)
	export ATE_TOKEN

	rpc() {
	  grpcurl -cacert \(Substrate.atespaceSetup.dir)/ca.pem -max-time 60 \\
	    -expand-headers -H 'authorization: Bearer ${ATE_TOKEN}' \\
	    -d "$2" \(Substrate.api.host):\(Substrate.api.port) \(Substrate.api.service)/"$1"
	}

	uid() { printf '%s\\n' "$1" | sed -n 's/.*"uid": *"\\([^"]*\\)".*/\\1/p' | head -n 1; }
	version() { printf '%s\\n' "$1" | sed -n 's/.*"version": *"\\([0-9]*\\)".*/\\1/p' | head -n 1; }
	state() { printf '%s\\n' "$1" | sed -n 's/.*"state": *"ACTOR_STATE_\\([A-Z]*\\)".*/\\1/p' | head -n 1; }
	template() { printf '%s\\n' "$1" | sed -n '/"actorTemplate": *{/,/}/s/.*"name": *"\\([^"]*\\)".*/\\1/p' | head -n 1; }

	status=0
	rpc CreateActorTemplate "$CREATE_TEMPLATE" >/dev/null || status=$?
	case "$status" in
	0) echo "template $TEMPLATE: created" ;;
	70) echo "template $TEMPLATE: already exists" ;;
	*) exit "$status" ;;
	esac

	status=0
	actor=$(rpc GetActor "$ACTOR_REF") || status=$?
	case "$status" in
	0)
	  if [ "$(state "$actor")" = CRASHED ]; then
	    rpc RevertActor "$ACTOR_REF" >/dev/null
	    actor=$(rpc GetActor "$ACTOR_REF")
	    echo "actor: reverted from CRASHED"
	  fi
	  current=$(template "$actor")
	  if [ "$current" = "$TEMPLATE" ]; then
	    echo "actor: on $TEMPLATE"
	  else
	    if [ "$(state "$actor")" != SUSPENDED ]; then
	      rpc SuspendActor "$ACTOR_REF" >/dev/null
	    fi
	    actor=$(rpc GetActor "$ACTOR_REF")
	    rpc UpdateActor "$(printf "$UPDATE_ACTOR" "$(uid "$actor")" "$(version "$actor")")" >/dev/null
	    echo "actor: moved from $current to $TEMPLATE"
	  fi
	  ;;
	69)
	  rpc CreateActor "$CREATE_ACTOR" >/dev/null
	  echo "actor: created on $TEMPLATE"
	  ;;
	*) exit "$status" ;;
	esac

	status=0
	policy=$(rpc GetActorEgressPolicy "$POLICY_REF") || status=$?
	case "$status" in
	0)
	  rpc UpdateActorEgressPolicy "$(printf "$UPDATE_POLICY" "$(uid "$policy")" "$(version "$policy")")" >/dev/null
	  echo "egress policy: updated"
	  ;;
	69)
	  rpc CreateActorEgressPolicy "$CREATE_POLICY" >/dev/null
	  echo "egress policy: created"
	  ;;
	*) exit "$status" ;;
	esac

	templates=$(rpc ListActorTemplates "$LIST_TEMPLATES")
	for old in $(printf '%s\\n' "$templates" | sed -n 's/.*"name": *"\\(planboard-[0-9a-f]\\{12\\}-[0-9a-f]\\{8\\}\\)".*/\\1/p'); do
	  [ "$old" != "$TEMPLATE" ] || continue
	  status=0
	  rpc DeleteActorTemplate "$(printf "$DELETE_TEMPLATE" "$old")" >/dev/null || status=$?
	  case "$status" in
	  0) echo "template $old: deleted" ;;
	  69) echo "template $old: already gone" ;;
	  *) exit "$status" ;;
	  esac
	done
	"""

if ProjectName != "" {
	let Read = #ProductComponent & {projectName: ProjectName, productName: ProductName}
	let CLAIM = ProjectName
	let Labels = {"holos.run/project": CLAIM}

	// Secrets are what the owner makes in their namespace by hand (README.md,
	// The board as an actor), the only Secrets the credential provider may read
	// there. Each of them leaves the cluster only on a request the actor's
	// egress policy sends to the host that policy names.
	let Secrets = {
		git:       "planboard-git"
		anthropic: "planboard-anthropic"
	}
	let CredentialReader = "k8s-credential-provider-planboard"

	// Actor is the board's name in the atespace, so its hostname is
	// planboard.<claim>.<AteGateway.domain>.
	let Actor = "planboard"
	let ActorRef = {atespace: CLAIM, name: Actor}

	// Trust is where the sync container reads what it trusts for github.com. An
	// https egress rule is a man in the middle, so that is the gateway's CA as
	// well as the public roots.
	let Trust = {
		mount: "/run/ate"
		file:  "egress-trust-bundle/trust-bundle.pem"
	}

	// Repo is the repository's environment, the same in both containers, so a
	// script reads a binding's values and never holds them in its text.
	let Repo = [
		{name: "REPO_URL", value: Read.values.repo.url},
		{name: "REPO_REF", value: Read.values.repo.ref},
		{name: "REPO_PATH", value: Read.values.repo.path},
	]

	let Image = "\(Quay.host)/\(CLAIM)/planboard@\(Read.product.images.board)"

	// TemplateSpec is the ActorTemplate but for its metadata. The containers run
	// as the image's user, 65532, which gVisor lets bind port 80, and share
	// /data, a durable directory. The golden snapshot is off, since it would run
	// the board before any clone. The probe is on /, the embedded UI, because
	// /api/projects loads the whole tree and each probe request gets 250 ms, and
	// board starts only once the checkout is there, so its 120 seconds has to
	// cover the first clone.
	let TemplateSpec = {
		containers: [
			{
				name:  "sync"
				image: Image
				command: ["/bin/sh", "-c", SyncScript]
				env: list.Concat([Repo, [
					{name: "GIT_SSL_CAINFO", value: "\(Trust.mount)/\(Trust.file)"},
					{name: "GIT_TERMINAL_PROMPT", value: "0"},
					{name: "GIT_HTTP_LOW_SPEED_LIMIT", value: "1000"},
					{name: "GIT_HTTP_LOW_SPEED_TIME", value: "60"},
				]])
				volumeMounts: [
					{name: "data", mountPath: "/data"},
					{name: "system-info", mountPath: Trust.mount},
				]
			},
			{
				name:  "board"
				image: Image
				command: ["/bin/sh", "-c", BoardScript]
				env: Repo
				wakeupProbe: {
					httpGet: {path: "/", port: 80}
					timeoutSeconds: 120
				}
				volumeMounts: [{name: "data", mountPath: "/data"}]
			},
		]
		volumes: [
			{name: "data", durableDir: {}},
			{
				name: "system-info"
				systemInfo: dataSources: [{
					trustBundle: {
						names: ["egress-mitm.ate.dev", "system-roots.ate.dev"]
						path: Trust.file
					}
				}]
			},
		]
		resources: limits: {cpuMillicores: 500, memoryBytes: 536870912}
		snapshotConfig: {
			preferredFidelity: "SNAPSHOT_FIDELITY_MEMORY"
			goldenSnapshotConfig: mode: "GOLDEN_SNAPSHOT_MODE_DISABLED"
		}
	}

	// Template is the ActorTemplate's name: the image's digest, to read, and a
	// hash of the whole template, because a template is immutable and a name
	// from the image alone would keep the old one when a value changes.
	let Digest12 = strings.SliceRunes(strings.TrimPrefix(Read.product.images.board, "sha256:"), 0, 12)
	let Spec8 = strings.SliceRunes(hex.Encode(sha256.Sum256(json.Marshal(TemplateSpec))), 0, 8)
	let Template = "planboard-\(Digest12)-\(Spec8)"
	let TemplateRef = {atespace: CLAIM, name: Template}

	// EgressRules are the board's whole egress: github.com, with the owner's
	// credential on any request that carries the placeholder.
	let EgressRules = [{
		https: {
			hostnames: ["github.com"]
			ports: numbers: [443]
			effects: replaceHeaders: [{
				header:        "authorization"
				prefix:        "Basic "
				credentialUri: "ate-secret://k8s.io/default/\(CLAIM)/\(Secrets.git)/authorization"
			}]
		}
	}]

	// JobEnv is ActorScript's. Those with a %s are printf formats, for what only
	// the API knows, the uid and version an update must name.
	let JobEnv = [
		{name: "TEMPLATE", value: Template},
		{name: "ACTOR_REF", value: json.Marshal({actor: ActorRef})},
		{name: "POLICY_REF", value: json.Marshal({actor: ActorRef, name: "default"})},
		{name: "LIST_TEMPLATES", value: json.Marshal({atespace: CLAIM, options: pageSize: 1000})},
		{name: "CREATE_TEMPLATE", value: json.Marshal({actorTemplate: TemplateSpec & {metadata: TemplateRef}})},
		{name: "CREATE_ACTOR", value: json.Marshal({actor: {metadata: ActorRef, actorTemplate: TemplateRef}})},
		{name: "UPDATE_ACTOR", value: json.Marshal({actor: {metadata: ActorRef & {uid: "%s", version: "%s"}, actorTemplate: TemplateRef}})},
		{name: "CREATE_POLICY", value: json.Marshal({actor: ActorRef, egressPolicy: {metadata: {atespace: CLAIM, name: "default"}, rules: EgressRules}})},
		{name: "UPDATE_POLICY", value: json.Marshal({actor: ActorRef, egressPolicy: {metadata: {atespace: CLAIM, name: "default", uid: "%s", version: "%s"}, rules: EgressRules}})},
		{name: "DELETE_TEMPLATE", value: json.Marshal({actorTemplate: {atespace: CLAIM, name: "%s"}})},
	]

	// Zone is the claim's zone on the ingress Gateway, which components/project
	// renders on a cluster where the claim has a binding, as this one has, and
	// Host the board's name in it, the product's name under the claim's.
	let Zone = IngressGateway.claimed[CLAIM]
	let Host = "planboard.\(Zone.domain)"

	// ActorHost is the board's hostname through the Substrate shim, which
	// the claim's members reach with an ID token, and the login's upstream.
	let ActorHost = "\(Actor).\(CLAIM).\(AteGateway.domain)"

	// Proxy is the login, oauth2-proxy, in the claim's namespace: its
	// Deployment, ServiceAccount and Service all have the name, which is the
	// one kagent's chart gives its own (Kagent.proxy), <release>-oauth2-proxy
	// on 4180, with the release planboard. pods are its pods' labels, which
	// the Service and the Istio AuthorizationPolicy select on, named as the
	// chart names kagent's. cookie is the generated Secret holding its cookie
	// secret.
	let Proxy = {
		service: "planboard-oauth2-proxy"
		port:    4180
		pods: {
			"app.kubernetes.io/name":     "oauth2-proxy"
			"app.kubernetes.io/instance": "planboard"
		}
		cookie: "\(service)-cookie"
	}

	// Login is the board's Keycloak client, planboard-<claim>, and its one
	// redirect URI, oauth2-proxy's callback on the board's hostname.
	let Login = {
		client: (Planboard.#Client & {project: CLAIM}).id
		callback: "https://\(Host)/oauth2/callback"
	}

	// CAMount is where the private-ca ConfigMap is mounted in the proxy.
	let CAMount = "/etc/private-ca"

	// ProxyArgs are oauth2-proxy's arguments, every one stated, with no
	// configuration file.
	//
	// The client is public and the flow PKCE, so there is no client secret
	// to hold in a namespace the owner is admin in. oauth2-proxy refuses to
	// start with no secret; a secret file of /dev/null reads as an empty one,
	// which is the way past that check oauth2-proxy's issue 1714 documents,
	// and Keycloak skips the secret for a public client. The scopes are the
	// realm's defaults, as kagent's chart asks for them, groups among them,
	// so the ID token carries the full group paths the shim's rule reads.
	//
	// Upstream, oauth2-proxy sends the session's ID token as a bearer token,
	// which the shim verifies again, and nothing else of the user: not the
	// access token, and no X-Forwarded-User, -Email, -Groups or
	// -Preferred-Username, which pass-user-headers and pass-basic-auth would
	// each set. With both off oauth2-proxy also leaves a client's own copies
	// in place, so the route removes them (HTTPRoute, below). The ID token is
	// not set on the browser's response. The Host is the upstream's, the
	// actor's hostname, the only one the shim's Lua takes. The upstream is
	// plain HTTP, so a waypoint in the claim's namespace can read the
	// request's headers and originate TLS to the shim (in the
	// Planboard_On_Holos planning project,
	// the-project-waypoint-and-the-shim-hop); until it is there, the name
	// resolves to the ingress Gateway, whose port 80 redirects to https.
	//
	// cookie-refresh: Keycloak's ID token lives five minutes, so oauth2-proxy
	// redeems the session's refresh token for a new one on a request once
	// the session is a minute old, as kagent's does. Any user of the realm may
	// log in: the shim decides who reaches the board, by the token's groups.
	// The provider button is skipped, so a request with no session goes
	// straight to Keycloak.
	//
	// Not skip-jwt-bearer-tokens: a bearer token in a request is not a login
	// here, and a token for the board's client is the shim's to take. Not
	// reverse-proxy: with it oauth2-proxy would read X-Forwarded-Uri, which
	// the ingress Gateway passes through from the client, for its skip-auth
	// rules and redirects. The metrics port stays off, since nothing scrapes
	// it.
	let ProxyArgs = [
		"--http-address=0.0.0.0:\(Proxy.port)",
		"--provider=oidc",
		"--oidc-issuer-url=\(Keycloak.issuer)",
		"--client-id=\(Login.client)",
		"--client-secret-file=/dev/null",
		"--code-challenge-method=S256",
		"--scope=openid profile email groups",
		"--redirect-url=\(Login.callback)",
		"--upstream=http://\(ActorHost)",
		"--pass-authorization-header=true",
		"--set-authorization-header=false",
		"--pass-access-token=false",
		"--pass-user-headers=false",
		"--pass-basic-auth=false",
		"--pass-host-header=false",
		"--cookie-refresh=1m",
		"--cookie-secure=true",
		"--cookie-samesite=lax",
		"--email-domain=*",
		"--skip-provider-button=true",
	]

	// IdentityHeaders are the request headers an auth proxy uses to name the
	// user, which the board's route removes from every request before it
	// reaches oauth2-proxy (ProxyArgs).
	let IdentityHeaders = [
		"X-Forwarded-User",
		"X-Forwarded-Email",
		"X-Forwarded-Groups",
		"X-Forwarded-Preferred-Username",
		"X-Auth-Request-User",
		"X-Auth-Request-Email",
		"X-Auth-Request-Groups",
		"X-Auth-Request-Preferred-Username",
		"X-Auth-Request-Access-Token",
		"X-Forwarded-Access-Token",
	]

	// Hook is held here because two objects read it, the Job and its ConfigMap.
	let Hook = #AteAPIJob & {
		labels: Labels
		script: ActorScript
		env:    JobEnv
	}

	holos: spec: artifacts: (Read & {
		platform: {
			// Public, so atelet pulls with no pull secret, as demo/echo is. Orphan,
			// as the claim's Organization is, so removing the binding leaves the
			// images in Quay.
			for NAME, DESCRIPTION in {
				planboard:          "The Planboard board, which the actor runs."
				"planboard-agent":  "The Planboard agent, kagent's Claude harness with planboard."
				"planboard-plugin": "The Planboard plugin, an image volume of the agent."
			} {
				Repository: (NAME): {
					metadata: {
						namespace: CLAIM
						labels:    Labels
					}
					spec: {
						name:            NAME
						organizationRef: CLAIM
						visibility:      "public"
						description:     DESCRIPTION
						deletionPolicy:  "Orphan"
						credentialsSecretRef: name: Quay.credentials.controller
					}
				}
			}

			// The credential provider resolves the actors' ate-secret:// references
			// in the claim's namespace (the substrate component's namespace
			// policy), and may get these Secrets by name and nothing else there,
			// as in kagent's. get is its one call.
			Role: (CredentialReader): {
				metadata: {
					namespace: CLAIM
					labels:    Labels
				}
				rules: [{
					apiGroups: [""]
					resources: ["secrets"]
					resourceNames: [for _, NAME in Secrets {NAME}]
					verbs: ["get"]
				}]
			}
			RoleBinding: (CredentialReader): {
				metadata: {
					namespace: CLAIM
					labels:    Labels
				}
				roleRef: {
					apiGroup: "rbac.authorization.k8s.io"
					kind:     "Role"
					name:     CredentialReader
				}
				subjects: [{
					kind:      "ServiceAccount"
					name:      "k8s-credential-provider"
					namespace: Substrate.namespace
				}]
			}

			// The board's host, for each of the claim's roles and the platform's
			// owners. A policy of its own, for one host, since ALLOW policies on a
			// Gateway add up: the claim's own (components/project) stays the owners',
			// on every host of the atespace, and another actor there stays closed to
			// editors and viewers. Owners are named again so that this rule can take
			// an audience the claim's cannot: the board's client, whose tokens the
			// login forwards, beside kubectl's. Every other rule on the Gateway
			// takes kubectl's alone (AteGateway.#Rule), so a token of the board's
			// client is good on this host and on no other actor of any atespace.
			AuthorizationPolicy: "product-planboard-\(CLAIM)": {
				metadata: {
					namespace: AteGateway.namespace
					labels:    Labels
				}
				spec: {
					targetRefs: [{
						group: "gateway.networking.k8s.io"
						kind:  "Gateway"
						name:  AteGateway.name
					}]
					action: "ALLOW"
					rules: [(AteGateway.#Rule & {
						hostname: ActorHost
						groups: list.Concat([
							[for ROLE in #ProjectRoles {(#ProjectRoleGroupPath & {project: CLAIM, role: ROLE}).claim}],
							[Keycloak.groups.owners.path],
						])
						audiences: [Keycloak.clients.kubectl, Login.client]
					}).out]
				}
			}

			// #AteAPIJob holds where it runs, under what credential, and why, and
			// what a failure does. It runs after project-<claim> has made the
			// atespace, a wave earlier. A claim's name can be 54 characters, which
			// here is one too many for a Job's: refused on the name, because a
			// bottom in the key would drop the Job and render on without it.
			Job: "planboard-\(CLAIM)": Hook.job & {metadata: name: strings.MaxRunes(63)}

			// The image's digest, the binding's repo values, the egress rules and the
			// script reach the cluster only through the hook, which is outside the
			// Application's comparison: a change to them alone would leave the
			// Application Synced and the actor where it was. Nothing reads this
			// ConfigMap. It is here to be compared, with no hook annotation, so
			// that any such change is a difference and the automated sync runs the
			// hook. job is the Job's revision, which covers all of it, and template
			// is there for a person, as the name the actor should be on.
			ConfigMap: "planboard-\(CLAIM)": {
				metadata: {
					namespace: Substrate.namespace
					labels:    Labels
				}
				data: {
					template: Template
					job:      Hook.revision
				}
			}

			// The board's hostname on the ingress Gateway, in the claim's zone,
			// on its ListenerSet, which admits routes from the claim's namespace
			// alone. The platform's, not the owner's: the route decides what is
			// in front of the board. Every path goes to the proxy, as kagent's
			// do, and none to the board itself, which would bypass the login.
			// The gateway removes a client's identity headers first, which
			// oauth2-proxy, setting none of its own, would pass on
			// (ProxyArgs).
			HTTPRoute: planboard: {
				metadata: {
					namespace: CLAIM
					labels:    Labels
				}
				spec: {
					parentRefs: [Zone.parentRef]
					hostnames: [Host]
					rules: [{
						filters: [{
							type: "RequestHeaderModifier"
							requestHeaderModifier: remove: IdentityHeaders
						}]
						backendRefs: [{name: Proxy.service, port: Proxy.port}]
					}]
				}
			}

			// The board's client: public, so it has no secret, and standard
			// flow to oauth2-proxy's one callback, with PKCE. It gets the
			// realm's default scopes, which oauth2-proxy asks for by name. In
			// the claim's namespace, naming the Instance in keycloak, which
			// the claim's ReferenceGrant there allows for Client where the
			// claim has a binding (components/project).
			Client: (Login.client): {
				metadata: {
					namespace: CLAIM
					labels:    Labels
				}
				spec: {
					clientId:    Login.client
					type:        "public"
					description: "Planboard for the project \(CLAIM)"
					instanceRef: PlatformController.instance
					redirectUris: [Login.callback]
				}
			}

			// oauth2-proxy's own identity: the mesh's for this workload, which
			// no other pod in the namespace shares unless the owner makes one
			// with it. It calls no Kubernetes API, so it mounts no token.
			ServiceAccount: (Proxy.service): {
				metadata: {
					namespace: CLAIM
					labels:    Labels
				}
				automountServiceAccountToken: false
			}

			// oauth2-proxy, one replica, with the image kagent's runs
			// (OAuth2Proxy) and the chart's user, probes and security
			// context, and kagent's resources. The cookie secret comes from
			// the generated Secret (below) and the private root from
			// trust-manager's ConfigMap, which every namespace has: Keycloak
			// is reached at its public name through the ingress Gateway, whose
			// certificate the private CA issues. The kubelet's probes reach an
			// ambient pod from 169.254.7.127, which ztunnel's policy does not
			// see.
			Deployment: (Proxy.service): {
				metadata: {
					namespace: CLAIM
					labels:    Labels
				}
				spec: {
					replicas: 1
					selector: matchLabels: Proxy.pods
					template: {
						metadata: labels: Proxy.pods & Labels
						spec: {
							serviceAccountName:           Proxy.service
							automountServiceAccountToken: false
							securityContext: {
								runAsNonRoot: true
								runAsUser:    2000
								runAsGroup:   2000
								seccompProfile: type: "RuntimeDefault"
							}
							containers: [{
								name:  "oauth2-proxy"
								image: OAuth2Proxy.image
								args:  ProxyArgs
								env: [
									{
										name: "OAUTH2_PROXY_COOKIE_SECRET"
										valueFrom: secretKeyRef: {name: Proxy.cookie, key: "cookie-secret"}
									},
									{name: "SSL_CERT_FILE", value: "\(CAMount)/\(PrivateCA.bundleKey)"},
								]
								ports: [{name: "http", containerPort: Proxy.port, protocol: "TCP"}]
								livenessProbe: httpGet: {path: "/ping", port: "http"}
								readinessProbe: httpGet: {path: "/ready", port: "http"}
								volumeMounts: [{name: "private-ca", mountPath: CAMount, readOnly: true}]
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
							volumes: [{name: "private-ca", configMap: name: PrivateCA.bundle}]
						}
					}
				}
			}

			// The route's backend, oauth2-proxy on 4180. The owner is admin in
			// the namespace, so a pod of theirs with the proxy's labels would
			// join the Service and receive the board's traffic, viewers'
			// session cookies included; nothing in Kubernetes stops it short of
			// taking pod create away from the owner, and the gap is accepted
			// for now.
			Service: (Proxy.service): {
				metadata: {
					namespace: CLAIM
					labels:    Labels
				}
				spec: {
					selector: Proxy.pods
					ports: [{
						name:       "http"
						port:       Proxy.port
						targetPort: Proxy.port
						protocol:   "TCP"
					}]
				}
			}

			// The claim's namespace is in ambient, so the ingress Gateway
			// reaches oauth2-proxy over HBONE, where a NetworkPolicy would see
			// port 15008 and not 4180. ztunnel enforces this instead: the
			// gateway's mesh identity, on 4180 alone, and nothing else, as
			// holos-authenticator admits its gateway. The proxy's own egress
			// is the waypoint's to narrow (in the Planboard_On_Holos planning
			// project, the-project-waypoint-and-the-shim-hop).
			AuthorizationPolicy: (Proxy.service): {
				metadata: {
					namespace: CLAIM
					labels:    Labels
				}
				spec: {
					selector: matchLabels: Proxy.pods
					action: "ALLOW"
					rules: [{
						from: [{source: principals: [IngressGateway.principal]}]
						to: [{operation: ports: ["\(Proxy.port)"]}]
					}]
				}
			}

			// The cookie secret, 32 letters and digits, which oauth2-proxy
			// decodes as base64url to 24 bytes, an AES-192 key, generated in the claim's namespace as
			// kagent's is. The owner, admin there, can read it, and so could
			// decrypt a viewer's session cookie, which holds that viewer's
			// tokens for the board's client: good for the board and nothing
			// else, whose content the owner already decides. Accepted.
			(#GeneratedSecret & {
				name:      Proxy.cookie
				namespace: CLAIM
				generator: spec: secretKeys: ["cookie-secret"]
			}).resources
		}
		project: {}
	}).artifacts
}
