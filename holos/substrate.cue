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
	// commit is the fork's, on its holos-2026-11-06 branch, upstream
	// agent-substrate/substrate main at 94e0a26a with nothing added, which
	// is v1.0.0 in everything that runs (docs/forks.md). It must equal the
	// submodule's HEAD (git -C holos/vendor/substrate rev-parse HEAD).
	commit: "94e0a26ac90151886a76410568aaac2664a54d90"
	// version is the tag publish-images.yaml published every image under, kept
	// for the reader; the components pull by digest alone.
	version:  "v0.0.0-holos.20261105.94e0a26"
	registry: "ghcr.io/holos-run/substrate"

	// digests are the index digests of the images the publish run pushed
	// (substrate-and-kagent-images-built-on-the-garage-runner), public and
	// pulled anonymously, by the image's name: the last element of its
	// ko://go.ate.dev/substrate/cmd/<path> import path, as ko names it, so
	// credential-provider/kubernetes-secrets is kubernetes-secrets.
	// envoy-dataplane is built from a Dockerfile, not by ko, and is the one
	// image whose digest a local build does not reproduce.
	digests: {
		"ate-idp-server":     "sha256:59e1242ac8e7af0e4bd28615f7180ee39e6ec879ad8443cf9b5dbb48867a43f3"
		ateapi:               "sha256:e8c0071e6327f7c689ee332af5b5ec302f9b4f385acf9f3240a421344a124cd6"
		atecontroller:        "sha256:c47fb0951ee96c69b5c4faeeb0e915cceafdf4d6305bf51d0e227491bdf9a48c"
		atelet:               "sha256:13057dbc2346c8b67dac2fb6ba0c820ff21d1ceb36d0a205a6875dea144cd744"
		atenet:               "sha256:c0a6b860d47e290ffe0eaeda032c67353a2b42f56375fa103a4ce5ffb0d9fada"
		"ateworker-gvisor":   "sha256:f1d6844f3037e6f27bd093c99bf38f0baa86f59641bf96265ba2eed517bd167e"
		"ateworker-microvm":  "sha256:44ff2ab8554da86e6769df401a5429d4969728f155f67e7ee30686a783c072b1"
		"envoy-dataplane":    "sha256:a81bdc703ae10e34ec48ae24a1044a985ad82a4d585e3fa61d7e2858547879a9"
		"kubernetes-secrets": "sha256:236d44b1c4eabe385df3d1cf9f83a6914e5b915c71b3c6d15120eaeb8953c9a5"
		"objectstore-plugin": "sha256:1648297ceac9200739fde63a702f2879809f82b6364b1dbaeb0196e445ce36a5"
		podcertcontroller:    "sha256:c0be27d91dd46b107f0e632aa3421585175af51fc83d6bdc8f20f9cb1c49d078"
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
