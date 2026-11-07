package holos

// OAuth2Proxy pins oauth2-proxy, the login in front of every browser-facing
// service the platform renders behind Keycloak: kagent's UI, through the
// kagent chart's subchart (components/kagent), and each Planboard binding's
// board, in plain CUE (components/product-planboard), since a product's
// component renders only its two buckets and no chart. Both read the pin here,
// so they cannot drift apart. To bump, move tag to the new release and its
// index digest, and re-read the subchart's templates against the board's
// Deployment.
OAuth2Proxy: {
	// repository is the image's, the subchart's default registry and
	// repository, which kagent's values leave as they are.
	repository: "quay.io/oauth2-proxy/oauth2-proxy"
	// tag is the release, with the index digest it pointed to when pinned.
	// The subchart puts a tag with an @digest after the colon as it is.
	tag:   "v7.15.6@sha256:c3415e8660af553f5e18f5d90db050614c02493c0ac6260ac59442f6d9b12048"
	image: "\(repository):\(tag)"
}
