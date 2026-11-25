package holos

import "list"

// Kagent's names that need the ingress Gateway and Keycloak, which only
// component instances load: its public URL and its Keycloak client, and the
// claims it runs agents for on this cluster. The names Substrate reads are in
// kagent.cue at the platform root.
//
// Also the release this cluster runs, from its pins (pins/<cluster>.cue), the
// holos-run fork (docs/forks.md): the fork's commit, the charts and images
// ghcr.io/holos-run published from it, by digest, and the agents' harness and
// sandbox guest images, which the fork does not build.
//
// To bump a cluster, set its pins.kagent: commit and version to the new publish
// run's, every digest from its references, and upstream to the upstream release
// nearest the new fork's base. Copy the fork's setup.sql to
// components/kagent/vendor/<version>/ and re-read the chart's values.yaml against
// the kagent component's. Moving upstream.harnesses.claude moves the agent
// image's base too: set the digest in components/product-planboard/Dockerfile and
// rebuild that image (README.md, Building the Planboard images). A bump that
// changes kagent's initial migration in place needs the kagent schema dropped and
// re-created on the cluster (README.md, Substrate, Bumping the pin).
Kagent: {
	let Pins = Cluster.pins.kagent

	// commit is the fork's: an upstream release with the fork's one change on
	// top, the build against the holos-run Substrate fork at Substrate.commit,
	// where upstream builds against kagent-dev/substrate (docs/forks.md).
	commit: Pins.commit
	// version is the tag publish-images.yaml published the images and the
	// charts under. It is also the controller's version.Version, which the
	// controller compares with harnessImages.release.
	version: Pins.version

	// charts are the fork's two OCI charts. The digests are for the reader:
	// holos pulls by version and caches the chart in the component's
	// vendor/, which is committed.
	charts: {
		crds: {
			name:   "oci://\(Kagent.registry)/helm/kagent-crds"
			digest: Pins.charts.crds
		}
		kagent: {
			name:   "oci://\(Kagent.registry)/helm/kagent"
			digest: Pins.charts.kagent
		}
	}

	// digests are the index digests of the fork's two images, public and
	// pulled anonymously, by the image's name under registry.
	digests: Pins.digests

	// upstream is the kagent-dev release the fork is cut from. The fork
	// builds only the controller and the UI, so the agents' images come from
	// this release, by the index digests its chart's
	// files/builtin-harness-images.json lists, which the fork's chart does
	// not carry. They have to be this release's: since v1.0.0-rc3 a harness
	// fetches its configuration from the controller's bootstrap RPC, with no
	// fallback to the environment, so an older harness cannot start under
	// this controller.
	upstream: {
		release:  Pins.upstream.release
		registry: "ghcr.io/kagent-dev/kagent"
	}
	// harnessImages are config.harnessImages, the built-in Harness images by
	// harness. The controller refuses an image not pinned by digest. The
	// fourth key, release, stays unset: the controller refuses to start when
	// it is set and differs from its own version, which is the fork's tag.
	harnessImages: {
		kagent: "\(upstream.registry)/golang-adk:\(upstream.release)@\(Pins.upstream.harnesses.kagent)"
		claude: "\(upstream.registry)/claude-harness:\(upstream.release)@\(Pins.upstream.harnesses.claude)"
		codex:  "\(upstream.registry)/codex-harness:\(upstream.release)@\(Pins.upstream.harnesses.codex)"
	}
	// guestImage is config.sandboxes.guestImage, the guest a SandboxTemplate's
	// standalone sandbox runs in place of its image's entrypoint, from the
	// same release, by the index digest of its tag. Agents do not use it;
	// without it every SandboxTemplate is refused as unpinned.
	guestImage: "\(upstream.registry)/sandbox-guest:\(upstream.release)@\(Pins.upstream.guest)"

	// toolsTag is the tool server's image tag, with its digest, which the
	// subchart puts after the colon as it is.
	toolsTag: "\(Pins.tools.version)@\(Pins.tools.digest)"

	// host and url are the UI's one public name, behind oauth2-proxy, under
	// the ingress Gateway's wildcard certificate, so no Certificate of its
	// own.
	host: IngressGateway.hosts.kagent
	url:  "https://\(host)"

	// clientId is the confidential client oauth2-proxy logs in through,
	// which a holos-controller Client in kagent's namespace creates in the
	// realm. It is also the aud of the ID tokens oauth2-proxy accepts.
	// oidcSecret is the Secret there the controller delivers its secret
	// to.
	clientId: "kagent"
	oidcSecret: {
		name: "kagent-oidc-client"
		key:  "client-secret"
	}
	// callback is oauth2-proxy's redirect URL, the client's one redirect
	// URI.
	callback: "\(url)/oauth2/callback"

	// proxy is oauth2-proxy, the chart's subchart, which the ingress Gateway
	// routes every request for host to: its Service and port.
	proxy: {
		service: "\(Kagent.release)-oauth2-proxy"
		port:    4180
	}
	// ui is the UI's Service, nginx, which oauth2-proxy forwards to and
	// which proxies the API to the controller.
	ui: {
		service: "\(Kagent.release)-ui"
		port:    8080
	}

	// claims are the claims kagent runs agents for on this cluster, by name,
	// sorted: each claim with a binding here (clusterBindings,
	// collections.cue) of a product whose components name kagent. The
	// product's component renders the agents in the claim's namespace
	// (components/product-planboard), and the kagent component widens the
	// controller's RBAC and watch, and its login, to them. On a cluster with
	// no such binding it is empty, and kagent renders as it did before any.
	claims: list.SortStrings([for NAME, _ in {
		for B in clusterBindings[Cluster.name]
		for R in B.productRefs
		if list.Contains(products[R.name].components, "kagent") {(B.project): true}
	} {NAME}])

	// allowedGroups are the groups whose members may log in to kagent, as
	// full paths, the form the ID token's groups claim carries
	// (#ProjectRoleGroupPath): the platform's owners, and the owner and
	// editor groups of each of claims, who drive their claim's agent. A
	// viewer of a claim and a user of the realm in no group are refused at
	// the login. Only claims with an agent here: an owner of any other claim
	// would reach kagent's API and no agent of theirs. kagent has no
	// authorizer of its own, so whoever is admitted may use every agent in
	// every watched namespace (README.md, kagent).
	allowedGroups: list.SortStrings([
		Keycloak.groups.owners.path,
		for C in claims for ROLE in ["owner", "editor"] {
			(#ProjectRoleGroupPath & {project: C, role: ROLE}).claim
		},
	])
}
