package holos

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/yaml"
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
// Everything but the waypoint's policy is in the platform bucket, since none of
// it is the owner's to change in git. The Substrate objects are in the
// atespace, which the owner also owns through the claim's ServiceAccount, so the
// hook writes them again on every sync:
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
//     with PKCE, so no client secret exists anywhere;
//   - the hop from the login to the shim: a waypoint in the claim's
//     namespace, a Gateway of the claim's waypointClass with its parameters
//     ConfigMap, which mounts the private root; a ServiceEntry that gives the
//     board's shim hostname a mesh address behind the waypoint, on port 80, to
//     the shim Gateway's ClusterIP Service on 443; a DestinationRule that
//     originates TLS to the shim with the hostname as SNI, against the private
//     root; and a TrafficExtension whose Lua copies the project query
//     parameter into x-planboard-project and strips what Planboard should not
//     see.
//
// The project bucket, the claim's own Application, holds the waypoint's
// RequestAuthentication and AuthorizationPolicy, which decide who reads which
// part of the board (overview §6): the owner's to edit live, with self-heal off
// on that Application, and healed back to this render when it is on again.
// The waypoint's Gateway and its parameters ConfigMap, the ServiceEntry, the
// DestinationRule, the TrafficExtension and an AuthorizationPolicy that
// admits nothing stay in the platform bucket, since they decide where the
// board's traffic goes, what it is checked against and what the policy reads,
// and the last makes the waypoint refuse everything the owner's policy does
// not admit, whichever Application syncs first. Denying those kinds in the
// claim's AppProject is self-heal-off-for-live-policy-edits, in the
// Planboard_On_Holos planning project, and not done here; until then the
// owner, admin in the namespace, can edit them live, and self-heal on the
// platform's Application puts them back.
//
// A logged-in request takes this path:
//
//	browser
//	  -> the ingress Gateway, the claim's ListenerSet, the HTTPRoute planboard,
//	     which removes the identity headers
//	  -> oauth2-proxy, which adds the ID token as a bearer token, to
//	     http://<ActorHost>, whose address in the claim's namespace is the
//	     ServiceEntry's
//	  -> ztunnel, to the waypoint over HBONE
//	  -> the waypoint: RequestAuthentication (the board's client), the Lua,
//	     AuthorizationPolicy (the claim's groups, by route and project)
//	  -> TLS to the shim Gateway's Service, for ActorHost
//	  -> the shim, which verifies the token again (the AuthorizationPolicy
//	     product-planboard-<claim>, below), and the router, to the actor
//
// README.md, The board as an actor, has what the owner does by hand, and The
// board's login what the login and the waypoint do.

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

	// CAMount is where the private-ca ConfigMap is mounted, in the proxy and
	// in the waypoint.
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
	// plain HTTP to port 80, so the waypoint in the claim's namespace can read
	// the request's headers and originate TLS to the shim: ztunnel's DNS
	// proxy resolves the actor's hostname to the ServiceEntry's address
	// (ShimEntry, below), and ztunnel sends what is dialed there through the
	// waypoint, so the argument names the hostname and nothing else.
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
	// reaches oauth2-proxy (ProxyArgs), and the waypoint's Lua removes again
	// (Lua, below).
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

	// Waypoint is the board's waypoint in the claim's namespace, which
	// istiod deploys as a Deployment and a Service of the Gateway's name. It is
	// named for the product, not a bare waypoint, since another product bound
	// to the claim would want that name. ref is the Gateway as the policies'
	// targetRefs name it, so each applies to this waypoint alone. parameters
	// is the ConfigMap its infrastructure.parametersRef names. class is the
	// claim's waypointClass, interpolated, which settles the claim's default:
	// #Resources gives a Gateway's class a default of its own, and two
	// defaults that differ leave neither.
	let WaypointName = "planboard-waypoint"
	let Waypoint = {
		name:       WaypointName
		parameters: WaypointName
		class:      "\(Read.claim.waypointClass)"
		ref: {
			group: "gateway.networking.k8s.io"
			kind:  "Gateway"
			name:  WaypointName
		}
	}

	// ShimEntry is the ServiceEntry and the DestinationRule for the board's
	// shim hostname, and endpoint the shim Gateway's ClusterIP Service, the
	// fully qualified name, since a ServiceEntry's endpoint is resolved by DNS
	// as it is written. The Service rather than the public hostname, which
	// resolves to the ingress Gateway's address, where ztunnel could take the
	// connection for the ingress Service's.
	let ShimEntry = {
		name:     "planboard-shim"
		endpoint: "\(AteGateway.service).\(AteGateway.namespace).svc.\(Cluster.network.dnsDomain)"
	}

	// ProjectHeader is the header the waypoint's Lua sets from the project
	// query parameter, and the policy's viewer rule for /api/document reads.
	let ProjectHeader = "x-planboard-project"

	// ProjectPattern is #Values' #projectPattern (products/planboard.cue) as a
	// Lua pattern. Lua's patterns are not regular expressions: a dash is a
	// range in a character class and a lazy repetition outside one unless
	// escaped with %, and there is no alternation and no counted repetition.
	// So it is written out here, and unified with the regular expression with
	// that one change made, so that a change there fails the render until this
	// is changed with it. The literal is a let of its own: CUE v0.17.1 lets a
	// let that unifies a literal with a builtin's result conflict without an
	// error, and takes the literal.
	let LuaProjectPattern = "^[A-Za-z0-9][A-Za-z0-9_%-]*$"
	let ProjectPattern = LuaProjectPattern & strings.Replace(Read.product.#Values.#projectPattern, "-]", "%-]", -1)

	// Theme is the one cookie of Planboard's own, which holds the UI's theme
	// and nothing about the user.
	let Theme = "planboard-theme"

	// Lua is the waypoint's TrafficExtension, at the AUTHZ phase: after the
	// JWT filter, so a request with a bad token is already refused, and before
	// the RBAC filter, so the AuthorizationPolicy reads the header it sets.
	//
	// Istio matches a policy's paths without the query, and has no condition
	// on a query parameter, so the Lua makes the project parameter a header.
	// It reads the query as Planboard does, with Go's url.Query().Get, so the
	// project the policy admits is the project Planboard serves: pairs split
	// on &, empty ones skipped; a pair holding ; dropped, as Go has done since
	// 1.17; key and value split at the first =, each unescaped with + as a
	// space and %XX as a byte, a malformed escape dropping the pair; and the
	// first pair whose key is project wins. Its value becomes the header only
	// in the shape of a project's name (ProjectPattern), and otherwise there
	// is no header, so a viewer is refused. A client's own copy of the header
	// is removed first, whatever the query says.
	//
	// It also strips what Planboard has no use for and should not see: every
	// cookie but Theme, the login's session cookie among them; the client's
	// X-Forwarded-For, so the address Planboard sees is the waypoint's, which
	// the shim appends; and IdentityHeaders, which the board's route removes
	// for requests through the ingress Gateway, and which a pod in the claim's
	// namespace calling the ServiceEntry's address directly could send. The
	// Authorization header stays, for the shim, which removes it once it has
	// verified the token.
	//
	// Envoy keeps each Cookie header a client sends as a value of its own, so
	// every value is read, by index from 0. A pair is kept when its name, the
	// text before the first = with spaces trimmed as Go trims it, is Theme, and
	// what is kept is sent as one header, or none.
	let RemoveIdentity = strings.Join([for H in IdentityHeaders {
		"  headers:remove(\"\(strings.ToLower(H))\")"
	}], "\n")
	let Lua = """
		-- unescape is Go's url.QueryUnescape: + is a space and %XX a byte, and a
		-- % not followed by two hex digits fails the whole pair, so nil.
		local function unescape(s)
		  local i = 1
		  while true do
		    local p = string.find(s, "%", i, true)
		    if p == nil then break end
		    if not string.match(string.sub(s, p + 1, p + 2), "^%x%x$") then return nil end
		    i = p + 3
		  end
		  s = string.gsub(s, "%+", " ")
		  s = string.gsub(s, "%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end)
		  return s
		end

		-- project is the first value of the query parameter project, as Go's
		-- url.Query().Get reads it, or nil. Go reads no parameter at all past
		-- its limit of 10000 pairs, where this still reads one; that can
		-- only admit a viewer to a request Planboard then answers with no
		-- project.
		local function project(path)
		  local query = string.match(path, "%?(.*)$")
		  if query == nil then return nil end
		  for pair in string.gmatch(query, "[^&]+") do
		    if not string.find(pair, ";", 1, true) then
		      local key, value = pair, ""
		      local eq = string.find(pair, "=", 1, true)
		      if eq ~= nil then
		        key = string.sub(pair, 1, eq - 1)
		        value = string.sub(pair, eq + 1)
		      end
		      key = unescape(key)
		      if key ~= nil then value = unescape(value) end
		      if key == "project" and value ~= nil then return value end
		    end
		  end
		  return nil
		end

		local function trim(s)
		  return string.match(s, "^%s*(.-)%s*$")
		end

		-- theme is every \(Theme) cookie of every Cookie header, as name=value.
		local function theme(headers)
		  local kept = {}
		  for i = 0, headers:getNumValues("cookie") - 1 do
		    for pair in string.gmatch(headers:getAtIndex("cookie", i) or "", "[^;]+") do
		      pair = trim(pair)
		      if trim(string.match(pair, "^[^=]*")) == "\(Theme)" then
		        table.insert(kept, pair)
		      end
		    end
		  end
		  return kept
		end

		function envoy_on_request(handle)
		  local headers = handle:headers()

		  -- The project, for the policy, and only from the query.
		  headers:remove("\(ProjectHeader)")
		  local name = project(headers:get(":path") or "")
		  if name ~= nil and string.match(name, "\(ProjectPattern)") then
		    headers:add("\(ProjectHeader)", name)
		  end

		  -- Of the cookies, \(Theme) alone.
		  local kept = theme(headers)
		  headers:remove("cookie")
		  if #kept > 0 then
		    headers:add("cookie", table.concat(kept, "; "))
		  end

		  -- No client address, and no header naming a user.
		  headers:remove("x-forwarded-for")
		\(RemoveIdentity)
		end
		"""

	// Policy is what the waypoint's AuthorizationPolicy is made of (overview
	// §6). Every rule takes a token the RequestAuthentication verified, from
	// the realm, and one of the claim's groups in its groups claim. Writers
	// are /platform/owners and the claim's owner and editor groups, who reach
	// every route: editors read the board, since they drive the agent that
	// writes it. The viewer group reads the UI shell and the API that names
	// no project, and the projects the binding lists (Viewers).
	let Policy = {
		from: [{source: requestPrincipals: ["\(Keycloak.issuer)/*"]}]
		groups: "request.auth.claims[\(Keycloak.groupsClaim)]"
		writers: list.SortStrings([
			Keycloak.groups.owners.path,
			(#ProjectRoleGroupPath & {project: CLAIM, role: "owner"}).claim,
			(#ProjectRoleGroupPath & {project: CLAIM, role: "editor"}).claim,
		])
		viewer: (#ProjectRoleGroupPath & {project: CLAIM, role: "viewer"}).claim
		reads: ["GET", "HEAD"]
	}

	// Viewers are the Planboard projects the viewer group may open, the
	// binding's values.planboard.access.viewers.projects.
	let Viewers = list.SortStrings(Read.values.access.viewers.projects)

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
			// (ProxyArgs), and the waypoint removes them again (Lua).
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
			// is still open: in an ambient namespace a NetworkPolicy sees
			// ztunnel's HBONE on 15008, and the ingress Gateway's address for
			// Keycloak, not the path through the waypoint, so narrowing it
			// needs a spike of its own (README.md, The board's login).
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

			// The waypoint Deployment's customization, which istiod merges into
			// the Deployment it generates: the private root, from trust-manager's
			// ConfigMap, which every namespace has, read-only in the proxy, for
			// the DestinationRule to check the shim's certificate against. A
			// mounted file rather than a DestinationRule's credentialName, which
			// would need the root copied into a Secret, and trust-manager writes
			// ConfigMaps alone here.
			ConfigMap: (Waypoint.parameters): {
				metadata: {
					namespace: CLAIM
					labels:    Labels
				}
				data: deployment: yaml.Marshal({
					spec: template: spec: {
						containers: [{
							name: "istio-proxy"
							volumeMounts: [{name: "private-ca", mountPath: CAMount, readOnly: true}]
						}]
						volumes: [{name: "private-ca", configMap: name: PrivateCA.bundle}]
					}
				})
			}

			// The waypoint, for Services and ServiceEntries that name it, of
			// which there is one, ShimEntry. One HBONE listener, which is how
			// ztunnel hands it a connection. The class is the claim's
			// waypointClass, Istio's waypoint unless the claim says otherwise.
			Gateway: (Waypoint.name): {
				metadata: {
					namespace: CLAIM
					labels: Labels & {"istio.io/waypoint-for": "service"}
				}
				spec: {
					gatewayClassName: Waypoint.class
					infrastructure: parametersRef: {
						group: ""
						kind:  "ConfigMap"
						name:  Waypoint.parameters
					}
					listeners: [{name: "mesh", port: 15008, protocol: "HBONE"}]
				}
			}

			// The board's shim hostname in the claim's namespace: an address
			// of the mesh's, which ztunnel's DNS proxy answers the hostname
			// with for the namespace's pods, behind the waypoint. Port 80 is
			// plain HTTP, the login's upstream, sent to the shim Gateway's
			// Service on 443 once the waypoint has originated TLS. Exported to
			// the claim's namespace alone. A pod there that dials the
			// hostname's https port gets this address too, and fails its TLS
			// handshake (README.md, The board's login).
			ServiceEntry: (ShimEntry.name): {
				metadata: {
					namespace: CLAIM
					labels: Labels & {"istio.io/use-waypoint": Waypoint.name}
				}
				spec: {
					hosts: [ActorHost]
					exportTo: ["."]
					location:   "MESH_EXTERNAL"
					resolution: "DNS"
					ports: [{number: 80, name: "http", protocol: "HTTP", targetPort: 443}]
					endpoints: [{address: ShimEntry.endpoint}]
				}
			}

			// TLS from the waypoint to the shim: the actor's hostname as SNI,
			// which picks the claim's listener on the shim Gateway, and the
			// shim's certificate checked for that name against the private
			// root the waypoint mounts. One-way, since the shim takes the
			// user's token, not the waypoint's identity. Exported to the
			// claim's namespace alone, where the waypoint is the proxy that
			// dials the hostname.
			DestinationRule: (ShimEntry.name): {
				metadata: {
					namespace: CLAIM
					labels:    Labels
				}
				spec: {
					host: ActorHost
					exportTo: ["."]
					trafficPolicy: tls: {
						mode: "SIMPLE"
						sni:  ActorHost
						subjectAltNames: [ActorHost]
						caCertificates: "\(CAMount)/\(PrivateCA.bundleKey)"
					}
				}
			}

			// The waypoint admits nothing on its own. An ALLOW policy with no
			// rules matches no request, and once a workload has an ALLOW
			// policy, a request no ALLOW rule matches is refused, so the
			// owner's policy (the project bucket, below) only adds to this.
			// Without it, the waypoint would admit any request with a valid
			// token, every viewer to every project and to the agent's routes,
			// from the moment this Application makes the ServiceEntry until
			// the claim's Application syncs the policy, or for as long as that
			// sync fails.
			AuthorizationPolicy: (Waypoint.name): {
				metadata: {
					namespace: CLAIM
					labels:    Labels
				}
				spec: {
					targetRefs: [Waypoint.ref]
					action: "ALLOW"
				}
			}

			// The project header and the strip (Lua, above), at the AUTHZ
			// phase, stated, since an unphased filter would run after the
			// policy and the policy would never see the header.
			TrafficExtension: (Waypoint.name): {
				metadata: {
					namespace: CLAIM
					labels:    Labels
				}
				spec: {
					targetRefs: [Waypoint.ref]
					phase: "AUTHZ"
					lua: inlineCode: Lua
				}
			}
		}

		// The waypoint's policy, the owner's to edit live (overview §6), so
		// in the claim's own Application, where self-heal off leaves an edit
		// in place and self-heal on returns it to this.
		project: {
			// A bearer token, if the request carries one, must be a Keycloak ID
			// token from the realm for the board's client, the token the login
			// forwards; any other bearer token is 401. A request without one,
			// or whose Authorization is not a bearer token, passes here as
			// anonymous and is refused by the AuthorizationPolicy. The token is
			// forwarded, since the shim verifies it again.
			RequestAuthentication: planboard: {
				metadata: {
					namespace: CLAIM
					labels:    Labels
				}
				spec: {
					targetRefs: [Waypoint.ref]
					jwtRules: [{
						issuer: Keycloak.issuer
						audiences: [Login.client]
						fromHeaders: [{name: "Authorization", prefix: "Bearer "}]
						forwardOriginalToken: true
					}]
				}
			}

			// Who reads what of the board (Policy, above). Planboard v0.0.1's
			// routes (server/handler.go) are the UI shell at / and the
			// project-less research library's /research/<slug>/raw/<name>,
			// which the first viewer rule admits as everything outside /api/,
			// /files/ and /present/; the API, of which every GET but
			// /api/document names no project, and GET /api/agent is the
			// agent's card, while POST /api/agent/turn and /api/agent/render
			// drive the agent and stay closed to viewers; and /files/<project>/
			// and /present/<project>/, a project's files and decks, by path.
			// /api/projects returns nearly every project's text whatever this
			// says about /api/document, and the UI cannot start without it, a
			// leak taken as Planboard has it. Istio resolves a .. before the
			// match, and Go's mux answers any other unclean path with a
			// redirect to the clean one, which comes back through here. The
			// mesh's path normalization leaves a %2F encoded, though, so
			// /files/<P>/..%2F<Q>/x matches <P>'s prefix and reaches Planboard
			// with ../<Q>/x as its path; Planboard refuses it, since it checks
			// every segment of a project's path and refuses a .. or a /
			// (server/images.go, servedPath). The project rules render only
			// when the binding lists projects.
			AuthorizationPolicy: planboard: {
				metadata: {
					namespace: CLAIM
					labels:    Labels
				}
				spec: {
					targetRefs: [Waypoint.ref]
					action: "ALLOW"
					rules: [
						{
							from: Policy.from
							when: [{key: Policy.groups, values: Policy.writers}]
						},
						{
							from: Policy.from
							to: [
								{operation: {
									methods: Policy.reads
									notPaths: ["/api/*", "/files/*", "/present/*"]
								}},
								{operation: {
									methods: Policy.reads
									paths: list.SortStrings([
										"/api/projects",
										"/api/events",
										"/api/catalog",
										"/api/research",
										"/api/research/*",
										"/api/agent",
									])
								}},
							]
							when: [{key: Policy.groups, values: [Policy.viewer]}]
						},
						if len(Viewers) > 0 {
							from: Policy.from
							to: [{operation: {methods: Policy.reads, paths: ["/api/document"]}}]
							when: [
								{key: Policy.groups, values: [Policy.viewer]},
								{key: "request.headers[\(ProjectHeader)]", values: Viewers},
							]
						},
						if len(Viewers) > 0 {
							from: Policy.from
							to: [{operation: {
								methods: Policy.reads
								paths: list.SortStrings([for P in Viewers for D in ["files", "present"] {"/\(D)/\(P)/*"}])
							}}]
							when: [{key: Policy.groups, values: [Policy.viewer]}]
						},
					]
				}
			}
		}
	}).artifacts
}
