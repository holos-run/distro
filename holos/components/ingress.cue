package holos

// IngressGateway is the cluster's one ingress Gateway, which the
// ingress-gateway component renders: every platform service with a hostname
// is an HTTPRoute on its HTTPS listener. A component that adds a route names
// its host in hosts and attaches with parentRef.
IngressGateway: {
	let Self = IngressGateway

	// namespace holds the Gateway, its listener certificate and the
	// Deployment istiod creates for it. It is not in ambient: the gateway is
	// its own mesh proxy and speaks HBONE to ambient workloads itself.
	namespace: "istio-ingress"
	// name is the Gateway's. istiod names the Deployment and the
	// LoadBalancer Service it creates <name>-istio.
	name: "ingress"
	// serviceAccount is the gateway Deployment's ServiceAccount, which istiod
	// creates under the name the Gateway's gateway.istio.io/service-account
	// annotation gives, and the gateway's mesh identity is named after. The
	// Substrate router does not admit it: only the shim's gateway
	// (AteGateway), behind the ate listener, reaches the router.
	serviceAccount: "ingress-gateway"
	// parameters is the ConfigMap the Gateway's infrastructure.parametersRef
	// names: istiod merges its deployment key into the Deployment it
	// generates.
	parameters: "ingress-gateway"

	// address is the gateway's LoadBalancer address, reserved in the cluster's
	// block (clusters.cue), where the private zone's *.<domain> record points.
	address: Cluster.loadBalancer.gateway

	// domain is the cluster's ingress domain, Cluster.ingressDomain:
	// <cluster>.<privateDomain> unless the cluster sets it (clusters.cue).
	// Every gateway hostname is <service>.<domain>,
	// <service>.<cluster>.<privateDomain> (the Cluster_Qualified_Hostnames
	// planning project), one label under the domain, so the listener's one
	// wildcard certificate covers them all. Email addresses are not
	// hostnames: they stay under the site's zone, Cluster.site.privateDomain.
	domain:   Cluster.ingressDomain
	wildcard: "*.\(domain)"

	// hosts maps each service the gateway routes to its hostname.
	hosts: [NAME=string]: "\(NAME).\(domain)"
	hosts: {
		argocd:   _
		hello:    _
		kagent:   _
		keycloak: _
		quay:     _
		secrets:  _
		toolhive: _
	}

	// listeners are the Gateway's listener names. https terminates TLS for
	// every host; http answers every request with a redirect to https; ate
	// passes TLS through to the Substrate shim's Gateway (AteGateway), and the
	// Gateway has it only on a cluster that names substrate-shim; k8s passes
	// TLS through to holos-authenticator's Gateway (PlatformAuthenticator).
	listeners: {
		https: "https"
		http:  "http"
		ate:   "ate"
		k8s:   "k8s"
	}

	// parentRef attaches an HTTPRoute to the HTTPS listener.
	parentRef: {
		group:       "gateway.networking.k8s.io"
		kind:        "Gateway"
		namespace:   Self.namespace
		name:        Self.name
		sectionName: Self.listeners.https
	}
}
