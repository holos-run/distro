package holos

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/yaml"
	"list"
	"strings"
)

// substrate is Agent Substrate's control plane, rendered from upstream's own
// install tree (interview Q23 and Q27) in the holos-run fork, which is
// vendored as a git submodule at vendor/substrate and pinned, with its image
// digests, by Substrate (substrate.cue). cmd/ate-setup cannot render without
// a cluster, so it is read rather than run: ATE-SETUP.md, beside this file,
// maps every step of its "deploy ate-system" to a stage here or to an
// imperative step in README.md, Substrate, and is re-read on every bump.
//
// The artifact is a pipeline of four stages:
//
//  1. A Command generator builds upstream/kustomization.yaml with kubectl
//     kustomize: upstream's base and the files ate-setup applies on their
//     own (the CRDs and the controller's RBAC, the pod certificate
//     controller, the SandboxConfig policy and default, the egress gateway
//     and the Kubernetes Secrets credential provider), plus the role SQL as
//     a ConfigMap. The submodule's commit is the pin, so every render reads
//     the same tree offline.
//  2. A Resources generator makes, as CUE, what ate-setup creates
//     imperatively or what upstream does not ship: the API server's
//     ConfigMaps, the CloudNativePG cluster and its role Job, the generated
//     passwords and the connection strings, the copy of the RustFS keys,
//     the WorkerPool and the NetworkPolicy additions.
//  3. A Kustomize transformer applies the patches that reproduce
//     ate-setup's render (Patches, below) and rewrites every ko:// image to
//     ghcr.io by digest.
//  4. holos kubectl-slice writes one file per resource.
//
// Two validators fail the render if the submodule is not at
// Substrate.commit, or if any ko:// reference, ${...} image placeholder, GKE
// PodMonitoring, GKE collector address or gcs storage backend survives.
//
// Three things stay imperative, because Substrate has no declarative form
// for them (README.md, Substrate): the key pools, created once with
// ate-setup's create commands; the demo atespace; and its actor templates
// and actors. Until the pools exist the pods that project them stay in
// ContainerCreating, which is a new cluster's expected first sync.
//
// Every kind's CRD is here or in an earlier component: WorkerPool and
// SandboxConfig here, Cluster from cloudnative-pg, Certificate from
// cert-manager, ExternalSecret, SecretStore and the generators from
// external-secrets.

let S = Substrate
let NS = S.namespace
let DB = S.database
let Pool = S.workerPool

// DNSDomain is the cluster's, read here because inside the resources below
// Cluster names CloudNativePG's kind.
let DNSDomain = Cluster.network.dnsDomain

// PostgreSQLImage is keycloak's and quay's, CloudNativePG 1.30.1's default,
// PostgreSQL 18.6, stated so an operator upgrade does not move the database
// to a new major version by itself. The role Job runs psql from it.
let PostgreSQLImage = "ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie"

// Roles are pkg/postgressetup's defaults, which ateapi's flags and
// setup.sql's variables name: two NOLOGIN roles and a login user for each,
// in schema substrate.
let Roles = {
	schema: "substrate"
	owner: {
		role: "substrate_owner"
		user: "substrate_owner_user"
	}
	readwrite: {
		role: "substrate_readwrite"
		user: "substrate_readwrite_user"
	}
}

// Secrets made here. users holds the two login users' passwords, one key
// each named for its user; superuser is CloudNativePG's postgres login,
// which only the role Job uses; app is the initdb owner's, which nothing
// uses; serverTLS is the database's serving certificate.
let Secrets = {
	users:     "\(DB.cluster)-users"
	superuser: "\(DB.cluster)-superuser"
	app:       DB.cluster
	serverTLS: "\(DB.cluster)-server-tls"
	envVars:   "ate-api-server-secret-envvars"
}

// ServerCA is where ate-api-server's upstream manifest mounts the external
// database's server CA, the Secret postgres-server-ca, key server-ca.pem.
// Patches mounts the private root's ConfigMap there instead, so the DSN's
// sslrootcert is upstream's path.
let ServerCA = "/run/postgres-server-ca/server-ca.pem"

// DSN is a login user's connection string, verify-full against the private
// root, whose ClusterIssuer signed the database's certificate. The password
// is an External Secrets template variable; the generated passwords are
// letters and digits, so they need no escaping in a URI.
let DSN = {
	user:     string
	password: string
	out:      "postgresql://\(user):{{ .\(password) }}@\(DB.host):\(DB.port)/\(DB.database)?sslmode=verify-full&sslrootcert=\(ServerCA)"
}

// RustFS is the snapshot store: rustfs-svc in rustfs (components/rustfs),
// its bucket substrate and the keys its Job registers for it. The bucket is
// the snapshot location's host; the plugins ignore its scheme on S3.
let RustFS = {
	namespace: "rustfs"
	endpoint:  "http://rustfs-svc.\(namespace).svc:9000"
	bucket:    "substrate"
	keys:      "rustfs-\(bucket)"
}

// S3Env is the object store plugin's S3 backend, on both of its sidecars,
// ate-api-server's and atelet's, in the kind overlay's shape, with the
// keys from the copy of rustfs-substrate instead of RustFS's defaults.
let S3Env = [
	{name: "ATE_STORAGE_BACKEND", value: "s3"},
	{name: "AWS_REGION", value: "us-east-1"},
	{name: "AWS_ENDPOINT_URL", value: RustFS.endpoint},
	{name: "AWS_S3_USE_PATH_STYLE", value: "true"},
	{name: "AWS_ACCESS_KEY_ID", valueFrom: secretKeyRef: {name: RustFS.keys, key: "access-key"}},
	{name: "AWS_SECRET_ACCESS_KEY", valueFrom: secretKeyRef: {name: RustFS.keys, key: "secret-key"}},
]

// The ConfigMaps ate-setup's EnsureAPIServerPrerequisites writes.
//
// Authentication: one JWT provider, the cluster's ServiceAccount tokens for
// audience api.ate-system.svc. Talos's issuer is the control plane
// endpoint, which ate-setup would write with no CA or token file, as it adds
// them only for the in-cluster issuer; Talos has anonymous auth off, so
// discovery would answer 401. Both files are the pod's own ServiceAccount
// mount.
let Authentication = yaml.Marshal({
	jwtProviders: [{
		name:   "kubernetes"
		issuer: Cluster.serviceAccountIssuer
		audiences: [S.api.audience]
		certificateAuthorityFile: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
		discoveryTokenFile:       "/var/run/secrets/kubernetes.io/serviceaccount/token"
	}]
})

// APIConfig is ateconfigpb.APIConfig in text format, ate-setup's default.
let APIConfig = """
	logging: {
	  level: "info"
	}

	"""

// EnvVars is ate-api-server-envvars: the stable roles, the actor JWT
// issuer, which the objectstore sidecar also reads, the snapshot location
// and an empty transfer service account, which only GCS uses but the
// sidecar's argument names. The connection strings and the schema are in
// the Secret (DSNs, below).
let EnvVars = {
	ATE_API_POSTGRES_READ_WRITE_ROLE:          Roles.readwrite.role
	ATE_API_POSTGRES_OWNER_ROLE:               Roles.owner.role
	ATE_API_ACTOR_JWT_ISSUER:                  S.issuer
	ATE_API_SNAPSHOT_TRANSFER_SERVICE_ACCOUNT: ""
	ATE_API_SNAPSHOT_LOCATION:                 "s3://\(RustFS.bucket)/"
}

// DSNs is the template of ate-api-server-secret-envvars, the keys ateapi
// reads with @env.
let DSNs = {
	ATE_API_POSTGRES_READ_WRITE_CONNECTION_STRING: (DSN & {user: Roles.readwrite.user, password: "readwrite"}).out
	ATE_API_POSTGRES_OWNER_CONNECTION_STRING: (DSN & {user: Roles.owner.user, password: "owner"}).out
	ATE_API_POSTGRES_SCHEMA: Roles.schema
}

// OTel is ate-otel-config's data. There is no collector, so every signal's
// exporter is none rather than an endpoint left unset, which the OTel SDK
// takes as localhost:4317 and logs errors against. Logs go to stdout as the
// components' JSON lines either way; console adds the actor events there.
// ATE_WORKER_* are what ate-controller hands the worker pods. With no
// endpoint, atenet-router configures no Envoy tracer.
let OTel = {
	OTEL_TRACES_EXPORTER:             "none"
	OTEL_METRICS_EXPORTER:            "none"
	OTEL_LOGS_EXPORTER:               "console"
	ATE_WORKER_OTEL_TRACES_EXPORTER:  "none"
	ATE_WORKER_OTEL_METRICS_EXPORTER: "none"
	ATE_WORKER_OTEL_LOGS_EXPORTER:    "none"
}

// NamespacePolicy is the credential provider's: an atespace may resolve
// ate-secret:// references to Secrets in the namespaces listed for it, and
// in no other. kagent's atespace reads kagent's namespace, where its model
// key is.
let NamespacePolicy = yaml.Marshal({
	policies: [{
		atespace: Kagent.atespace
		allowedNamespaces: [Kagent.namespace]
	}]
})

// ConfigHashes are what each workload reads of the configuration made in
// CUE, by kind and name. Kubernetes does not restart a pod when a ConfigMap
// or Secret it reads changes, and these components read theirs at start, so
// a short digest of it, holos.run/config-hash on the pod template, rolls the
// workload when it changes. On ate-api-server it replaces ate-setup's
// ate.dev/env-hash. Only what is in git is covered: a password rotation is
// followed by a rollout restart by hand, and so is a change to the two Envoy
// ConfigMaps upstream ships, atenet-router-envoy-config and atenet-egress,
// whose data the input stage, a command's output, does not give CUE
// (README.md, Substrate, Bumping the pin). Every reader of ate-otel-config
// is here; ate-idp-server and the pod certificate controller read none.
let ConfigHashes = {
	Deployment: {
		"ate-api-server": {
			envVars:        EnvVars
			dsns:           DSNs
			authentication: Authentication
			apiConfig:      APIConfig
			otel:           OTel
		}
		"ate-controller": otel:                     OTel
		"atenet-router": otel:                      OTel
		"atenet-egress": otel:                      OTel
		"k8s-credential-provider": namespacePolicy: NamespacePolicy
	}
	DaemonSet: atelet: otel: OTel
}

// Ingress is the router's allowed list (--ingress-allowed-spiffe-ids), an
// exact match on the SPIFFE ID of a client's pod identity certificate: the
// ingress gateway, through which substrate-shim reaches actors, and kagent's
// controller. The gateway's identity is IngressGateway's, the one the
// gateway Deployment's certificate is issued for; the unification below
// fails the render should Istio's trust domain ever differ from the pod
// identity signer's.
let Ingress = [IngressGateway.spiffeID, Kagent.controller.spiffeID]
IngressGateway: spiffeID: "spiffe://\(S.trustDomain)/ns/\(IngressGateway.namespace)/sa/\(IngressGateway.serviceAccount)"

// BootstrapOwners always hold owner on the global scope: ate-client, the
// identity kubectl ate acts as without --token-file, as ate-setup's default,
// so its token is the global admin credential and is minted only from the
// laptop with cluster-admin; and kagent's controller, by the principal its
// pod certificate authenticates as.
let BootstrapOwners = [S.client.principal, Kagent.controller.spiffeID]

// CredentialProvider is the bundled Kubernetes Secrets provider, ate-setup's
// {"name":"k8s.io"}: the egress gateway's flags name it, its Service's
// address and its serving certificate's name.
let CredentialProvider = {
	name:       "k8s.io"
	serverName: "k8s-credential-provider.\(NS).svc"
	address:    "\(serverName):50051"
}

// KoImages are the ko:// import paths in upstream's manifests, by image name
// (Substrate.digests). The images field rewrites each to ghcr.io by digest;
// a reference to one not listed here survives and fails the render.
let KoImages = {
	"ate-idp-server":     "cmd/ate-idp-server"
	ateapi:               "cmd/ateapi"
	atecontroller:        "cmd/atecontroller"
	atelet:               "cmd/atelet"
	atenet:               "cmd/atenet"
	"kubernetes-secrets": "cmd/credential-provider/kubernetes-secrets"
	"objectstore-plugin": "cmd/objectstore-plugin"
	podcertcontroller:    "cmd/podcertcontroller"
}

// EnvoyImage replaces ${ENVOY_DATAPLANE_IMAGE}, which kustomize's images
// field cannot match, as ate-setup's patchEnvoyDataplaneImage does.
let EnvoyImage = "\(S.registry)/envoy-dataplane@\(S.digests["envoy-dataplane"])"

// #ContainerPatch is a JSON 6902 patch of one container of an apps/v1
// workload in ate-system, by index, after a test that the container at that
// index has the name expected, so a reordered manifest fails the render
// rather than patching the wrong container, as ate-setup's
// appendContainerArgs does. ops are relative to the container.
#ContainerPatch: {
	kind:      "Deployment" | "DaemonSet"
	name:      string
	index:     int
	container: string
	ops: [...{op: string, path: string, value?: _}]

	let Path = "/spec/template/spec/containers/\(index)"
	out: #KustomizePatch & {
		target: {
			group:   "apps"
			version: "v1"
			"kind":  kind
			"name":  name
		}
		patch: yaml.Marshal(list.Concat([
			[{op: "test", path: "\(Path)/name", value: container}],
			[for O in ops {
				op:   O.op
				path: "\(Path)\(O.path)"
				if O.value != _|_ {value: O.value}
			}],
		]))
	}
}

// #AppendArgs adds args to the end of a container's.
#AppendArgs: {
	#ContainerPatch
	args: [...string]
	ops: [for A in args {op: "add", path: "/args/-", value: A}]
}

// #StrategicPatch is a strategic merge patch of one object, in ate-system
// unless it is cluster-scoped.
#StrategicPatch: {
	apiVersion: string
	kind:       string
	name:       string
	namespaced: bool | *true
	body: {...}

	out: #KustomizePatch & {
		target: {"kind": kind, "name": name}
		patch: yaml.Marshal({
			"apiVersion": apiVersion
			"kind":       kind
			metadata: "name": name
			if namespaced {metadata: namespace: NS}
		} & body)
	}
}

// Patches reproduce ate-setup's render on the input, in the order ATE-SETUP.md
// lists them.
let Patches = [
	// The namespace atelet's host paths and the worker pods need (the
	// spike's finding). podcertificate-controller-system needs no label.
	// Both hold key pools Argo CD does not track, and ate-system holds the
	// database, so Argo CD never deletes either namespace, even with its
	// Application.
	(#StrategicPatch & {
		apiVersion: "v1"
		kind:       "Namespace"
		name:       NS
		namespaced: false
		body: metadata: {
			labels: "pod-security.kubernetes.io/enforce":   "privileged"
			annotations: "argocd.argoproj.io/sync-options": "Delete=false"
		}
	}).out,
	(#StrategicPatch & {
		apiVersion: "v1"
		kind:       "Namespace"
		name:       S.podCertNamespace
		namespaced: false
		body: metadata: annotations: "argocd.argoproj.io/sync-options": "Delete=false"
	}).out,

	// Upstream's NetworkPolicy for its bundled PostgreSQL, which is not
	// installed; substrate-db has its own (Resources).
	(#StrategicPatch & {
		apiVersion: "networking.k8s.io/v1"
		kind:       "NetworkPolicy"
		name:       "postgres"
		body: "$patch": "delete"
	}).out,

	// The credential provider's cluster-wide binding to its Secret reader
	// role, which would let it read every Secret in the cluster. The
	// ClusterRole stays: each namespace the namespace policy lists binds it
	// to the provider's ServiceAccount with a RoleBinding of its own, which
	// the component that owns that namespace renders (kagent for kagent), so
	// the provider reads Secrets only where an atespace may resolve them.
	(#StrategicPatch & {
		apiVersion: "rbac.authorization.k8s.io/v1"
		kind:       "ClusterRoleBinding"
		name:       "k8s-credential-provider-secret-reader"
		namespaced: false
		body: "$patch": "delete"
	}).out,

	// The router's GKE-only PodMonitoring, which base lists and nothing
	// here serves.
	{
		target: {kind: "PodMonitoring", name: "atenet-router-envoy"}
		patch: yaml.Marshal({
			apiVersion: "monitoring.googleapis.com/v1"
			kind:       "PodMonitoring"
			metadata: {name: "atenet-router-envoy", namespace: NS}
			"$patch": "delete"
		})
	},

	// The OpenTelemetry settings, in place of GKE's managed collector.
	{
		target: {version: "v1", kind: "ConfigMap", name: "ate-otel-config"}
		patch: yaml.Marshal([{op: "replace", path: "/data", value: OTel}])
	},

	// The credential provider's namespace policy, which ate-setup applies
	// only when it is missing, to keep an operator's edits; here git holds
	// it.
	{
		target: {version: "v1", kind: "ConfigMap", name: "k8s-credential-provider-namespace-policy"}
		patch: yaml.Marshal([{op: "replace", path: "/data/namespace-policy.yaml", value: NamespacePolicy}])
	},

	// ate-api-server: the bootstrap owners (setAPIServerAuthzArgs).
	(#AppendArgs & {
		kind:      "Deployment"
		name:      "ate-api-server"
		index:     0
		container: "ate-api-server"
		args: ["--authz-bootstrap-owners=" + strings.Join(BootstrapOwners, ",")]
	}).out,
	// Each workload's config hash (ConfigHashes).
	for KIND, WORKLOADS in ConfigHashes for NAME, READS in WORKLOADS {
		(#StrategicPatch & {
			apiVersion: "apps/v1"
			kind:       KIND
			name:       NAME
			body: spec: template: metadata: annotations: "holos.run/config-hash": strings.SliceRunes(hex.Encode(sha256.Sum256(yaml.Marshal(READS))), 0, 8)
		}).out
	},

	// ate-api-server: the S3 backend on its objectstore sidecar, and the
	// private root as the database's server CA.
	(#StrategicPatch & {
		apiVersion: "apps/v1"
		kind:       "Deployment"
		name:       "ate-api-server"
		body: spec: template: {
			spec: {
				initContainers: [{name: "objectstore-plugin", env: S3Env}]
				volumes: [{
					name:   "postgres-server-ca"
					secret: null
					configMap: {
						name: PrivateCA.bundle
						items: [{key: PrivateCA.bundleKey, path: "server-ca.pem"}]
					}
				}]
			}
		}
	}).out,

	// ate-idp-server: the issuer it mints actor JWTs with
	// (setIDPServerIssuer).
	(#AppendArgs & {
		kind:      "Deployment"
		name:      "ate-idp-server"
		index:     0
		container: "ate-idp-server"
		args: ["--issuer=" + S.issuer]
	}).out,

	// atenet-router: the allowed SPIFFE IDs, without which it serves no TLS
	// listener (patchAtenetRouterAllowedSPIFFEIDs), and the Envoy image.
	(#AppendArgs & {
		kind:      "Deployment"
		name:      "atenet-router"
		index:     0
		container: "atenet-router"
		args: ["--ingress-allowed-spiffe-ids=" + strings.Join(Ingress, ",")]
	}).out,
	(#ContainerPatch & {
		kind:      "Deployment"
		name:      "atenet-router"
		index:     1
		container: "envoy"
		ops: [{op: "replace", path: "/image", value: EnvoyImage}]
	}).out,

	// atenet-egress: the Envoy image, and the credential provider's flags
	// on ext-proc, which ate-setup splices over a YAML comment that
	// kustomize drops (patchAtenetEgressInject).
	(#ContainerPatch & {
		kind:      "Deployment"
		name:      "atenet-egress"
		index:     0
		container: "envoy"
		ops: [{op: "replace", path: "/image", value: EnvoyImage}]
	}).out,
	(#AppendArgs & {
		kind:      "Deployment"
		name:      "atenet-egress"
		index:     1
		container: "ext-proc"
		args: [
			"--credential-provider-name=\(CredentialProvider.name)",
			"--credential-provider-address=\(CredentialProvider.address)",
			"--credential-provider-ca-file=/run/servicedns.podcert.ate.dev/trust-bundle.pem",
			"--credential-provider-client-cert=/run/podidentity.podcert.ate.dev/credential-bundle.pem",
			"--credential-provider-server-name=\(CredentialProvider.serverName)",
		]
	}).out,

	// atelet: no GKE image credential provider, as the kind overlay. Its
	// flags are the first two args; the tests fail the render if upstream
	// moves them.
	(#ContainerPatch & {
		kind:      "DaemonSet"
		name:      "atelet"
		index:     0
		container: "atelet"
		ops: [
			{op: "test", path: "/args/0", value: "--image-credential-provider-config=/run/image-credential-provider/config.yaml"},
			{op: "remove", path: "/args/0"},
			{op: "test", path: "/args/0", value: "--image-credential-provider-bin-dir=/run/image-credential-provider/bin"},
			{op: "remove", path: "/args/0"},
		]
	}).out,
	// atelet: their host mounts, the S3 backend on its objectstore sidecar,
	// and the private root. atelet pulls actor images itself, with
	// go-containerregistry over Go's default TLS, not through containerd, so
	// the workers' Talos trust store does not reach it. It trusts the
	// private-ca ConfigMap trust-manager keeps in the namespace beside the
	// image's public roots, as argocd-server and holos-controller do: Go
	// reads every file in each SSL_CERT_DIR directory, after its bundle file,
	// which SSL_CERT_FILE, unset, leaves in place. So an actor image in
	// Quay, at quay.bank.internal behind the gateway's private wildcard,
	// pulls. Go reads the pool once, at start: a new root, after a rebuild,
	// needs atelet restarted.
	(#StrategicPatch & {
		apiVersion: "apps/v1"
		kind:       "DaemonSet"
		name:       "atelet"
		body: spec: template: spec: {
			containers: [{
				name: "atelet"
				env: [{name: "SSL_CERT_DIR", value: "/etc/ssl/certs:/etc/ssl/private-ca"}]
				volumeMounts: [
					{mountPath: "/run/image-credential-provider/bin", "$patch": "delete"},
					{mountPath: "/run/image-credential-provider/config.yaml", "$patch": "delete"},
					{name: "private-ca", mountPath: "/etc/ssl/private-ca", readOnly: true},
				]
			}]
			volumes: [
				{name: "image-credential-provider-bin", "$patch": "delete"},
				{name: "image-credential-provider-config", "$patch": "delete"},
				{name: "private-ca", configMap: name: PrivateCA.bundle},
			]
			initContainers: [{name: "objectstore-plugin", env: S3Env}]
		}
	}).out,
]

// Images rewrites each ko:// reference to its ghcr.io image by digest.
let Images = [for NAME, PATH in KoImages {
	name:    "ko://go.ate.dev/substrate/\(PATH)"
	newName: "\(S.registry)/\(NAME)"
	digest:  S.digests[NAME]
}]

// Restricted is the container security context of the role Job.
let Restricted = {
	allowPrivilegeEscalation: false
	readOnlyRootFilesystem:   true
	capabilities: drop: ["ALL"]
}

// SetupScript runs setup.sql, pkg/postgressetup's, as its Script does: in
// one transaction, with the role names, schema and passwords as psql
// variables (Config.PSQLArgs), once the database answers. Every statement
// in it converges.
let SetupScript = """
	set -eu
	until pg_isready --quiet; do
	  echo "waiting for $PGHOST"
	  sleep 5
	done
	exec psql --no-psqlrc --set=ON_ERROR_STOP=1 --single-transaction \\
	  --set=substrate_schema=\(Roles.schema) \\
	  --set=substrate_owner_role=\(Roles.owner.role) \\
	  --set=substrate_owner_user=\(Roles.owner.user) \\
	  --set=substrate_owner_password="$OWNER_PASSWORD" \\
	  --set=substrate_readwrite_role=\(Roles.readwrite.role) \\
	  --set=substrate_readwrite_user=\(Roles.readwrite.user) \\
	  --set=substrate_readwrite_password="$READWRITE_PASSWORD" \\
	  --file=/sql/setup.sql
	"""

let SetupLabels = {"app.kubernetes.io/name": "\(DB.cluster)-setup"}

holos: spec: artifacts: [{
	artifact: OutputDir
	generators: [
		// 1. Upstream's install tree, from the submodule. The command runs in
		// the platform root.
		{
			kind:   "Command"
			output: "upstream.yaml"
			command: {
				args: ["kubectl", "kustomize", "--load-restrictor", "LoadRestrictionsNone", "\(BuildContext.leafDir)/upstream"]
				isStdoutOutput: true
			}
		},
		// 2. What ate-setup makes imperatively, and the platform's additions.
		{
			kind:      "Resources"
			output:    "resources.yaml"
			resources: _Resources
		},
	]
	transformers: [
		// 3. ate-setup's render.
		{
			kind: "Kustomize"
			inputs: ["upstream.yaml", "resources.yaml"]
			output: "kustomize-output.yaml"
			kustomize: kustomization: {
				resources: inputs
				images:    Images
				patches:   Patches
			}
		},
		// 4. One file per resource.
		{
			kind: "Command"
			inputs: ["kustomize-output.yaml"]
			output: OutputDir
			command: args: ["holos", "kubectl-slice", "--skip-non-k8s", "-f", "\(BuildContext.tempDir)/kustomize-output.yaml", "-o", "\(BuildContext.tempDir)/\(OutputDir)"]
		},
	]
	validators: [
		// The submodule is checked out at the pin.
		{
			kind: "Command"
			inputs: [OutputDir]
			command: args: ["sh", "-c", """
				got=$(git -C vendor/substrate rev-parse HEAD)
				if [ "$got" != "$1" ]; then
				  echo "vendor/substrate is at $got, but Substrate.commit is $1 (substrate.cue)" >&2
				  exit 1
				fi
				""", "sh", S.commit]
		},
		// Nothing of ate-setup's render is left undone.
		{
			kind: "Command"
			inputs: [OutputDir]
			command: args: ["sh", "-c", """
				if grep -rnE 'ko://|image: .*[$][{]|gke-managed-otel|kind: PodMonitoring' "$1"; then
				  echo "an unresolved image, placeholder or GKE object is left in the render" >&2
				  exit 1
				fi
				if grep -rn -A1 'name: ATE_STORAGE_BACKEND' "$1" | grep -n 'value: gcs'; then
				  echo "an objectstore sidecar is left on the gcs backend" >&2
				  exit 1
				fi
				""", "sh", "\(BuildContext.tempDir)/\(OutputDir)"]
		},
	]
}]

_Resources: #Resources & {
	// The API server's ConfigMaps (EnsureAPIServerPrerequisites).
	ConfigMap: "ate-api-authentication": {
		metadata: namespace:         NS
		data: "authentication.yaml": Authentication
	}
	ConfigMap: "ate-api-config": {
		metadata: namespace:         NS
		data: "apiconfig.textproto": APIConfig
	}
	ConfigMap: "ate-api-server-envvars": {
		metadata: namespace: NS
		data: EnvVars
	}

	// The database, in place of upstream's bundled StatefulSet: one
	// instance, one volume on the default class, ceph-rbd, as keycloak-db
	// and quay-db, and no PodDisruptionBudget, since with one instance it
	// allows no disruption and a drain would hang. Argo CD does not prune
	// it: the Cluster owns its volume, which ceph-rbd reclaims with Delete.
	// kagent shares it, with roles and a schema of its own.
	//
	// initdb makes database substrate, owned by a login nothing uses, whose
	// password is generated. ateapi's roles and schema are setup.sql's,
	// which the role Job runs as the superuser: CloudNativePG's application
	// owner cannot create roles. The server certificate is cert-manager's,
	// from the private CA, so a client verifies the server against the
	// private root, which every namespace has, and which does not change
	// while the cluster lives, where CloudNativePG's own CA is renewed every
	// three months and a client that loaded it at start would stop
	// connecting. CloudNativePG keeps its own CA for client certificates.
	Cluster: (DB.cluster): {
		metadata: {
			namespace: NS
			annotations: "argocd.argoproj.io/sync-options": "Prune=false,Delete=false"
		}
		spec: {
			instances: 1
			enablePDB: false
			imageName: PostgreSQLImage
			storage: size: "10Gi"
			enableSuperuserAccess: true
			superuserSecret: name: Secrets.superuser
			bootstrap: initdb: {
				database: DB.database
				owner:    DB.database
				secret: name: Secrets.app
			}
			certificates: {
				serverTLSSecret: Secrets.serverTLS
				serverCASecret:  Secrets.serverTLS
			}
			resources: {
				requests: {cpu: "100m", memory: "256Mi"}
				limits: memory: "1Gi"
			}
		}
	}

	// The database's serving certificate, for the names a client in the
	// cluster reaches the -rw Service by. cert-manager writes the issuing
	// CA, the private root, as ca.crt beside it, which CloudNativePG reads
	// as the server CA.
	Certificate: "\(DB.cluster)-server": {
		metadata: namespace: NS
		spec: {
			secretName: Secrets.serverTLS
			dnsNames: [
				"\(DB.cluster)-rw",
				"\(DB.cluster)-rw.\(NS)",
				DB.host,
				"\(DB.host).\(DNSDomain)",
			]
			usages: ["server auth"]
			privateKey: {
				algorithm:      "ECDSA"
				size:           256
				rotationPolicy: "Always"
			}
			issuerRef: {
				group: "cert-manager.io"
				kind:  "ClusterIssuer"
				name:  PrivateCA.issuer
			}
		}
	}

	// The role Job: setup.sql, from the submodule through the input's
	// ConfigMap, run with psql as the superuser against the -rw Service.
	// Every statement converges, and ALTER ROLE sets each user's password
	// from its Secret, so it runs on every sync: an Argo CD Sync hook,
	// deleted and re-created each time (BeforeHookCreation), since a Job's
	// template cannot change in place, and deleted with its pod once it
	// succeeds, so no finished pod keeps a node's copy of the immutable
	// password Secrets (README.md, External Secrets). Sync, not PostSync:
	// ate-api-server cannot become Healthy until its roles exist, so a
	// PostSync hook would never run. It waits for the database itself.
	Job: "\(DB.cluster)-setup": {
		metadata: {
			namespace: NS
			labels:    SetupLabels
			annotations: {
				"argocd.argoproj.io/hook":               "Sync"
				"argocd.argoproj.io/hook-delete-policy": "BeforeHookCreation,HookSucceeded"
			}
		}
		spec: {
			backoffLimit: 6
			// A new cluster's database takes a few minutes: the volume,
			// the image and initdb.
			activeDeadlineSeconds: 900
			template: {
				metadata: labels: SetupLabels
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
						image: PostgreSQLImage
						command: ["/bin/sh", "-c", SetupScript]
						env: [
							{name: "PGHOST", value: DB.host},
							{name: "PGPORT", value: "\(DB.port)"},
							{name: "PGDATABASE", value: DB.database},
							{name: "PGSSLMODE", value: "verify-full"},
							{name: "PGSSLROOTCERT", value: "/etc/private-ca/\(PrivateCA.bundleKey)"},
							{name: "PGCONNECT_TIMEOUT", value: "5"},
							{name: "PGUSER", valueFrom: secretKeyRef: {name: Secrets.superuser, key: "username"}},
							{name: "PGPASSWORD", valueFrom: secretKeyRef: {name: Secrets.superuser, key: "password"}},
							{name: "OWNER_PASSWORD", valueFrom: secretKeyRef: {name: Secrets.users, key: Roles.owner.user}},
							{name: "READWRITE_PASSWORD", valueFrom: secretKeyRef: {name: Secrets.users, key: Roles.readwrite.user}},
						]
						volumeMounts: [
							{name: "sql", mountPath: "/sql", readOnly: true},
							{name: "private-ca", mountPath: "/etc/private-ca", readOnly: true},
						]
						resources: {
							requests: {cpu: "10m", memory: "32Mi"}
							limits: memory: "128Mi"
						}
						securityContext: Restricted
					}]
					volumes: [
						{name: "sql", configMap: name: "\(DB.cluster)-setup"},
						{name: "private-ca", configMap: name: PrivateCA.bundle},
					]
				}
			}
		}
	}

	// ate-api-server's connection strings and schema, from the generated
	// passwords, through the store below. Owner: it follows its source.
	ExternalSecret: (Secrets.envVars): {
		metadata: namespace: NS
		spec: {
			refreshInterval: "1h"
			secretStoreRef: {kind: "SecretStore", name: Secrets.users}
			target: {
				creationPolicy: "Owner"
				template: {
					engineVersion: "v2"
					mergePolicy:   "Replace"
					data:          DSNs
				}
			}
			data: [
				{secretKey: "owner", remoteRef: {key: Secrets.users, property: Roles.owner.user}},
				{secretKey: "readwrite", remoteRef: {key: Secrets.users, property: Roles.readwrite.user}},
			]
		}
	}

	// The RustFS keys' copy, from the immutable rustfs-substrate the rustfs
	// component generates, through the store below, as quay copies
	// rustfs-quay.
	ExternalSecret: (RustFS.keys): {
		metadata: namespace: NS
		spec: {
			refreshInterval: "1h"
			secretStoreRef: {kind: "SecretStore", name: RustFS.namespace}
			target: creationPolicy: "Owner"
			dataFrom: [{extract: key: RustFS.keys}]
		}
	}

	// The database's NetworkPolicy. Upstream's default-deny-ingress covers
	// every pod in the namespace, CloudNativePG's instance among them: the
	// operator reaches the instance manager on 8000 and PostgreSQL on 5432,
	// and ate-api-server and the role Job reach PostgreSQL. ate-system is
	// not in the mesh, so no HBONE port is needed. kagent adds a policy of
	// its own for its namespace.
	NetworkPolicy: (DB.cluster): {
		metadata: namespace: NS
		spec: {
			podSelector: matchLabels: "cnpg.io/cluster": DB.cluster
			policyTypes: ["Ingress"]
			ingress: [
				{
					from: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "cnpg-system"}]
					ports: [{protocol: "TCP", port: 8000}, {protocol: "TCP", port: 5432}]
				},
				{
					from: [
						{podSelector: matchLabels: app: "ate-api-server"},
						{podSelector: matchLabels: SetupLabels},
					]
					ports: [{protocol: "TCP", port: 5432}]
				},
			]
		}
	}

	// The platform's gVisor pool, in a namespace of its own, which the
	// worker pods' capabilities and unconfined profiles need privileged.
	// One worker per general worker node; a worker's capacity is
	// unconstrained, as no limits are set. The class default SandboxConfig,
	// gvisor-default, fetches gVisor from Google's bucket, anonymously
	// (Holos_Distro/substrate-bank-hardening). ate-controller creates the
	// worker ServiceAccount, ateworker, which needs no pull secret: the image
	// is public. kagent's ActorTemplates select the pool by its two labels,
	// whose namespace is kagent's, the agents', not the pool's.
	Namespace: (Pool.namespace): metadata: labels: "pod-security.kubernetes.io/enforce": "privileged"
	WorkerPool: (Pool.name): {
		metadata: {
			namespace: Pool.namespace
			labels: {
				"kagent.dev/worker-pool-namespace": Kagent.namespace
				"kagent.dev/worker-pool-name":      Pool.name
			}
		}
		spec: {
			replicas:    3
			workerImage: S.images["ateworker-gvisor"]
			sandboxClasses: [{name: "gvisor"}]
			template: nodeSelector: "holos.run/nodepool": "general"
		}
	}
}

// The generated Secrets: the initdb owner's login, the superuser's login,
// which CloudNativePG requires to be postgres, and the two users'
// passwords, which setup.sql sets and the connection strings carry.
_Resources: (#GeneratedSecret & {
	name:      Secrets.app
	namespace: NS
	username:  DB.database
}).resources
_Resources: (#GeneratedSecret & {
	name:      Secrets.superuser
	namespace: NS
	username:  "postgres"
}).resources
_Resources: (#GeneratedSecret & {
	name:      Secrets.users
	namespace: NS
	generator: spec: secretKeys: [Roles.owner.user, Roles.readwrite.user]
}).resources

// The stores: one that may get the users' passwords in this namespace, for
// the connection strings, and one that may get rustfs-substrate in rustfs.
_Resources: (#ScopedSecretStore & {
	name:      Secrets.users
	namespace: NS
	source:    NS
	secrets: [Secrets.users]
}).resources
_Resources: (#ScopedSecretStore & {
	name:      RustFS.namespace
	namespace: NS
	source:    RustFS.namespace
	secrets: [RustFS.keys]
}).resources
