package holos

// Kagent names what Substrate must know of kagent before kagent is installed
// (interview Q26): its namespace, which is also its atespace, and its
// controller's identity. The substrate component puts the controller on the
// router's allowed list and among the API server's bootstrap owners, and maps
// the kagent atespace to the kagent namespace in the credential provider's
// policy, all from here, so the kagent component, which reads the same
// definition, cannot disagree with it.
//
// It also pins kagent, the holos-run fork (docs/forks.md): the fork's commit,
// the charts and images ghcr.io/holos-run published from it, by digest, and
// the agents' harness and sandbox guest images, which the fork does not
// build. The kagent-crds and kagent components read the pins here; the names
// that need the ingress Gateway or Keycloak are in components/kagent.cue.
//
// To bump, set commit and version to the new publish run's, copy every digest
// from its references, re-read the chart's values.yaml against the kagent
// component's, re-copy components/kagent/setup.sql if the fork's changed, and
// move harnessImages and guestImage to the upstream release nearest the new
// fork's base. Moving harnessImages.claude moves the agent image's base too:
// set the digest in components/product-planboard/Dockerfile and rebuild that
// image (README.md, Building the Planboard images). A bump that changes
// kagent's initial migration in place needs the kagent schema dropped and
// re-created on the cluster (README.md, Substrate, Bumping the pin).
Kagent: {
	namespace: "kagent"
	// atespace is the Substrate atespace kagent creates for its agents
	// through the API.
	atespace: namespace

	// commit is the fork's, on its holos-2026-11-06 branch, which is
	// upstream kagent-dev/kagent's tag v1.0.0-rc3 at 3548b7aa with the
	// fork's one change on top: the build against the holos-run Substrate
	// fork at Substrate.commit, where upstream builds against
	// kagent-dev/substrate v1.0.0 (docs/forks.md).
	commit: "3af6ae590abcaaf4235006185ba47b82427a13bf"
	// version is the tag publish-images.yaml published the images and the
	// charts under. It is also the controller's version.Version, which the
	// controller compares with harnessImages.release.
	version:  "0.0.0-holos.20261107.3af6ae5"
	registry: "ghcr.io/holos-run/kagent"

	// charts are the fork's two OCI charts. The digests are for the reader:
	// holos pulls by version and caches the chart in the component's
	// vendor/, which is committed.
	charts: {
		crds: {
			name:   "oci://\(registry)/helm/kagent-crds"
			digest: "sha256:8bb8d1bcafaa180980225ca4809b6db53414872eee21cb2a368aec43b1dbb483"
		}
		kagent: {
			name:   "oci://\(registry)/helm/kagent"
			digest: "sha256:48d31481b0634cc50cc7a77d01e0bebcd68c686b41f0f067bd83c11764aa599d"
		}
	}

	// digests are the index digests of the fork's two images, public and
	// pulled anonymously, by the image's name under registry.
	digests: {
		controller: "sha256:6c6d1fef30e43f36cc77e090bc9221d1037287b2f1978c6fa5af442afc5b8057"
		ui:         "sha256:2eb18ef5bf788c5af382506a30f5354681872cc69ddd5b200d82f6ab5b0f43c6"
	}

	// upstream is the kagent-dev release the fork is cut from. The fork
	// builds only the controller and the UI, so the agents' images come from
	// this release, by the index digests its chart's
	// files/builtin-harness-images.json lists, which the fork's chart does
	// not carry. They have to be this release's: since v1.0.0-rc3 a harness
	// fetches its configuration from the controller's bootstrap RPC, with no
	// fallback to the environment, so an older harness cannot start under
	// this controller.
	upstream: {
		release:  "1.0.0-rc3"
		registry: "ghcr.io/kagent-dev/kagent"
	}
	// harnessImages are config.harnessImages, the built-in Harness images by
	// harness. The controller refuses an image not pinned by digest. The
	// fourth key, release, stays unset: the controller refuses to start when
	// it is set and differs from its own version, which is the fork's tag.
	harnessImages: {
		kagent: "\(upstream.registry)/golang-adk:\(upstream.release)@sha256:51859027b42b704c8f443876ef5155ace2f411752f297e5cb43e04d9b91545b7"
		claude: "\(upstream.registry)/claude-harness:\(upstream.release)@sha256:216613bf155d3d437765675144fee19c9045cb21cd2e481189f2dcae36c24b3b"
		codex:  "\(upstream.registry)/codex-harness:\(upstream.release)@sha256:84c3275e36c0d98472a8b930a628e47e08277e7ce4438908e2a44fd1d8a9efd2"
	}
	// guestImage is config.sandboxes.guestImage, the guest a SandboxTemplate's
	// standalone sandbox runs in place of its image's entrypoint, from the
	// same release, by the index digest of its tag. Agents do not use it;
	// without it every SandboxTemplate is refused as unpinned.
	guestImage: "\(upstream.registry)/sandbox-guest:\(upstream.release)@sha256:8521d7e41097fb2964570ce1e65115056098d1c0c17c5dab1c2a4f30a7e06939"

	// modelKey is the key of a model's Secret that a ModelConfig reads,
	// ANTHROPIC_API_KEY: kagent-anthropic's in kagent's namespace and each
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
	// kagent's setup.sql (go/core/pkg/postgressetup at commit) and the
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
