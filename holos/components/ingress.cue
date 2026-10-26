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
	// annotation gives. The gateway's mesh identity is rendered from it, as
	// substrate-shim renders the identity the Substrate router allows.
	serviceAccount: "ingress-gateway"
	spiffeID:       "spiffe://\(Istio.trustDomain)/ns/\(namespace)/sa/\(serviceAccount)"
	// parameters is the ConfigMap the Gateway's infrastructure.parametersRef
	// names: istiod merges its deployment key into the Deployment it
	// generates.
	parameters: "ingress-gateway"

	// address is the gateway's LoadBalancer address, pinned in the cluster's
	// block (clusters.cue), where the private zone's wildcard points.
	address: Cluster.loadBalancer.gateway

	// domain is the private zone. Every gateway hostname is
	// <service>.<domain> (interview Q40), one label under the zone, so the
	// listener's one wildcard certificate covers them all. Unlike webhook
	// hostnames, gateway hostnames carry no cluster name.
	domain:   Cluster.site.privateDomain
	wildcard: "*.\(domain)"

	// hosts maps each service the gateway routes to its hostname.
	hosts: [NAME=string]: "\(NAME).\(domain)"
	hosts: {
		argocd: _
		hello:  _
	}

	// listeners are the Gateway's listener names. https terminates TLS for
	// every host; http answers every request with a redirect to https.
	listeners: {
		https: "https"
		http:  "http"
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
