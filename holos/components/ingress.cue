package holos

import "list"

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
		argocd:   _
		hello:    _
		keycloak: _
		quay:     _
		secrets:  _
	}

	// listeners are the Gateway's listener names. https terminates TLS for
	// every host; http answers every request with a redirect to https;
	// webhooks passes TLS through to the admission webhooks (webhooks.cue);
	// ate passes TLS through to the Substrate shim's Gateway (AteGateway);
	// k8s passes TLS through to holos-authenticator's Gateway
	// (HolosAuthenticator).
	listeners: {
		https:    "https"
		http:     "http"
		webhooks: "webhooks"
		ate:      "ate"
		k8s:      "k8s"
	}

	// webhooks is the listener the API server reaches every admission
	// webhook through: Cluster.webhooks.port on the gateway's address, for
	// every webhook hostname, routed on SNI by one TLSRoute per entry in
	// webhookServices (webhooks.cue) and passed through to the webhook's
	// Service. Talos host entries on the control plane point the
	// hostnames at address (talos.cue).
	webhooks: {
		port:     Cluster.webhooks.port
		hostname: "*.\(Cluster.webhooks.domain)"
		// namespaces are those of the webhook Services, the only namespaces
		// whose TLSRoutes the listener accepts.
		namespaces: list.SortStrings([for NS, _ in {for S in webhookServices {(S.namespace): _}} {NS}])
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
