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
// component's, and move harnessImages and guestImage to the upstream release
// nearest the new fork's base.
Kagent: {
	namespace: "kagent"
	// atespace is the Substrate atespace kagent creates for its agents
	// through the API.
	atespace: namespace

	// commit is the fork's, on its holos-2026-10-28 branch, which is
	// upstream kagent-dev/kagent main at d9cc3a82 with the fork's two
	// changes on top.
	commit: "fa2cb2361ee45da4b3e757a618128c298680d458"
	// version is the tag publish-images.yaml published the images and the
	// charts under. It is also the controller's version.Version, which the
	// controller compares with harnessImages.release.
	version:  "0.0.0-holos.20261028.fa2cb23"
	registry: "ghcr.io/holos-run/kagent"

	// charts are the fork's two OCI charts. The digests are for the reader:
	// holos pulls by version and caches the chart in the component's
	// vendor/, which is committed.
	charts: {
		crds: {
			name:   "oci://\(registry)/helm/kagent-crds"
			digest: "sha256:440ad8ea2681f48f4dde0305f5eac03bd734267f9af43cc22135de36cacd68c8"
		}
		kagent: {
			name:   "oci://\(registry)/helm/kagent"
			digest: "sha256:725614ef1ae69d3b3481ecaa731d67b007a05a6d43566c9a50b88f0e2c62c1ac"
		}
	}

	// digests are the index digests of the fork's two images, public and
	// pulled anonymously, by the image's name under registry.
	digests: {
		controller: "sha256:5da882d7f78cd17d155ab3a24f145d7ddc2ad91e71f40f8c04e0312b615cb69c"
		ui:         "sha256:36e29c6a21d607eb78e4e58383ed7515d59563dc939ae76fe29ce92f1a593514"
	}

	// upstream is the kagent-dev release nearest the fork's base: d9cc3a82
	// is v1.0.0-alpha17 and 38 commits, and no later release exists. The
	// fork builds only the controller and the UI, so the agents' images
	// come from this release, by the index digests its chart's
	// files/builtin-harness-images.json lists, which the fork's chart does
	// not carry. Between alpha17 and d9cc3a82 the harnesses gained only
	// fields whose zero value is the old behavior (disableAskUser,
	// strictOutputSchema), which the controller's protojson omits.
	upstream: {
		release:  "1.0.0-alpha17"
		registry: "ghcr.io/kagent-dev/kagent"
	}
	// harnessImages are config.harnessImages, the built-in Harness images by
	// harness. The controller refuses an image not pinned by digest. The
	// fourth key, release, stays unset: the controller refuses to start when
	// it is set and differs from its own version, and these are alpha17's.
	harnessImages: {
		kagent: "\(upstream.registry)/golang-adk:\(upstream.release)@sha256:d20d411759d7bb549f00b7d6e8d669b91694aeb57dce847dcd2cbb68aa0d45f3"
		claude: "\(upstream.registry)/claude-harness:\(upstream.release)@sha256:69cbd021825de5b6798723c96a4ae72f78a4916e70e4f1cd7f6bd5678e6641ff"
		codex:  "\(upstream.registry)/codex-harness:\(upstream.release)@sha256:1c8565efce78c420b6726c68eaf010363fafd4eeec0c1afcd317d9e517434c22"
	}
	// guestImage is config.sandboxes.guestImage, the guest a SandboxTemplate's
	// standalone sandbox runs in place of its image's entrypoint, from the
	// same release, by the index digest of its tag. Agents do not use it;
	// without it every SandboxTemplate is refused as unpinned.
	guestImage: "\(upstream.registry)/sandbox-guest:\(upstream.release)@sha256:5355072effb219e157c3e0471637ca64d1f84ab7513dde23968c20cd65d18c9b"

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
