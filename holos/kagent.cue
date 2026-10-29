package holos

// Kagent names what Substrate must know of kagent before kagent is installed
// (interview Q26): its namespace, which is also its atespace, and its
// controller's identity. The substrate component puts the controller on the
// router's allowed list and among the API server's bootstrap owners, and maps
// the kagent atespace to the kagent namespace in the credential provider's
// policy, all from here, so the kagent component, which reads the same
// definition, cannot disagree with it.
Kagent: {
	namespace: "kagent"
	// atespace is the Substrate atespace kagent creates for its agents
	// through the API.
	atespace: namespace

	controller: {
		serviceAccount: "kagent-controller"
		// spiffeID is the SPIFFE ID of the controller's pod certificate from
		// Substrate's pod identity signer, which is also the principal the
		// API server authenticates it as over mutual TLS.
		spiffeID: "spiffe://\(Substrate.trustDomain)/ns/\(namespace)/sa/\(serviceAccount)"
	}
}
