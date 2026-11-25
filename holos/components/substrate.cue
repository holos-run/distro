package holos

// Substrate's commit and images on this cluster, from its pins
// (pins/<cluster>.cue), and the images of what runs against it. The names are
// in substrate.cue at the platform root.
//
// To bump a cluster, add a submodule at the new commit and the commit's
// directory of the substrate component's input, set the cluster's
// pins.substrate, and re-read components/substrate/ATE-SETUP.md against the new
// ate-setup (README.md, Substrate, Bumping the pin). The render refuses a commit
// whose submodule is not at it.
Substrate: {
	let Pins = Cluster.pins.substrate

	// commit is the fork's, whose install tree the substrate component renders.
	commit: Pins.commit
	// tree is the submodule checked out at commit. There is one per commit a
	// cluster pins, and the name carries the commit, so two clusters on
	// different commits each render from their own.
	tree: "vendor/substrate-\(commit)"
	// version is the tag publish-images.yaml published every image under, kept
	// for the reader; the components pull by digest alone.
	version: Pins.version

	// digests are the index digests of the images the publish run pushed,
	// public and pulled anonymously, by the image's name: the last element of
	// its ko://go.ate.dev/substrate/cmd/<path> import path, as ko names it, so
	// credential-provider/kubernetes-secrets is kubernetes-secrets.
	// envoy-dataplane is built from a Dockerfile, not by ko, and is the one
	// image whose digest a local build does not reproduce.
	digests: Pins.digests

	// images are the full references, tag and digest, by name.
	images: {for NAME, DIGEST in digests {(NAME): "\(Substrate.registry)/\(NAME):\(version)@\(DIGEST)"}}

	// The grpcurl the Jobs that call the API run.
	atespaceSetup: image: "docker.io/fullstorydev/grpcurl:\(Pins.grpcurl.version)@\(Pins.grpcurl.digest)"

	// CloudNativePG 1.30.1's default, PostgreSQL 18.6, as keycloak's and quay's
	// are, pinned so an operator upgrade does not move the database to a new
	// major version by itself. The role Jobs, Substrate's and kagent's, run
	// psql from it.
	database: image: "ghcr.io/cloudnative-pg/postgresql:\(Pins.postgresql)"

	// The platform pool's worker image, which each claim's copy of the pool
	// takes with its spec.
	workerPool: spec: workerImage: images["ateworker-gvisor"]
}
