@extern(embed)
package holos

import (
	"list"
	"strings"
)

// keycloak-realm is the platform's realm, holos, at issuer
// https://keycloak.bank.internal/realms/holos, in two halves, because
// holos-controller 0.22.0 has no kind for a realm, a client scope or a
// protocol mapper, and no field for the device grant (interview Q50):
//
//   - A KeycloakRealmImport creates the realm with what the controller cannot
//     reconcile: the groups client scope, the kubectl, argocd and
//     svc-holos-controller clients, svc-holos-controller's admin roles, the
//     user jeff and the service user svc-quay-controller. The Keycloak Operator imports it once, when the realm
//     does not exist, and never again: a change to it here reaches a running
//     cluster only by deleting the realm and the import (README.md, "The
//     realm").
//   - holos-controller's resources, reconciled for as long as they exist: the
//     Instance every other resource names, the group /platform/owners, and
//     jeff's membership in it. Later items add their own Clients and Groups
//     against the same Instance.
//
// It also writes the credential holos-controller calls the admin API with,
// and the PostSync Job that gives the Instance the private root (Q52).
//
// Three secrets are generated here (#GeneratedSecret), in Keycloak's
// namespace, because the import's placeholders read Secrets in the import's
// own namespace alone:
//
//   - svc-holos-controller, a login whose username is the client ID and whose
//     password is the client's secret.
//   - holos-user-jeff, jeff's login.
//   - svc-quay-controller, the Quay superuser's login, which
//     cmd/quay-bootstrap reads to mint holos-controller's Quay token.
//
// The controller reads its credential from its own namespace, so an
// ExternalSecret copies svc-holos-controller there as
// holos-controller-keycloak-creds, with the keys the controller reads,
// clientId and clientSecret, through a per-namespace store
// (#ScopedSecretStore), a SecretStore of External Secrets' kubernetes
// provider allowed to read that one Secret in keycloak and nothing else.
// The value is generated once, in one place, and the import and the
// controller read the same one; the copy follows the source within the hour
// should it ever be rotated, or at once with a forced refresh.
//
// Every resource here is in a namespace earlier components made, keycloak or
// holos-controller, and every kind's CRD comes from an earlier component:
// KeycloakRealmImport from keycloak-operator, the keycloak.holos.run kinds
// from holos-controller, ExternalSecret and SecretStore from
// external-secrets.

let KC = Keycloak
let HC = HolosController
let Namespace = KC.namespace

// Clients names the realm's client IDs (components/keycloak.cue).
let Clients = KC.clients

// ControllerSecret is svc-holos-controller's generated login, and
// UserSecret jeff's.
let ControllerSecret = Clients.controller
let UserSecret = "holos-user-jeff"

// QuayUser is the service user Quay's SUPER_USERS names and
// cmd/quay-bootstrap logs in to Quay as (components/quay.cue, interview
// Q57a). It logs in through Quay's own Keycloak flow, with the realm's
// ordinary login form, so it is a user with a password rather than a
// client. Its first and last name and its verified email are set, so
// Keycloak's VERIFY_PROFILE form never stands between the program and a
// session. Its Secret is named after it.
let QuayUser = Quay.controller

// The milestone's user (interview Q6). Its group membership is the
// controller's, below, not the import's.
let User = {
	username:  "jeff"
	email:     "jeff@bank.internal"
	firstName: "Jeff"
	lastName:  "McCune"
}

// Owners is the group whose members are Argo CD admins (components/argocd),
// Keycloak.groups.owners, which the Substrate shim's policy reads too. The
// controller takes the path with or without its leading slash and creates
// the parent, platform, if it is missing; the claim carries the full path,
// /platform/owners. The Group is given it without the slash, as it always
// has been.
let Owners = {
	name: KC.groups.owners.name
	path: strings.TrimPrefix(KC.groups.owners.path, "/")
}

// BuiltinClientScopes are the client scopes Keycloak 26.8.1 creates in a new
// realm, as the admin API returns the master realm's on treasury, ids
// removed. A realm import that lists any client scope gets none of these:
// Keycloak creates its defaults only when the import's clientScopes is
// absent (RealmManager.importRealm), and the groups scope must be listed. So
// they are listed beside it, as a realm created without them would have them.
// A Keycloak upgrade that adds a default scope does not add it to a realm
// already imported, here or anywhere.
_builtinClientScopes: _ @embed(file="client-scopes.json")
let BuiltinClientScopes = _builtinClientScopes

// The realm's default client scopes, which every client in the realm,
// including the ones holos-controller creates later, gets unless it names its
// own: Keycloak's defaults, as for master, and groups as a default default
// scope, so every token carries the groups claim without a mapper of its own.
let DefaultScopes = ["role_list", "saml_organization", "AuthnContextClassRef", "profile", "email", "roles", "web-origins", "acr", "basic", "groups"]
let OptionalScopes = ["offline_access", "address", "phone", "microprofile-jwt", "organization"]

// Placeholders are the import's environment variables, which the operator
// sets on its import Job from the Secrets named, and which Keycloak puts in
// place of ${NAME} in the realm as it imports it. The values are never in
// the resource or in git.
let Placeholders = {
	SVC_HOLOS_CONTROLLER_CLIENT_SECRET: secret: {name: ControllerSecret, key: "password"}
	JEFF_PASSWORD: secret: {name: UserSecret, key: "password"}
	SVC_QUAY_CONTROLLER_PASSWORD: secret: {name: QuayUser.username, key: "password"}
}

// ArgoCDURL is Argo CD's URL, the base of its redirects.
let ArgoCDURL = "https://\(IngressGateway.hosts.argocd)"

// CABundle is the PostSync Job that writes the private root into the
// Instance's caBundle, its ServiceAccount and Role.
let CABundle = "instance-cabundle"

// KubectlImage is alpine/kubectl at the cluster's Kubernetes version, which
// has a shell for the Job's script, pinned by index digest.
let KubectlImage = "docker.io/alpine/kubectl:1.37.1@sha256:a5d0fbecab3f7b6c2ab7398f1daa73a3e0ed6ece18556d21698233e9e3759cc7"

holos: spec: artifacts: [(#ResourcesArtifact & {
	resources: {
		// The realm (Q50). The operator runs a Job from the server's image
		// that imports it straight into the database, with
		// override=false: an existing realm is left as it is, so this
		// imports once. Its status reports Done; a failed import's Job
		// stays for its logs.
		KeycloakRealmImport: (KC.realm): {
			metadata: namespace: Namespace
			spec: {
				keycloakCRName: KC.name
				placeholders:   Placeholders
				realm: {
					realm:       KC.realm
					displayName: "Holos"
					enabled:     true
					// TLS ends at the gateway, which sets
					// X-Forwarded-Proto, so every request arrives as
					// https. Logins are by email or username; nobody
					// registers themselves.
					sslRequired:            "external"
					registrationAllowed:    false
					loginWithEmailAllowed:  true
					duplicateEmailsAllowed: false

					clientScopes: list.Concat([BuiltinClientScopes, [{
						// The groups scope (Q6): each user's groups, by
						// full path, in the ID token, the access token
						// and userinfo, under the claim groups. A realm
						// default default scope, so it is in every
						// client's tokens, the controller's clients
						// included, and a client may ask for it by name,
						// as Argo CD does.
						name:        KC.groupsClaim
						description: "Group membership, by full path"
						protocol:    "openid-connect"
						attributes: {
							"include.in.token.scope":    "true"
							"display.on.consent.screen": "false"
						}
						protocolMappers: [{
							name:            KC.groupsClaim
							protocol:        "openid-connect"
							protocolMapper:  "oidc-group-membership-mapper"
							consentRequired: false
							config: {
								"claim.name":                KC.groupsClaim
								"full.path":                 "true"
								"id.token.claim":            "true"
								"access.token.claim":        "true"
								"userinfo.token.claim":      "true"
								"introspection.token.claim": "true"
							}
						}]
					}]])
					defaultDefaultClientScopes:  DefaultScopes
					defaultOptionalClientScopes: OptionalScopes

					clients: [
						{
							// kubectl: a person's login for the
							// cluster, through the device grant, or
							// kubelogin's authorization code with PKCE
							// on a loopback listener (RFC 8252), which
							// it defaults to ports 8000 and 18000 for;
							// both loopback spellings, since which one
							// the browser returns depends on how the
							// host resolves localhost. Public, so no
							// secret, no client credentials, no
							// password grant. Its client ID is the
							// audience the Substrate shim pins: the ID
							// token's aud.
							//
							// PKCE is not required here, unlike argocd.
							// Keycloak 26.8.1 applies a client's
							// pkce.code.challenge.method to the device
							// grant too, and refuses a device
							// authorization request without a
							// code_challenge, which RFC 8628 clients
							// such as kubelogin's device-code mode do
							// not all send. kubelogin's authorization
							// code flow sends PKCE on its own when the
							// issuer advertises S256, as this one does.
							clientId:                  Clients.kubectl
							name:                      "kubectl"
							enabled:                   true
							protocol:                  "openid-connect"
							publicClient:              true
							standardFlowEnabled:       true
							implicitFlowEnabled:       false
							directAccessGrantsEnabled: false
							serviceAccountsEnabled:    false
							redirectUris: [
								"http://localhost:8000",
								"http://localhost:18000",
								"http://127.0.0.1:8000",
								"http://127.0.0.1:18000",
							]
							attributes: "oauth2.device.authorization.grant.enabled": "true"
						},
						{
							// argocd: Argo CD's UI and CLI, a public
							// client with PKCE, S256 (Q51): neither can
							// keep a secret. The UI's redirect is
							// /pkce/verify, where its browser code
							// finishes the exchange, and
							// /auth/callback the server's; the CLI's
							// `argocd login --sso` listens on
							// localhost:8085. The UI calls the token
							// endpoint from the browser, so its origin
							// is allowed.
							clientId:                  Clients.argocd
							name:                      "Argo CD"
							enabled:                   true
							protocol:                  "openid-connect"
							publicClient:              true
							standardFlowEnabled:       true
							implicitFlowEnabled:       false
							directAccessGrantsEnabled: false
							serviceAccountsEnabled:    false
							rootUrl:                   ArgoCDURL
							baseUrl:                   "/applications"
							redirectUris: [
								"\(ArgoCDURL)/auth/callback",
								"\(ArgoCDURL)/pkce/verify",
								"http://localhost:8085/auth/callback",
							]
							webOrigins: [ArgoCDURL]
							attributes: {
								"pkce.code.challenge.method": "S256"
								"post.logout.redirect.uris":  "\(ArgoCDURL)/applications"
							}
						},
						{
							// svc-holos-controller: holos-controller's
							// own login, client credentials alone. Its
							// secret is the generated one, through
							// the placeholder.
							clientId:                  Clients.controller
							name:                      "holos-controller"
							enabled:                   true
							protocol:                  "openid-connect"
							publicClient:              false
							clientAuthenticatorType:   "client-secret"
							secret:                    "${SVC_HOLOS_CONTROLLER_CLIENT_SECRET}"
							standardFlowEnabled:       false
							implicitFlowEnabled:       false
							directAccessGrantsEnabled: false
							serviceAccountsEnabled:    true
						},
					]

					users: [
						{
							// svc-holos-controller's service account
							// user, with the realm-management roles
							// the controller's kinds need: clients
							// (manage-clients, query-clients),
							// groups, users and memberships
							// (manage-users, query-groups).
							// manage-realm, which aavis-ops also
							// grants, is left out: it is there only
							// for a Group's custodians, which
							// delegate membership through
							// fine-grained admin permissions (FGAP
							// v2, adminPermissionsEnabled) and amount
							// to administering the realm. Nothing
							// here sets custodians, so FGAP stays
							// off; an item that needs them adds both.
							username:               "service-account-\(Clients.controller)"
							enabled:                true
							serviceAccountClientId: Clients.controller
							clientRoles: "realm-management": [
								"manage-clients",
								"manage-users",
								"query-clients",
								"query-groups",
							]
						},
						User & {
							enabled:       true
							emailVerified: true
							// An imported user gets only the roles
							// it lists, not the realm's default
							// role, and without its offline_access
							// Keycloak refuses the Secrets Manager's
							// login, which asks for that scope.
							realmRoles: ["default-roles-\(KC.realm)"]
							credentials: [{
								type:      "password"
								value:     "${JEFF_PASSWORD}"
								temporary: false
							}]
						},
						QuayUser & {
							// The import is one-shot, so on a realm
							// imported before this user was added it is
							// created once by hand, through the admin API
							// (README.md, Quay). It holds the realm's
							// default role, as jeff does, and no group:
							// Quay makes it a superuser by name.
							enabled:       true
							emailVerified: true
							realmRoles: ["default-roles-\(KC.realm)"]
							credentials: [{
								type:      "password"
								value:     "${SVC_QUAY_CONTROLLER_PASSWORD}"
								temporary: false
							}]
						},
					]
				}
			}
		}

		// The Instance every keycloak.holos.run resource names: the realm
		// at Keycloak's public URL, through the gateway, whose
		// certificate is the private CA's. Its caBundle is the private
		// root, which the PostSync Job below writes, since the root is
		// minted in the cluster and is not in git (Q52); Argo CD ignores
		// the field (registry.cue). Until the Job has run, the Instance
		// reports a TLS error. The credential Secret is resolved in the
		// controller's own namespace, whatever the Instance's.
		Instance: (HC.instance.name): {
			metadata: namespace: HC.instance.namespace
			spec: {
				url:   KC.url
				realm: KC.realm
				credentialsSecretRef: name: HC.credentials
			}
		}

		// /platform/owners, whose members are Argo CD admins. In the
		// Instance's namespace, so no ReferenceGrant: a reference within
		// a namespace needs none.
		Group: (Owners.name): {
			metadata: namespace: HC.instance.namespace
			spec: {
				path: Owners.path
				instanceRef: name: HC.instance.name
			}
		}

		// jeff in /platform/owners. The controller finds a member by
		// email among the realm's users, so the user the import created
		// is enough, and no User resource is needed.
		GroupMembership: (Owners.name): {
			metadata: namespace: HC.instance.namespace
			spec: {
				instanceRef: name: HC.instance.name
				groupRef: name:    Owners.name
				members: [{email: User.email}]
			}
		}

		// holos-controller-keycloak-creds, the keys the controller reads
		// from svc-holos-controller's username and password. Not
		// immutable, unlike its source: it is a copy, and follows the
		// source.
		ExternalSecret: (HC.credentials): {
			metadata: namespace: HC.namespace
			spec: {
				refreshInterval: "1h"
				secretStoreRef: {kind: "SecretStore", name: "keycloak"}
				target: {
					name:           HC.credentials
					creationPolicy: "Owner"
					template: {
						engineVersion: "v2"
						mergePolicy:   "Replace"
						data: {
							clientId:     "{{ .username }}"
							clientSecret: "{{ .password }}"
						}
					}
				}
				dataFrom: [{extract: key: ControllerSecret}]
			}
		}

		// instance-cabundle writes the private root, from trust-manager's
		// private-ca ConfigMap in this namespace, into the Instance's
		// caBundle (Q52), base64 as the field's format: byte asks. It
		// runs after every sync, as an Argo CD PostSync hook, deleted and
		// re-created each time (BeforeHookCreation), and deleted once it
		// succeeds (HookSucceeded); a failed one stays for its logs. The
		// patch is a merge patch under its own field manager, which Argo
		// CD's server-side apply, not owning the field, leaves alone.
		ServiceAccount: (CABundle): metadata: namespace: Namespace
		Role: (CABundle): {
			metadata: namespace: Namespace
			rules: [{
				apiGroups: ["keycloak.holos.run"]
				resources: ["instances"]
				resourceNames: [HC.instance.name]
				verbs: ["get", "patch"]
			}]
		}
		RoleBinding: (CABundle): {
			metadata: namespace: Namespace
			roleRef: {
				apiGroup: "rbac.authorization.k8s.io"
				kind:     "Role"
				name:     CABundle
			}
			subjects: [{
				kind:      "ServiceAccount"
				name:      CABundle
				namespace: Namespace
			}]
		}
		Job: (CABundle): {
			metadata: {
				namespace: Namespace
				annotations: {
					"argocd.argoproj.io/hook":               "PostSync"
					"argocd.argoproj.io/hook-delete-policy": "BeforeHookCreation,HookSucceeded"
				}
			}
			spec: {
				backoffLimit:          6
				activeDeadlineSeconds: 300
				template: spec: {
					restartPolicy:      "OnFailure"
					serviceAccountName: CABundle
					securityContext: {
						runAsNonRoot: true
						runAsUser:    65534
						runAsGroup:   65534
						seccompProfile: type: "RuntimeDefault"
					}
					containers: [{
						name:  "patch"
						image: KubectlImage
						command: ["/bin/sh", "-c", CABundleScript]
						env: [{name: "HOME", value: "/tmp"}]
						volumeMounts: [
							{name: "private-ca", mountPath: "/private-ca", readOnly: true},
							{name: "tmp", mountPath: "/tmp"},
						]
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
					volumes: [
						{name: "private-ca", configMap: name: PrivateCA.bundle},
						{name: "tmp", emptyDir: {}},
					]
				}
			}
		}
	}

	// The copy of svc-holos-controller into the controller's namespace,
	// through a per-namespace store (#ScopedSecretStore) whose
	// ServiceAccount, keycloak-secret-reader, may get that one Secret in
	// keycloak. The reader keeps the name it had before the definition
	// existed, rather than the default, holos-controller-keycloak-reader,
	// so the render and the cluster do not change.
	resources: (#ScopedSecretStore & {
		name:      "keycloak"
		namespace: HC.namespace
		source:    Namespace
		secrets: [ControllerSecret]
		reader: "keycloak-secret-reader"
	}).resources

	resources: (#GeneratedSecret & {
		name:      ControllerSecret
		namespace: Namespace
		username:  Clients.controller
	}).resources

	resources: (#GeneratedSecret & {
		name:      UserSecret
		namespace: Namespace
		username:  User.username
	}).resources

	resources: (#GeneratedSecret & {
		name:      QuayUser.username
		namespace: Namespace
		username:  QuayUser.username
	}).resources
}).artifact]

// CABundleScript patches the Instance's caBundle with the private root, the
// PEM base64-encoded on one line.
let CABundleScript = strings.Join([
	"set -eu",
	"ca=$(base64 < /private-ca/\(PrivateCA.bundleKey) | tr -d '\\n')",
	"kubectl -n \(HC.instance.namespace) patch instances.keycloak.holos.run \(HC.instance.name) --type=merge --field-manager=\(CABundle) -p \"{\\\"spec\\\":{\\\"caBundle\\\":\\\"$ca\\\"}}\"",
], "\n")
