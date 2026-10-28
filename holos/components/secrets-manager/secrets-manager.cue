package holos

// secrets-manager is the Holos Secrets Manager (interview Q18), at
// https://secrets.bank.internal: a Go server with a web UI that manages
// Kubernetes Secrets directly, with Keycloak login and project grants, so
// there is no external store. A platform secret is made here, in the
// management namespace holos-prj-platform (Q54), which management-namespaces
// renders, early in the registry, and copied into each consumer's namespace
// by an ExternalSecret through that consumer's per-namespace store
// (#ScopedSecretStore).
//
// SecretsManager (components/secrets-manager.cue) holds the release, the
// names and the URL. The server is one Deployment of the release's
// distroless image, serving plain HTTP on 8080 behind the ingress gateway,
// which terminates TLS as it does for Keycloak, in the mesh namespace
// secrets-manager. It keeps no state of its own beyond Namespaces and
// Secrets: a project is a Namespace named holos-prj-<project> with its
// labels, and every grant is a JSON annotation on a Namespace or a Secret.
//
// Login is OIDC against the realm holos, through the public client
// secrets-manager, which a holos-controller Client here creates. The SPA
// runs the authorization code flow with PKCE in the browser and sends a
// token as its bearer to the server's API, which verifies it as an ID token:
// iss the realm's issuer, aud the client ID, and the person's groups from
// the claim groups. Holos services authenticate a person with the ID token,
// never the access token (Q53, ADR 0002).
//
// Platform owners alone create organizations (Q55), and own the platform
// organization and project. A project grant never cascades to reading a
// secret's data: reading needs a grant on the secret itself, which the
// platform project's default grant (components/management-namespaces) puts
// on every new secret for platform owners. A project owner may still share a
// secret to themselves, and so read it.
//
// Every kind's CRD comes from an earlier component: Client and the
// security.holos.run ReferenceGrant from holos-controller, HTTPRoute from
// gateway-api. The Instance the Client names is keycloak-realm's.

let SM = SecretsManager
let NS = SM.namespace
let Name = SM.name
let Labels = {"app.kubernetes.io/name": Name}

// CAMount is where trust-manager's private-ca ConfigMap is mounted, and
// CACert the private root's path in it. The server adds the root to the
// system pool for its calls to the issuer, discovery and JWKS, through the
// gateway, whose certificate the private CA issues.
let CAMount = "/etc/ssl/private-ca"
let CACert = "\(CAMount)/\(PrivateCA.bundleKey)"

holos: spec: artifacts: [(#ResourcesArtifact & {
	resources: {
		Namespace: (NS): metadata: labels: Istio.ambient

		// The server acts as its own ServiceAccount and impersonates no
		// one. It reads and writes Secrets only in project namespaces,
		// holos-prj-<project>, and in this distro those come from git, as
		// organizations come only from platform owners (Q55). So its access
		// is two ClusterRoles:
		//
		//   - Name, bound cluster wide: namespaces, to list, read, make,
		//     update and delete organizations and projects, which are
		//     Namespaces the server may make at runtime.
		//   - SM.secretsRole, secrets, bound by a RoleBinding in each
		//     project namespace git renders, beside the namespace
		//     (components/management-namespaces), so holos-prj-platform
		//     alone for now.
		//
		// The cost: a project made in the UI has a namespace but no access
		// to its secrets, and the UI fails on them, until git adds its
		// RoleBinding; the ProjectClaim collection renders those later. The
		// namespace writes are still cluster wide: the ServiceAccount may
		// update or delete any Namespace in the cluster, and deleting one
		// deletes everything in it, Keycloak's included. A
		// ValidatingAdmissionPolicy holding its namespace writes to holos-
		// namespaces with the server's labels is open hardening.
		ServiceAccount: (Name): metadata: namespace: NS
		ClusterRole: (Name): rules: [{
			apiGroups: [""]
			resources: ["namespaces"]
			verbs: ["get", "list", "create", "update", "delete"]
		}]
		ClusterRole: (SM.secretsRole): rules: [{
			apiGroups: [""]
			resources: ["secrets"]
			verbs: ["get", "list", "create", "update", "delete"]
		}]
		ClusterRoleBinding: (Name): {
			roleRef: {
				apiGroup: "rbac.authorization.k8s.io"
				kind:     "ClusterRole"
				name:     Name
			}
			subjects: [{
				kind:      "ServiceAccount"
				name:      Name
				namespace: NS
			}]
		}

		Deployment: (Name): {
			metadata: namespace: NS
			spec: {
				// One replica: the server is stateless, and one is the
				// base's size.
				replicas: 1
				selector: matchLabels: Labels
				template: {
					metadata: labels: Labels
					spec: {
						serviceAccountName: Name
						securityContext: {
							runAsNonRoot: true
							runAsUser:    65532
							runAsGroup:   65532
							seccompProfile: type: "RuntimeDefault"
						}
						containers: [{
							name:  Name
							image: SM.image
							args:  Args
							ports: [{name: "http", containerPort: SM.port}]
							// The kubelet's probes reach an ambient pod from
							// 169.254.7.127, which cilium-resources' policy
							// admits. /readyz answers once the server has
							// read its configuration and is about to listen.
							livenessProbe: httpGet: {
								path: "/healthz"
								port: "http"
							}
							readinessProbe: httpGet: {
								path: "/readyz"
								port: "http"
							}
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
						// Not optional, unlike Argo CD's: trust-manager
						// comes earlier in the registry, and without the
						// root the server cannot reach the issuer, so the
						// pod waits for it.
						volumes: [{name: "private-ca", configMap: name: PrivateCA.bundle}]
					}
				}
			}
		}

		Service: (Name): {
			metadata: namespace: NS
			spec: {
				selector: Labels
				ports: [{name: "http", port: SM.port, targetPort: "http"}]
			}
		}

		// The server serves /metrics, Prometheus's, unauthenticated, on the
		// same port as the UI and the API, so the route does not forward
		// it. Of a request's rules the one with the longest matching path
		// prefix wins, so /metrics and everything under it meets the first
		// rule, which has no backend: the Gateway API answers such a rule
		// with a 500, and the request never reaches the server. Everything
		// else meets the second. The gateway normalizes the path before it
		// matches, decoding escapes such as /%6Detrics and removing dot
		// segments; the server's mux redirects //metrics to /metrics, which
		// then meets the first rule. A metrics scraper in the cluster calls
		// the Service directly.
		HTTPRoute: (Name): {
			metadata: namespace: NS
			spec: {
				parentRefs: [IngressGateway.parentRef]
				hostnames: [IngressGateway.hosts.secrets]
				rules: [
					{matches: [{path: {type: "PathPrefix", value: "/metrics"}}]},
					{backendRefs: [{name: Name, port: SM.port}]},
				]
			}
		}

		// The SPA's client: public, so no secret, with the standard flow
		// alone. Its redirect is /pkce/verify, where the SPA finishes the
		// exchange, and its web origin is the server's, since the SPA calls
		// the token endpoint from the browser. The SPA sends PKCE, S256, on
		// its own; the Client has no field to require it, nor one for a
		// post-logout redirect, so logging out ends on Keycloak's page
		// rather than back at the UI. The client gets the realm's default
		// scopes, groups among them, and offline_access as an optional
		// one, which the SPA asks for by name with openid, profile, email
		// and groups.
		Client: (Name): {
			metadata: namespace: NS
			spec: {
				clientId:    SM.clientId
				type:        "public"
				description: "Holos Secrets Manager"
				instanceRef: HolosController.instance
				redirectUris: ["\(SM.url)/pkce/verify"]
				webOrigins: [SM.url]
			}
		}

		// The Client names the Instance in keycloak, another namespace,
		// which holos-controller allows only with a ReferenceGrant there,
		// from Clients in this namespace to that one Instance.
		ReferenceGrant: "\(Name)-clients": {
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
	}
}).artifact]

// Args are the server's flags (cli/cli.go at the release):
//
//   - --plain-http on :8080, since TLS ends at the gateway.
//   - --origin, the public URL, from which the server derives the redirect
//     and post-logout URIs it hands the SPA.
//   - --issuer, the realm's. It must always be set: an empty issuer turns
//     authentication off.
//   - --client-id, the aud every ID token must carry.
//   - --ca-cert, the private root, added to the system pool.
//   - --roles-claim, the claim a person's roles, their groups by full path,
//     are read from.
//   - --disable-org-creation with --org-creator-roles: only platform owners
//     create organizations (Q55). Without the first, anyone who logs in may.
//
// Never --enable-insecure-dex, the embedded identity provider with
// auto-login, which is for local development alone.
let Args = [
	"--plain-http",
	"--listen=:\(SM.port)",
	"--origin=\(SM.url)",
	"--issuer=\(Keycloak.issuer)",
	"--client-id=\(SM.clientId)",
	"--ca-cert=\(CACert)",
	"--roles-claim=\(Keycloak.groupsClaim)",
	"--disable-org-creation",
	"--org-creator-roles=\(SM.owners)",
]
