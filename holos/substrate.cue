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
	// commit is the fork's, on its holos-2026-10-28 branch. It must equal
	// the submodule's HEAD (git -C holos/vendor/substrate rev-parse HEAD).
	commit: "475f49b023352b47b8504ffead596953f28d7e7f"
	// version is the tag publish-images.yaml published every image under, kept
	// for the reader; the components pull by digest alone.
	version:  "v0.0.0-holos.20261028.475f49b"
	registry: "ghcr.io/holos-run/substrate"

	// digests are the index digests of the images the publish run pushed
	// (substrate-and-kagent-images-built-on-the-garage-runner), public and
	// pulled anonymously, by the image's name: the last element of its
	// ko://go.ate.dev/substrate/cmd/<path> import path, as ko names it, so
	// credential-provider/kubernetes-secrets is kubernetes-secrets.
	// envoy-dataplane is built from a Dockerfile, not by ko, and is the one
	// image whose digest a local build does not reproduce.
	digests: {
		"ate-idp-server":     "sha256:f93be95c1ee43fcbc619e6eb43d5392bef15c19d3fdf25e5d2251e28203c67b7"
		ateapi:               "sha256:0f686185f3b109e3c749d19619a5b1d3fc25b15029bbc1e798c9ab8381393041"
		atecontroller:        "sha256:d1fe5d83c302327d515e6ad77fe9753288fbcd1663aee52efb1d7e62b7dc1ae7"
		atelet:               "sha256:8ef83c880bf6db3445a419fae172ef4f6f4c0ea0b055a489bb5f9a3713ced26b"
		atenet:               "sha256:92cb0ffb6b74cc30c9b559648d95500bf9f79ddd97b3067833d90b974342f6fa"
		"ateworker-gvisor":   "sha256:9f16968c56534b9fbf92ceb5853a9dafddfe3ff498edabe9ba6010fbcbb3ac23"
		"ateworker-microvm":  "sha256:b3a9333da9bbebece419b7b7965276a9ffa71f9d637a567b2f674fff422ec9f9"
		"envoy-dataplane":    "sha256:e1016f18e8e30236cc0535a7eb9955a9f9892ed23044447d4c87f446a1dc6bf6"
		"kubernetes-secrets": "sha256:5c310ddc73370b9e2168177ae6a11fdd26ca9ecfb15697d20f3346953e493b11"
		"objectstore-plugin": "sha256:1ccc33f1b437bc1963daf6f2435a159bbc9c0e9ea05d0b36148ca89469b4e340"
		podcertcontroller:    "sha256:0842b4f1ea6ae9d025bd9360a929fb1d6d105cdca1df6f61f8afc63f534a0bfa"
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
	// client is the ServiceAccount kubectl ate mints its token for when it
	// is given none: a bootstrap owner, so whoever can mint its token is a
	// global owner of the install.
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
	}

	// workerPool is the platform's one gVisor WorkerPool, in its own
	// privileged namespace, on the general workers.
	workerPool: {
		namespace: "ate-workers"
		name:      "gvisor"
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
