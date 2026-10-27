package holos

// keycloak is the platform's one identity provider (interview Q11): Keycloak
// 26.8.1, run by the Keycloak Operator (the keycloak-operator component) from
// the Keycloak resource here, with its own one-instance CloudNativePG cluster,
// behind the ingress gateway at keycloak.<privateDomain>. That URL is the
// issuer every token carries, https://keycloak.bank.internal/realms/<realm>,
// and pods and the laptop resolve it alike, to the gateway. The realm, holos,
// is keycloak-realm's, imported once and then reconciled in part by
// holos-controller; this component is the server and its database alone, and
// the master realm its bootstrap admin logs in to.
//
// The gateway terminates TLS with the private CA's wildcard and reaches the
// server over HBONE, as it does hello, so Keycloak serves plain HTTP in the
// cluster, with its full URL set and the gateway's X-Forwarded headers
// trusted, and the operator's own Ingress is off. The namespace, which the
// keycloak-operator component renders, is in the mesh, the database's pods
// included: Keycloak reaches PostgreSQL over HBONE too.
//
// Both passwords are generated in the cluster (#GeneratedSecret), each a
// kubernetes.io/basic-auth Secret with a fixed username:
//
//   - keycloak-admin, the bootstrap admin, user admin, which the operator
//     gives the server to create in the master realm on its first start.
//   - keycloak-db, the database's owner, user keycloak, which CloudNativePG's
//     initdb creates the owner with and Keycloak connects as.
//
// They stay here, where they are used (Q46); nothing copies them out.

// KC is Keycloak (components/keycloak.cue), under a name the resources'
// Keycloak kind does not hide.
let KC = Keycloak
let Namespace = KC.namespace

// DB is the CloudNativePG cluster's name. CloudNativePG names its read-write
// Service <name>-rw.
let DB = "keycloak-db"

// Database and Owner are the database initdb creates and its owner, who is
// the user Keycloak connects as. Keycloak never uses the superuser, which
// CloudNativePG leaves disabled by default.
let Database = "keycloak"
let Owner = "keycloak"

// Admin is the bootstrap admin's username. The operator's own default is
// temp-admin, for an admin meant to be replaced by hand. This one is not: it
// is the platform's lasting admin of the master realm, its credential
// generated and kept in the cluster. holos-controller does not use it: it
// logs in to the realm holos as its own client, svc-holos-controller. The
// server still flags any bootstrap admin as temporary and says so in the
// admin console; the flag changes nothing else.
let Admin = "admin"

// PostgreSQLImage is the image CloudNativePG 1.30.1 runs by default,
// PostgreSQL 18.6, stated so an operator upgrade does not move the database
// to a new major version by itself.
let PostgreSQLImage = "ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie"

holos: spec: artifacts: [(#ResourcesArtifact & {
	resources: {
		// The database: one instance, one volume on the default class,
		// ceph-rbd, and a bootstrap initdb that creates the keycloak database
		// owned by keycloak, with the password from keycloak-db. Argo CD
		// does not prune it: the Cluster owns its volume, which ceph-rbd
		// reclaims with Delete, so the Cluster dropping out of the render
		// while the Application stays would otherwise drop every realm.
		// Nothing here stands in
		// the way of a backup stanza later (interview Q11): the WAL and the
		// data are on the one volume, and no plugin or object store is set.
		Cluster: (DB): {
			metadata: {
				namespace: Namespace
				annotations: "argocd.argoproj.io/sync-options": "Prune=false,Delete=false"
			}
			spec: {
				instances: 1
				// No PodDisruptionBudget. With one instance CloudNativePG's
				// keycloak-db-primary budget allows no disruption, so a
				// drain or upgrade of the node holding the database would
				// hang forever. One instance already means downtime on a
				// drain; a hang is worse.
				enablePDB: false
				imageName: PostgreSQLImage
				storage: size: "10Gi"
				bootstrap: initdb: {
					database: Database
					owner:    Owner
					secret: name: DB
				}
				resources: {
					requests: {cpu: "100m", memory: "256Mi"}
					limits: memory: "1Gi"
				}
			}
		}

		Keycloak: (KC.name): {
			metadata: namespace: Namespace
			spec: {
				// One server. More would cluster over JGroups, which the
				// operator configures, but one is the base's size.
				instances: 1

				// The database, as CloudNativePG serves it: the read-write
				// Service in this namespace, and the owner's Secret. With a
				// database set the operator runs the server with start, the
				// production mode, never start-dev.
				db: {
					vendor:   "postgres"
					host:     "\(DB)-rw"
					port:     5432
					database: Database
					usernameSecret: {name: DB, key: "username"}
					passwordSecret: {name: DB, key: "password"}
				}

				// Plain HTTP on 8080, the port the operator's Service, and
				// the route, reach. The gateway terminates TLS.
				http: {
					httpEnabled: true
					httpPort:    KC.port
				}

				// The full URL, so every URL Keycloak writes, the issuer
				// first, is the gateway's, whatever host a request came in
				// with. strict stays on and backchannelDynamic off: a pod
				// calls the same URL a browser does, through the gateway,
				// so Keycloak never advertises its plain HTTP Service.
				hostname: hostname: KC.url

				// The gateway sets X-Forwarded-For and X-Forwarded-Proto,
				// and from outside the cluster only the gateway reaches the
				// server's port. A pod in the cluster can reach
				// keycloak-service:8080 directly and forge
				// X-Forwarded-For, which Keycloak records as the client's
				// address in its logs and events, and nothing more: the
				// hostname is fixed above. proxy.trustedAddresses cannot
				// narrow this cleanly, since the gateway's connections
				// arrive from its pods' addresses, anywhere in the pod
				// network.
				proxy: headers: "xforwarded"

				// No Prometheus Operator, so no ServiceMonitor. Without
				// this the operator reports a warning on the resource that
				// it is not creating one.
				serviceMonitor: enabled: false

				// The route below is the way in. The operator's default, an
				// Ingress for the hostname, is off.
				ingress: enabled: false

				// The bootstrap admin, created in the master realm on the
				// server's first start, from keycloak-admin's username and
				// password. Once the master realm has an admin the server
				// ignores it, so a rotated keycloak-admin changes nothing
				// in Keycloak by itself (README.md, Keycloak).
				bootstrapAdmin: user: secret: "keycloak-admin"

				// The private root, for any outbound call the server makes
				// to a bank.internal name, such as a later identity broker
				// or backchannel call through the gateway. The operator
				// takes a ConfigMap here and mounts it among the server's
				// truststore paths, beside the image's own public roots, so
				// trust-manager's private-ca ConfigMap, which it keeps in
				// every namespace, is used as it is, with no copy into a
				// Secret.
				truststores: (PrivateCA.bundle): configMap: name: PrivateCA.bundle

				// Keycloak does not call the Kubernetes API, and the
				// operator would otherwise add the token's cluster CA to the
				// truststore.
				automountServiceAccountToken: false

				// The JVM's heap is a share of the memory limit, which the
				// operator sets; a 2Gi limit gives the heap about 1.4Gi, a
				// fifth of a worker.
				resources: {
					requests: {cpu: "500m", memory: "1Gi"}
					limits: memory: "2Gi"
				}
			}
		}

		// The operator puts a NetworkPolicy, keycloak-network-policy, on the
		// server's pods that admits their own ports alone: 8080, the
		// management port 9000, and JGroups'. In the mesh, ztunnel delivers
		// a meshed client's connection, the gateway's included, to the pod
		// on 15008, HBONE, and forwards it to 8080 inside the pod, so that
		// policy would drop it; the CRD can narrow the policy's sources but
		// not add a port. Policies add up, so this one admits 15008 to the
		// same pods beside it. ztunnel authenticates every HBONE peer with
		// mutual TLS, so the source is left open. The kubelet's probes of
		// 9000 come from 169.254.7.127, which cilium-resources' policy
		// admits.
		NetworkPolicy: "\(KC.name)-allow-hbone": {
			metadata: namespace: Namespace
			spec: {
				// The operator's own policy's selector, the labels it puts
				// on the server's pods.
				podSelector: matchLabels: {
					app:                            "keycloak"
					"app.kubernetes.io/instance":   KC.name
					"app.kubernetes.io/managed-by": "keycloak-operator"
				}
				policyTypes: ["Ingress"]
				ingress: [{ports: [{protocol: "TCP", port: 15008}]}]
			}
		}

		HTTPRoute: (KC.name): {
			metadata: namespace: Namespace
			spec: {
				parentRefs: [IngressGateway.parentRef]
				hostnames: [IngressGateway.hosts.keycloak]
				rules: [{backendRefs: [{name: KC.service, port: KC.port}]}]
			}
		}
	}

	resources: (#GeneratedSecret & {
		name:      "keycloak-admin"
		namespace: Namespace
		username:  Admin
	}).resources

	resources: (#GeneratedSecret & {
		name:      DB
		namespace: Namespace
		username:  Owner
	}).resources
}).artifact]
