package holos

// Kagent's names that need the ingress Gateway and Keycloak, which only
// component instances load: its public URL and its Keycloak client. The
// pins and the names Substrate reads are in kagent.cue at the platform root.
Kagent: {
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
}
