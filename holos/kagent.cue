package holos

// Kagent names what Substrate must know of kagent before kagent is installed
// (interview Q26): its namespace, which is also its atespace, and its
// controller's identity. The substrate component puts the controller on the
// router's allowed list and among the API server's bootstrap owners, and maps
// the kagent atespace to the kagent namespace in the credential provider's
// policy, all from here, so the kagent component, which reads the same
// definition, cannot disagree with it.
//
// The release the cluster runs, with its charts and images, and the names that
// need the ingress Gateway or Keycloak, are in components/kagent.cue.
Kagent: {
	namespace: "kagent"
	// atespace is the Substrate atespace kagent creates for its agents
	// through the API.
	atespace: namespace

	// registry is where the fork's charts and images are published.
	registry: "ghcr.io/holos-run/kagent"

	// modelKey is the key of a model's Secret that a ModelConfig reads,
	// ANTHROPIC_API_KEY: kagent-anthropic's in kagent's namespace (on a
	// cluster with no binding that runs an agent) and each
	// claim's planboard-anthropic (components/product-planboard).
	modelKey: "ANTHROPIC_API_KEY"

	// release is the Helm release name. The chart names its objects after
	// it, <release>-controller among them, which is the controller's
	// ServiceAccount below.
	release: "kagent"

	controller: {
		serviceAccount: "\(release)-controller"
		// service is the controller's Service, and port its HTTP and gRPC
		// port, which the UI, oauth2-proxy's upstream and sandboxed agents,
		// through Substrate's egress gateway, call.
		service: "\(release)-controller"
		port:    8083
		// spiffeID is the SPIFFE ID of the controller's pod certificate from
		// Substrate's pod identity signer, which is also the principal the
		// API server authenticates it as over mutual TLS.
		spiffeID: "spiffe://\(Substrate.trustDomain)/ns/\(namespace)/sa/\(serviceAccount)"
	}

	// database is kagent's share of Substrate's CloudNativePG cluster: its
	// own schema, two NOLOGIN roles and a login user for each, the names
	// kagent's setup.sql (go/core/pkg/postgressetup) and the
	// chart's config.database default to.
	database: {
		schema: "kagent"
		owner: {
			role: "kagent_owner"
			user: "kagent_owner_user"
		}
		readwrite: {
			role: "kagent_readwrite"
			user: "kagent_readwrite_user"
		}
	}
}
