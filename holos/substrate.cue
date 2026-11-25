package holos

import "strings"

// Substrate pins Agent Substrate, the holos-run fork (docs/forks.md): the
// fork's commit, which the submodule at vendor/substrate is checked out at
// and the substrate component renders upstream's install tree from, and the
// images ghcr.io/holos-run published from that commit, by digest. It also
// names what other components dial or select: the system namespace, the
// router, the API, the database the substrate component makes, and the
// platform's worker pool. Anything that talks to Substrate reads it here.
//
// To bump, check the submodule out at the new commit, set commit and version
// to match, copy every digest from the publish run's references, and re-read
// components/substrate/ATE-SETUP.md against the new ate-setup (README.md,
// Substrate). The render refuses a commit that is not the submodule's.
Substrate: {
	// commit is the fork's, on its holos-2026-11-25 branch, upstream
	// agent-substrate/substrate main at e54c359a with nothing added, the
	// newest commit kagent builds against (docs/forks.md). It must equal the
	// submodule's HEAD (git -C holos/vendor/substrate rev-parse HEAD).
	commit: "e54c359a11c9ed30e0fff6bfbaa2ee2665d809b8"
	// version is the tag publish-images.yaml published every image under, kept
	// for the reader; the components pull by digest alone.
	version:  "v0.0.0-holos.20261124.e54c359"
	registry: "ghcr.io/holos-run/substrate"

	// digests are the index digests of the images the publish run pushed
	// (substrate-and-kagent-images-built-on-the-garage-runner), public and
	// pulled anonymously, by the image's name: the last element of its
	// ko://go.ate.dev/substrate/cmd/<path> import path, as ko names it, so
	// credential-provider/kubernetes-secrets is kubernetes-secrets.
	// envoy-dataplane is built from a Dockerfile, not by ko, and is the one
	// image whose digest a local build does not reproduce.
	digests: {
		"ate-idp-server":     "sha256:1f6bb785e7f8c1fd77b893e6952756ba740add971ce53d446fb1626a6146a702"
		ateapi:               "sha256:3d1eca0ec41506f64af2a91970f46bd7961c202fc4185f943f27dc7a786daad4"
		atecontroller:        "sha256:5ed02c1701a130e496e81e3e8a37f95e014f6767771b6847d1857ed440a928e0"
		atelet:               "sha256:d8a889cc247ceb7b76458d9a36146f2b34aac17ac82e8191b6a5442ceb8d7780"
		atenet:               "sha256:783882a760d28a9e6674c74daed960684426e76b0ed1fb0dd2890081a8944702"
		"ateworker-gvisor":   "sha256:0ab15956e9da7ef494c8318ed498885add98309892170e191b6ae8217aba6d21"
		"ateworker-microvm":  "sha256:c694ac3ec823361220b160c69f843bb08cccb2511c54eb4ce536cfc1ea991031"
		"envoy-dataplane":    "sha256:1254a96d87a1a2e216114614606a223a48e387c7d4c5cf6683b13d8f91df007d"
		"kubernetes-secrets": "sha256:3903280cc6024acd1ce8ef247d759dac702a17a5dce1f6b10e714d201005f25d"
		"objectstore-plugin": "sha256:89b60788cf49083a088175adf48749d38c9a847aa4d0bbd9db31ac5b3d977410"
		podcertcontroller:    "sha256:4473113d8da57b74d72c611c57465a618aac78b9b25eeb162e8f2fae6396e08e"
	}

	// images are the full references, tag and digest, by name.
	images: {for NAME, DIGEST in digests {(NAME): "\(registry)/\(NAME):\(version)@\(DIGEST)"}}

	// namespace holds Substrate's control plane: the API server, the IdP,
	// the controller, the router, the egress gateway, the credential
	// provider, atelet and the database. It is privileged (atelet mounts
	// host paths) and stays out of the mesh: Substrate runs its own mutual
	// TLS on pod certificates.
	namespace: "ate-system"
	// podCertNamespace holds the pod certificate controller and its three
	// signer CA pools.
	podCertNamespace: "podcertificate-controller-system"

	// api is the API server's Service, the address every client dials, and
	// the audience of the ServiceAccount tokens it accepts. service is the
	// gRPC service kubectl ate calls. access is the namespace label the
	// server's NetworkPolicy admits a namespace's pods by, unless they are a
	// worker pool's.
	api: {
		host:     "api.\(namespace).svc"
		port:     443
		audience: host
		service:  "substrate.ateapi.v1.Control"
		access: "ate.dev/api-access": "true"
	}
	// atespaceSetup is the Job each ProjectClaim's atespace is made by
	// (components/project), and any other that calls the API. No image Substrate publishes carries kubectl ate,
	// so it calls the API with grpcurl, which reads the methods from the
	// server's gRPC reflection. labels are what the substrate component's
	// NetworkPolicy admits it to the API server by, and dir is where its pod
	// has its credential: a projected token for the API server, and the trust
	// bundle of the signer of the server's certificate, the live one, as the
	// shim projects it (#AteAPIJob, components/ate-api-job.cue).
	atespaceSetup: {
		labels: "app.kubernetes.io/name": "atespace-setup"
		dir:   "/var/run/ate/api"
		image: "docker.io/fullstorydev/grpcurl:v1.9.3-alpine@sha256:4614424ed58e9b9837c48b6b8eadb9ef40491d5af3499bcc8b378e9c64a9e4a9"
	}
	// issuer is the IdP's, the iss of every actor JWT, which ate-setup
	// defaults to the same name.
	issuer: "https://idp.\(namespace).svc"
	// router is the Envoy router actors are reached through, mutual TLS on
	// 443 (targetPort 8443) for clients whose pod certificate's SPIFFE ID is
	// on its allowed list.
	router: {
		name: "atenet-router"
		host: "\(name).\(namespace).svc"
		port: 443
		url:  "https://\(host):\(port)"
	}
	// client is the ate-client ksa (Kubernetes service account) kubectl ate
	// mints an ate-client ksa token for, a standard service account token,
	// when it is given none: a bootstrap owner, so whoever can mint that
	// token is a global owner of the install.
	client: {
		serviceAccount: "ate-client"
		principal:      "system:serviceaccount:\(namespace):\(serviceAccount)"
	}

	// database is the CloudNativePG cluster the substrate component makes in
	// namespace, which Substrate and kagent share, each with its own roles
	// and schema. Clients connect to the -rw Service with
	// sslmode=verify-full against the private root: the server certificate
	// is from the private-ca ClusterIssuer (PrivateCA).
	database: {
		cluster:  "substrate-db"
		host:     "\(cluster)-rw.\(namespace).svc"
		port:     5432
		database: "substrate"
		// image is keycloak's and quay's, CloudNativePG 1.30.1's default,
		// PostgreSQL 18.6, stated so an operator upgrade does not move the
		// database to a new major version by itself. The role Jobs,
		// Substrate's and kagent's, run psql from it.
		image: "ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie"
	}

	// workerPool is the platform's one gVisor WorkerPool, in its own
	// privileged namespace, on the general workers.
	workerPool: {
		namespace: "ate-workers"
		name:      "gvisor"
		// sandboxClass is the pool's one sandbox class, whose class default
		// SandboxConfig is gvisor-default. kagent's placeholder pool
		// (components/kagent) names the same class.
		sandboxClass: "gvisor"
		// spec is the pool's spec: three workers on the general worker nodes,
		// with no anti-affinity, from the fork's gVisor worker image. Each
		// worker reports its whole node as its capacity, so two pools on the
		// same nodes overcommit them. The substrate component renders it,
		// and each claim kagent runs agents for gets a copy of it, labeled for
		// the claim (components/product-planboard), so a bump or a new replica
		// count moves every pool at once.
		spec: {
			replicas:    3
			workerImage: images["ateworker-gvisor"]
			sandboxClasses: [{name: sandboxClass}]
			template: nodeSelector: "holos.run/nodepool": "general"
		}
	}

	// snapshots is where actors' durable snapshots are kept: RustFS's bucket
	// substrate (components/rustfs), and location, ate-api-server's
	// cluster-wide --snapshot-location, which the substrate component sets. A
	// kagent Harness names a location of its own under it, one directory per
	// namespace, which ate-api-server takes with its PerTemplateSnapshotLocation
	// gate (components/substrate).
	snapshots: {
		bucket:   "substrate"
		location: "s3://\(bucket)/"
	}

	// trustDomain is the pod identity signer's SPIFFE trust domain, fixed
	// in Substrate (installdefaults.AteletTrustDomain). It is Istio's too,
	// Istio's default, so a workload's mesh identity and its pod certificate
	// identity are the same string.
	trustDomain: "cluster.local"

	// signers are the pod certificate signers the controller serves; a pod
	// that projects a podCertificate from podidentity gets a certificate
	// whose SPIFFE ID is spiffe://<trust domain>/ns/<ns>/sa/<sa>, which the
	// router's allowed list matches exactly.
	signers: {
		podIdentity: "podidentity.podcert.ate.dev/identity"
		serviceDNS:  "servicedns.podcert.ate.dev/identity"
		postgres:    "postgres.podcert.ate.dev/identity"
	}
	// trustBundles are the ClusterTrustBundles the controller publishes, one
	// per signer, labeled podcert.ate.dev/canarying: live, which every
	// workload projects: <signer, / as :>:primary-bundle.
	trustBundles: [for S in signers {strings.Replace(S, "/", ":", 1) + ":primary-bundle"}]
}
