package holos

import "strings"

// Substrate names what other components dial or select of Agent Substrate, the
// holos-run fork (docs/forks.md): the system namespace, the router, the API,
// the database the substrate component makes, and the platform's worker pool.
// Anything that talks to Substrate reads it here. The commit it runs and its
// images, which are the cluster's, are in components/substrate.cue.
Substrate: {
	// registry is where the fork's images are published
	// (substrate-and-kagent-images-built-on-the-garage-runner).
	registry: "ghcr.io/holos-run/substrate"

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
	// shim projects it (#AteAPIJob, components/ate-api-job.cue). The image is
	// the cluster's (components/substrate.cue).
	atespaceSetup: {
		labels: "app.kubernetes.io/name": "atespace-setup"
		dir: "/var/run/ate/api"
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
		// with no anti-affinity, from the fork's gVisor worker image, which is
		// the cluster's (components/substrate.cue). Each
		// worker reports its whole node as its capacity, so two pools on the
		// same nodes overcommit them. The substrate component renders it,
		// and each claim kagent runs agents for gets a copy of it, labeled for
		// the claim (components/product-planboard), so a bump moves
		// every pool of its cluster at once, and a new replica count every pool.
		spec: {
			replicas: 3
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
