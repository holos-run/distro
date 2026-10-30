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
// fork's base. Before its RC kagent edits its initial migration in place
// rather than adding one, so a bump may need the kagent schema dropped and
// re-created on the cluster (README.md, kagent, Bumping the pin).
Kagent: {
	namespace: "kagent"
	// atespace is the Substrate atespace kagent creates for its agents
	// through the API.
	atespace: namespace

	// commit is the fork's, on its holos-2026-10-30 branch, which is
	// upstream kagent-dev/kagent main at 8f6910c8 with the fork's two
	// changes on top: the router dialers' mutual TLS, and the build against
	// the holos-run Substrate fork at Substrate.commit, where upstream builds
	// against kagent-dev/substrate v0.7.0-alpha2 (docs/forks.md).
	commit: "e1696d861ac609c3e7ae8c5f294623ade261cffd"
	// version is the tag publish-images.yaml published the images and the
	// charts under. It is also the controller's version.Version, which the
	// controller compares with harnessImages.release.
	version:  "0.0.0-holos.20261030.e1696d8"
	registry: "ghcr.io/holos-run/kagent"

	// charts are the fork's two OCI charts. The digests are for the reader:
	// holos pulls by version and caches the chart in the component's
	// vendor/, which is committed.
	charts: {
		crds: {
			name:   "oci://\(registry)/helm/kagent-crds"
			digest: "sha256:c32d9fdb25d9d6aebd145e31bb7e786c1123fd5e53fff36eb03ca5e9f0c8db40"
		}
		kagent: {
			name:   "oci://\(registry)/helm/kagent"
			digest: "sha256:d0683909f325e64a4c9ba2c56ee22e544c93ba80284edc3914eb37612bb8ebb8"
		}
	}

	// digests are the index digests of the fork's two images, public and
	// pulled anonymously, by the image's name under registry.
	digests: {
		controller: "sha256:1e1aee64e0484b92572fb1bb6fc66e5d538d3eb61019935b6ac98f763635178e"
		ui:         "sha256:e4ed5be8ddec69fbc15d0a8f468255d2091f45314ae072bc40fd1c8b40335552"
	}

	// upstream is the kagent-dev release nearest the fork's base: 8f6910c8
	// is v1.0.0-alpha17 and 48 commits, and no later release exists. The
	// fork builds only the controller and the UI, so the agents' images
	// come from this release, by the index digests its chart's
	// files/builtin-harness-images.json lists, which the fork's chart does
	// not carry. Between alpha17 and 8f6910c8 the agent config the
	// controller writes to a harness (proto/kagent/config, ADKAgentConfig and
	// what it holds) gained only fields whose zero value is the old behavior
	// (disableAskUser, strictOutputSchema), which the controller's protojson
	// omits, and lost ADKAgentConfig's network and share_tools (upstream
	// #3454), which the controller never set; their field numbers are not
	// reused. The other additions in that package (CLIConfig.tui,
	// AuthenticationConfig.service_account, PushConfig's max_concurrency and
	// send_timeout) are controller and CLI messages a harness never reads.
	// The runtime API the harnesses call (proto/kagent/runtime) changed
	// only in comments and dropped reserved statements, reusing no number.
	// So alpha17's harnesses read what this controller writes as before.
	//
	// What did change for them is Substrate: since upstream #2392 (in this
	// pin) an actor runs as its image's USER and WORKDIR, and golang-adk's
	// is 65532 at /, so the harness can no longer create its default config
	// directory /config. A Harness sets workload.args to
	// ["--filepath", "/data/config"], a directory that user owns in the
	// image (README.md, kagent, Agents and the worker pool), until an
	// upstream harness image allows for it.
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
