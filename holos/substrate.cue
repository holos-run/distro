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
	// commit is the fork's, on its holos-2026-10-30 branch, upstream
	// agent-substrate/substrate main on that date with nothing added. It
	// must equal the submodule's HEAD (git -C holos/vendor/substrate
	// rev-parse HEAD).
	commit: "f475d8b4cc8ad071bac7ba8fcace30212f1b56b0"
	// version is the tag publish-images.yaml published every image under, kept
	// for the reader; the components pull by digest alone.
	version:  "v0.0.0-holos.20261030.f475d8b"
	registry: "ghcr.io/holos-run/substrate"

	// digests are the index digests of the images the publish run pushed
	// (substrate-and-kagent-images-built-on-the-garage-runner), public and
	// pulled anonymously, by the image's name: the last element of its
	// ko://go.ate.dev/substrate/cmd/<path> import path, as ko names it, so
	// credential-provider/kubernetes-secrets is kubernetes-secrets.
	// envoy-dataplane is built from a Dockerfile, not by ko, and is the one
	// image whose digest a local build does not reproduce.
	digests: {
		"ate-idp-server":     "sha256:406d4e7bdfd07e9af8e826382f2d69ea3359257ba5ccad10ba783838718745cd"
		ateapi:               "sha256:743244e3ac1886310f47355e69a3c0e9274564351e9e9da83b3361a50fecbb43"
		atecontroller:        "sha256:01b9cd6d6843e82cc321c416ba2d829b89fff721e7a17275ce07b80c5af11e1e"
		atelet:               "sha256:a61b4b21078ae2e640e23bad20c18a209c46d2a76c2aa8a0c02147d573588d47"
		atenet:               "sha256:eab33c963d7a6eb2a83647b13e1ef906ef02897362cebcbce1d933f88325f766"
		"ateworker-gvisor":   "sha256:33b4e6dcd8d236063e44e5f3b92fbb6d85de470c6719f2643b5ffcb43a5bad68"
		"ateworker-microvm":  "sha256:9900583fbe0ce8d7b5278710243dc98c43da7ff52142238fd6a843b03096432d"
		"envoy-dataplane":    "sha256:590650c5db48cc88b4c363ab91dce076e15be4e76c6bbb83316068d44b6c553f"
		"kubernetes-secrets": "sha256:0c43ae939fb39bd13985fc1dd990285f51a633803c2e770f6308460d9245c0a0"
		"objectstore-plugin": "sha256:fbf8d4ed43a4ef1fb14db699133e07c6fe0d7e935a7639b7b18f55c05ad707fb"
		podcertcontroller:    "sha256:6efa8af09d7390f73b5c8e5917e9cb0f679b427cf6f8883afc4b6897c86bd828"
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
	// the audience of the ServiceAccount tokens it accepts.
	api: {
		host:     "api.\(namespace).svc"
		audience: host
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
