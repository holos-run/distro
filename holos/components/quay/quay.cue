package holos

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/yaml"
	"strings"
)

// quay is the platform's registry (interview Q13, Q56, Q57 and Q59), at
// https://quay.bank.internal: Quay 3.17.6 as one plain Deployment, ported
// from aavis-ops' quay component, with no Quay Operator, no Clair, no mirror
// worker and no config editor. Its database is its own one-instance
// CloudNativePG cluster, its blobs are in RustFS's bucket quay, and its
// build-log and event queues are in an ephemeral Redis beside it. It holds
// the demo actor's image, public; the Substrate and kagent images are on
// ghcr.io (docs/forks.md).
//
// Quay (components/quay.cue) holds the release, the names and the URL. Quay
// serves plain HTTP on 8080 behind the ingress gateway, which terminates TLS
// as it does for Keycloak, in the mesh namespace quay. Login is OIDC against
// the realm holos, through the confidential client quay, which a
// holos-controller Client here creates; Keycloak is Quay's only identity
// store, and SUPER_USERS names the controller's realm user and jeff.
//
// Quay reads /conf/stack/config.yaml and substitutes no environment, so the
// ConfigMap holds a template and an init container writes the config into an
// emptyDir from the Secrets, which are generated in the cluster
// (#GeneratedSecret), copied from rustfs (#ScopedSecretStore) or delivered
// by the controller. Nothing secret is in git.
//
// holos-controller reconciles the demo Organization and its Repository here
// against Quay's API with an OAuth token minted by cmd/quay-bootstrap, which
// writes it as the platform secret quay-controller-token; this component
// copies that into the controller's namespace. Until bootstrap has run, the
// copy's ExternalSecret reports Degraded and so does the Application
// (registry.cue, README.md, Quay).
//
// Every kind's CRD comes from an earlier component: Cluster from
// cloudnative-pg, ExternalSecret, SecretStore and the generators from
// external-secrets, Client, Organization, Repository and the
// security.holos.run ReferenceGrant from holos-controller,
// AuthorizationPolicy from istio-base, HTTPRoute from gateway-api.

let Q = Quay
let NS = Q.namespace
let Name = Q.name
let Labels = {"app.kubernetes.io/name": Name}

// DB is the CloudNativePG cluster's name and its owner's Secret's.
// CloudNativePG names its read-write Service <name>-rw. The database and its
// owner are both quay.
let DB = "quay-db"
let Database = "quay"
let Owner = "quay"

// PostgreSQLImage is keycloak's, CloudNativePG 1.30.1's default, PostgreSQL
// 18.6, stated so an operator upgrade does not move the database to a new
// major version by itself.
let PostgreSQLImage = "ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie"

// SecretKeys is the Secret holding Quay's SECRET_KEY and DATABASE_SECRET_KEY.
let SecretKeys = "quay-secret-keys"

// Redis is Quay's queue for build logs and user events, which Quay requires
// even with builds off. The image is pinned by index digest.
let Redis = {
	name:  "quay-redis"
	port:  6379
	image: "docker.io/library/redis:8.6.8-alpine@sha256:7d8d9a58ab3ef32025b06c9f9aeb273d0fb82a79f13d63658e7d7e56ee2f032c"
	labels: {"app.kubernetes.io/name": name}
}

// RustFS is the blob store: rustfs-svc in rustfs (components/rustfs), the
// bucket and the keys its Job registers for Quay. The host is fully
// qualified: Quay's nginx resolves a proxied storage URL through the pod's
// dnsmasq without the search path (FEATURE_PROXY_STORAGE, below).
let RustFS = {
	namespace: "rustfs"
	host:      "rustfs-svc.\(namespace).svc.cluster.local"
	port:      9000
	bucket:    "quay"
	keys:      "rustfs-\(bucket)"
}

// ConfigTemplate is the ConfigMap the init container reads, and CAMount
// where Quay's entrypoint picks up extra roots: it installs every file in
// /conf/stack/extra_ca_certs into the system trust and into certifi's
// bundle, which Python's requests uses for Quay's calls to Keycloak.
let ConfigTemplate = "quay-config-template"
let CAMount = "/conf/stack/extra_ca_certs"

// Config is Quay's config.yaml. The values in __NAME__ are placeholders the
// init container fills from Secrets (InitScript).
//
//   - EXTERNAL_TLS_TERMINATION: the gateway terminates TLS, and Quay writes
//     https URLs for SERVER_HOSTNAME.
//   - DISTRIBUTED_STORAGE_CONFIG: RadosGWStorage, the driver Quay documents
//     for any S3 endpoint at a host of its own, here RustFS over plain HTTP,
//     reached over HBONE, path-style, region us-east-1, SigV4.
//   - FEATURE_PROXY_STORAGE: a pull's blob request would otherwise be
//     redirected to a presigned URL on rustfs-svc, which neither the laptop
//     nor a worker's containerd can resolve. With it Quay redirects to
//     /_storage_proxy/ on its own host, and its nginx fetches the blob from
//     RustFS.
//   - AUTHENTICATION_TYPE OIDC, with the provider in KEYCLOAK_LOGIN_CONFIG:
//     Keycloak is the only identity store, FEATURE_DIRECT_LOGIN off removes
//     the password form, and a first login creates the user.
//     FEATURE_USERNAME_CONFIRMATION off takes preferred_username as it is,
//     so a user's Quay name is their realm username, which SUPER_USERS
//     matches.
//   - OIDC_SERVER is the realm's issuer with a trailing slash, which Quay
//     requires. LOGIN_SCOPES ask for groups, a realm default scope carrying
//     full paths, so teams sync from /platform/owners. USE_PKCE is off:
//     Quay 3.17 keeps the PKCE state in its CSRF cookie and does not clear it
//     on logout, so the next login fails with a 400 on the code exchange
//     (aavis-ops ADR-15). The Client sets no PKCE method, so Keycloak does
//     not require it.
//   - FEATURE_TEAM_SYNCING: a synced team's members are the users whose
//     groups claim named its group at their last login. Quay cannot list an
//     OIDC group's members, so its resync worker does nothing and
//     TEAM_RESYNC_STALE_TIME has no effect: a user taken out of the group
//     stays in the team until they next log in.
//   - FEATURE_SUPERUSERS_FULL_ACCESS: SUPER_USERS may administer
//     organizations they neither own nor belong to, so holos-controller,
//     acting as svc-quay-controller, can reconcile one somebody else made.
//     It widens jeff's session the same way.
//   - FEATURE_ANONYMOUS_ACCESS, Quay's default, stated: an anonymous pull
//     of a public repository, the demo actor's, works.
let Config = {
	SERVER_HOSTNAME:          Q.host
	PREFERRED_URL_SCHEME:     "https"
	EXTERNAL_TLS_TERMINATION: true
	SETUP_COMPLETE:           true
	TESTING:                  false
	REGISTRY_TITLE:           "Holos"
	REGISTRY_TITLE_SHORT:     "Holos"

	DB_URI:              "__DB_URI__"
	SECRET_KEY:          "__SECRET_KEY__"
	DATABASE_SECRET_KEY: "__DATABASE_SECRET_KEY__"

	BUILDLOGS_REDIS: {host: Redis.name, port: Redis.port}
	USER_EVENTS_REDIS: {host: Redis.name, port: Redis.port}

	DISTRIBUTED_STORAGE_CONFIG: rustfs: ["RadosGWStorage", {
		hostname:          RustFS.host
		port:              RustFS.port
		is_secure:         false
		bucket_name:       RustFS.bucket
		storage_path:      "/registry"
		access_key:        "__S3_ACCESS_KEY__"
		secret_key:        "__S3_SECRET_KEY__"
		region_name:       "us-east-1"
		signature_version: "s3v4"
	}]
	DISTRIBUTED_STORAGE_PREFERENCE: ["rustfs"]
	FEATURE_PROXY_STORAGE: true

	AUTHENTICATION_TYPE: "OIDC"
	KEYCLOAK_LOGIN_CONFIG: {
		SERVICE_NAME:  "Keycloak"
		OIDC_SERVER:   "\(Keycloak.issuer)/"
		CLIENT_ID:     Q.clientId
		CLIENT_SECRET: "__OIDC_CLIENT_SECRET__"
		LOGIN_SCOPES: ["openid", "profile", "email", Keycloak.groupsClaim]
		PREFERRED_USERNAME_CLAIM_NAME: "preferred_username"
		VERIFIED_EMAIL_CLAIM_NAME:     "email"
		PREFERRED_GROUP_CLAIM_NAME:    Keycloak.groupsClaim
		USE_PKCE:                      false
	}
	FEATURE_DIRECT_LOGIN:           false
	FEATURE_USER_CREATION:          true
	FEATURE_USERNAME_CONFIRMATION:  false
	FEATURE_TEAM_SYNCING:           true
	TEAM_RESYNC_STALE_TIME:         "30m"
	SUPER_USERS:                    Q.superUsers
	FEATURE_SUPERUSERS_FULL_ACCESS: true
	FEATURE_ANONYMOUS_ACCESS:       true
	FEATURE_MAILING:                false
	FEATURE_USER_LOG_ACCESS:        false
}

let ConfigYAML = yaml.Marshal(Config)

// ConfigHash is a short hash of the template, on the pod template, so a
// change to the config rolls the Deployment: the init container reads the
// template only at start.
let ConfigHash = strings.SliceRunes(hex.Encode(sha256.Sum256(ConfigYAML)), 0, 8)

// Placeholders are the init container's variables, by the placeholder each
// fills, and the Secret key each is read from.
let Placeholders = {
	DB_PASSWORD: {name: DB, key: "password"}
	SECRET_KEY: {name: SecretKeys, key: "SECRET_KEY"}
	DATABASE_SECRET_KEY: {name: SecretKeys, key: "DATABASE_SECRET_KEY"}
	OIDC_CLIENT_SECRET: Q.oidcSecret
	S3_ACCESS_KEY: {name: RustFS.keys, key: "access-key"}
	S3_SECRET_KEY: {name: RustFS.keys, key: "secret-key"}
}

// InitScript writes the config: every placeholder is replaced by its value
// as a JSON string, which is a YAML string whatever the value holds, and a
// placeholder missing from the template is an error rather than a config
// that silently lacks a value. DB_URI is built here from the owner's
// password, since CloudNativePG writes no URI for an initdb Secret it did not
// make; the password is letters and digits, so it needs no escaping. Python
// is the Quay image's own, so the init container needs no second image.
let InitScript = """
	import json, os

	env = os.environ
	values = {
	    "DB_URI": "postgresql://\(Owner):%s@\(DB)-rw:5432/\(Database)" % env["DB_PASSWORD"],
	    "SECRET_KEY": env["SECRET_KEY"],
	    "DATABASE_SECRET_KEY": env["DATABASE_SECRET_KEY"],
	    "OIDC_CLIENT_SECRET": env["OIDC_CLIENT_SECRET"],
	    "S3_ACCESS_KEY": env["S3_ACCESS_KEY"],
	    "S3_SECRET_KEY": env["S3_SECRET_KEY"],
	}
	config = open("/conf/template/config.yaml").read()
	for key, value in values.items():
	    placeholder = "__%s__" % key
	    if placeholder not in config:
	        raise SystemExit("config template has no " + placeholder)
	    config = config.replace(placeholder, json.dumps(value))
	with open("/conf/stack/config.yaml", "w") as f:
	    f.write(config)
	print("wrote /conf/stack/config.yaml")
	"""

// Restricted is the container security context every container here has but
// Quay's own, which needs a writable root (below).
let Restricted = {
	allowPrivilegeEscalation: false
	readOnlyRootFilesystem:   true
	capabilities: drop: ["ALL"]
}

holos: spec: artifacts: [(#ResourcesArtifact & {
	resources: {
		Namespace: (NS): metadata: labels: Istio.ambient

		// The database: one instance, one volume on the default class,
		// ceph-rbd, and a bootstrap initdb that creates the quay database
		// owned by quay, with the password from quay-db, as keycloak's. Quay
		// needs pg_trgm, which postInitApplicationSQL creates once, as the
		// superuser, in the new database. Argo CD does not prune it: the
		// Cluster owns its volume, which ceph-rbd reclaims with Delete, and
		// the database holds every manifest and tag. No PodDisruptionBudget,
		// for the reason keycloak-db has none: with one instance it allows
		// no disruption, and a drain would hang.
		Cluster: (DB): {
			metadata: {
				namespace: NS
				annotations: "argocd.argoproj.io/sync-options": "Prune=false,Delete=false"
			}
			spec: {
				instances: 1
				enablePDB: false
				imageName: PostgreSQLImage
				storage: size: "10Gi"
				bootstrap: initdb: {
					database: Database
					owner:    Owner
					secret: name: DB
					postInitApplicationSQL: ["CREATE EXTENSION IF NOT EXISTS pg_trgm"]
				}
				resources: {
					requests: {cpu: "100m", memory: "256Mi"}
					limits: memory: "1Gi"
				}
			}
		}

		ConfigMap: (ConfigTemplate): {
			metadata: {
				namespace: NS
				labels:    Labels
			}
			data: "config.yaml": ConfigYAML
		}

		// Quay's own ServiceAccount, which Redis's AuthorizationPolicy
		// admits by its mesh identity. Its token stays mounted: Quay's
		// KubernetesConfigProvider, chosen whenever KUBERNETES_SERVICE_HOST
		// is set, will not start without one. It is bound to no role, so the
		// token grants nothing.
		ServiceAccount: (Name): metadata: namespace: NS

		Deployment: (Name): {
			metadata: {
				namespace: NS
				labels:    Labels
			}
			spec: {
				replicas: 1
				// Recreate: two Quay pods would hold twice the memory, and
				// a new release's pod migrates the schema the old one is
				// still using.
				strategy: type:        "Recreate"
				selector: matchLabels: Labels
				template: {
					metadata: {
						labels: Labels
						annotations: "holos.run/config-hash": ConfigHash
					}
					spec: {
						serviceAccountName: Name
						// The image's user is 1001.
						securityContext: {
							runAsNonRoot: true
							seccompProfile: type: "RuntimeDefault"
						}
						initContainers: [{
							name:  "config"
							image: Q.image
							command: ["python3", "-c", InitScript]
							env: [for K, V in Placeholders {
								name: K
								valueFrom: secretKeyRef: V
							}]
							volumeMounts: [
								{name: "config-template", mountPath: "/conf/template", readOnly: true},
								{name: "config", mountPath: "/conf/stack"},
							]
							resources: {
								requests: {cpu: "10m", memory: "64Mi"}
								limits: memory: "256Mi"
							}
							securityContext: Restricted
						}]
						containers: [{
							name:  Name
							image: Q.image
							// Quay sizes each gunicorn pool from the CPU
							// count unless told, and clamps a pin below each
							// pool's minimum, eight for the registry, back
							// up to it, unless
							// WORKER_COUNT_UNSUPPORTED_MINIMUM lowers the
							// floor. aavis-ops saw the unpinned pools
							// OOMKilled at 4Gi.
							env: [
								{name: "WORKER_COUNT_WEB", value: "2"},
								{name: "WORKER_COUNT_REGISTRY", value: "2"},
								{name: "WORKER_COUNT_SECSCAN", value: "1"},
								{name: "WORKER_COUNT_UNSUPPORTED_MINIMUM", value: "1"},
							]
							ports: [{name: "http", containerPort: Q.port}]
							// The first start runs the schema migrations
							// before anything serves, so the startup probe
							// allows ten minutes. /health/instance checks
							// the database and gunicorn from a busy
							// Python process, so every probe waits 5s. The
							// kubelet's probes reach an ambient pod from
							// 169.254.7.127, which cilium-resources' policy
							// admits.
							startupProbe: {
								httpGet: {path: "/health/instance", port: "http"}
								periodSeconds:    10
								failureThreshold: 60
								timeoutSeconds:   5
							}
							readinessProbe: {
								httpGet: {path: "/health/instance", port: "http"}
								timeoutSeconds: 5
							}
							livenessProbe: {
								httpGet: {path: "/health/instance", port: "http"}
								timeoutSeconds: 5
							}
							// About twenty Python workers, each with the
							// whole codebase: treasury measured Quay at
							// 3.6Gi idle, as aavis-ops had, and 3.8Gi
							// after a push; aavis-ops saw OOMKills at 2Gi
							// and 4Gi limits. The request is that
							// measurement rounded up, so the scheduler
							// places nothing on memory Quay is using, and
							// the limit leaves headroom for a push.
							resources: {
								requests: {cpu: "500m", memory: "4Gi"}
								limits: memory: "6Gi"
							}
							// The root stays writable: the entrypoint writes
							// supervisord's state and the extracted trust
							// store.
							securityContext: {
								allowPrivilegeEscalation: false
								capabilities: drop: ["ALL"]
							}
							volumeMounts: [
								{name: "config", mountPath: "/conf/stack"},
								{name: "private-ca", mountPath: CAMount, readOnly: true},
							]
						}]
						volumes: [
							{name: "config-template", configMap: name: ConfigTemplate},
							{name: "config", emptyDir: {}},
							// trust-manager's private-ca ConfigMap, for
							// Quay's calls to Keycloak through the gateway.
							// Quay has no option to skip verification.
							// Not optional: trust-manager comes earlier.
							{name: "private-ca", configMap: {
								name: PrivateCA.bundle
								items: [{key: PrivateCA.bundleKey, path: "private-ca.crt"}]
							}},
						]
					}
				}
			}
		}

		Service: (Name): {
			metadata: {
				namespace: NS
				labels:    Labels
			}
			spec: {
				selector: Labels
				ports: [{name: "http", port: Q.port, targetPort: "http"}]
			}
		}

		// Every path, the UI, the API and /v2, to Quay. The gateway sets no
		// body size limit, so a large layer push goes through whole.
		HTTPRoute: (Name): {
			metadata: namespace: NS
			spec: {
				parentRefs: [IngressGateway.parentRef]
				hostnames: [Q.host]
				rules: [{backendRefs: [{name: Name, port: Q.port}]}]
			}
		}

		// Redis keeps nothing across a restart (--save "" --appendonly no)
		// and has no password. Its AuthorizationPolicy admits Quay's
		// ServiceAccount alone, by mesh identity, which ztunnel checks;
		// the kubelet's TCP probes bypass ztunnel.
		Deployment: (Redis.name): {
			metadata: {
				namespace: NS
				labels:    Redis.labels
			}
			spec: {
				replicas: 1
				selector: matchLabels: Redis.labels
				template: {
					metadata: labels: Redis.labels
					spec: {
						automountServiceAccountToken: false
						// The image's redis user.
						securityContext: {
							runAsNonRoot: true
							runAsUser:    999
							runAsGroup:   1000
							seccompProfile: type: "RuntimeDefault"
						}
						containers: [{
							name:  "redis"
							image: Redis.image
							args: ["redis-server", "--save", "", "--appendonly", "no"]
							ports: [{name: "redis", containerPort: Redis.port}]
							readinessProbe: tcpSocket: port: "redis"
							livenessProbe: tcpSocket: port:  "redis"
							resources: {
								requests: {cpu: "25m", memory: "32Mi"}
								limits: memory: "128Mi"
							}
							securityContext: Restricted
							volumeMounts: [{name: "data", mountPath: "/data"}]
						}]
						volumes: [{name: "data", emptyDir: {}}]
					}
				}
			}
		}

		Service: (Redis.name): {
			metadata: {
				namespace: NS
				labels:    Redis.labels
			}
			spec: {
				selector: Redis.labels
				ports: [{name: "redis", port: Redis.port, targetPort: "redis"}]
			}
		}

		AuthorizationPolicy: (Redis.name): {
			metadata: namespace: NS
			spec: {
				selector: matchLabels: Redis.labels
				action: "ALLOW"
				rules: [{from: [{source: principals: ["\(Istio.trustDomain)/ns/\(NS)/sa/\(Name)"]}]}]
			}
		}

		// Quay's client: confidential, standard flow alone, with the three
		// callbacks Quay's Keycloak provider uses, for login, for attaching
		// a login to an existing user, and for the CLI token page. The
		// controller generates the secret once and delivers it to
		// quay-oidc here. The client gets the realm's default scopes,
		// groups among them. No PKCE method is set (Config, above).
		Client: (Name): {
			metadata: namespace: NS
			spec: {
				clientId:    Q.clientId
				type:        "confidential"
				description: "Quay"
				instanceRef: HolosController.instance
				redirectUris: [for P in ["", "/attach", "/cli"] {"\(Q.url)/oauth2/keycloak/callback\(P)"}]
				secretRef: Q.oidcSecret
			}
		}

		// The Client names the Instance in keycloak, another namespace,
		// which holos-controller allows only with a ReferenceGrant there.
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

		// The organizations (Q13), each with the platformowners team synced
		// from the platform owners' group as admin. They name no caBundle: the
		// controller trusts the private root through SSL_CERT_DIR
		// (components/holos-controller), and reads its token from
		// holos-controller-quay-creds, the default credentialsSecretRef,
		// below. Orphan, so deleting one, or Argo CD pruning it, leaves the
		// organization and its images in Quay: they are not in git.
		for O in Q.organizations {
			Organization: (O.name): {
				metadata: namespace: NS
				spec: {
					name:           O.name
					email:          "quay+\(O.name)@\(IngressGateway.domain)"
					deletionPolicy: "Orphan"
					syncedTeams: [{
						name:      Q.ownersTeam
						oidcGroup: SecretsManager.owners
						role:      "admin"
					}]
				}
			}
		}

		// The demo actor's repository, public (Q13): atelet pulls actor
		// images with no pull secret. The actor template pins its digest.
		Repository: "demo-echo": {
			metadata: namespace: NS
			spec: {
				organizationRef: Q.organizations.demo.name
				name:            "echo"
				visibility:      "public"
				description:     "The demo actor's image, public so atelet can pull it anonymously."
				deletionPolicy:  "Orphan"
			}
		}

		// The RustFS keys' copy, from the immutable rustfs-quay the rustfs
		// component generates, through the store below. Owner, as every
		// copy is: it follows its source.
		ExternalSecret: (RustFS.keys): {
			metadata: namespace: NS
			spec: {
				refreshInterval: "1h"
				secretStoreRef: {kind: "SecretStore", name: RustFS.namespace}
				target: creationPolicy: "Owner"
				dataFrom: [{extract: key: RustFS.keys}]
			}
		}

		// holos-controller's Quay credential, url, token and username, the
		// Secret its Quay reconcilers read from its own namespace, copied
		// from the platform secret cmd/quay-bootstrap writes (Q57). It is
		// here rather than in holos-controller, which syncs before Quay
		// exists: an ExternalSecret there would keep that Application
		// Degraded, and the root would never reach this one. Until bootstrap
		// has run, it reports SecretSyncedError.
		ExternalSecret: (Q.credentials.controller): {
			metadata: namespace: HolosController.namespace
			spec: {
				refreshInterval: "1h"
				secretStoreRef: {kind: "SecretStore", name: "platform"}
				target: creationPolicy: "Owner"
				dataFrom: [{extract: key: Q.credentials.platform}]
			}
		}
	}

	resources: (#GeneratedSecret & {
		name:      DB
		namespace: NS
		username:  Owner
	}).resources

	// SECRET_KEY and DATABASE_SECRET_KEY. DATABASE_SECRET_KEY encrypts fields
	// in the database, so it must not change while the database lives: the
	// generated Secret is immutable, and a rebuilt cluster makes both anew
	// with the database.
	resources: (#GeneratedSecret & {
		name:      SecretKeys
		namespace: NS
		generator: spec: secretKeys: ["SECRET_KEY", "DATABASE_SECRET_KEY"]
	}).resources

	// The store for the RustFS keys: it may get rustfs-quay in rustfs and
	// nothing else.
	resources: (#ScopedSecretStore & {
		name:      RustFS.namespace
		namespace: NS
		source:    RustFS.namespace
		secrets: [RustFS.keys]
	}).resources

	// The store for the controller's credential, in the controller's
	// namespace: it may get quay-controller-token in holos-prj-platform and
	// nothing else. Its reader is holos-controller-platform-reader.
	resources: (#ScopedSecretStore & {
		name:      "platform"
		namespace: HolosController.namespace
		secrets: [Q.credentials.platform]
	}).resources
}).artifact]
