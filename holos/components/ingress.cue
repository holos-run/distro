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
	// principal is that mesh identity as an Istio AuthorizationPolicy names
	// it, which an ambient workload behind the gateway admits, as a Planboard
	// binding's login does (components/product-planboard).
	principal: "\(Istio.trustDomain)/ns/\(Self.namespace)/sa/\(serviceAccount)"
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

	// listenerSets is whether the Gateway admits ListenerSets, from its own
	// namespace alone, which only git writes: on a cluster with a binding,
	// whose bound claims add their listeners that way (claimed, below).
	// Elsewhere there is none to admit, and the gate keeps a cluster with no
	// binding byte-identical until after Ate Con (Second_Cluster Q6), as
	// AteGateway.#Rule's audience clause does.
	listenerSets: len(clusterBindings[Cluster.name]) > 0

	// #Claim is a claim's own zone on the gateway, <claim>.<domain>, where the
	// products bound to it have their hostnames, such as the Planboard's board
	// at planboard.<claim>.<domain>.
	//
	// The https listener's hostname would take such a name already: a Gateway
	// API wildcard is a suffix match over any number of labels, so *.<domain>
	// matches planboard.<claim>.<domain>, as the ate listener's
	// *.ate.<domain> matches a two-label actor's host. Its certificate would
	// not. An X.509 wildcard covers exactly one label (RFC 6125, 6.4.3), so the
	// wildcard *.<domain> is no good for planboard.<claim>.<domain>, and a
	// browser refuses it. Hence a certificate of the claim's own, and a
	// listener to serve it on, whose *.<claim>.<domain> is more specific than
	// https's *.<domain> and so wins for these hosts, as ate's does for its
	// own.
	//
	// The listener is in a ListenerSet rather than on the Gateway, so a claim
	// stays inside its own Application (components/project), as its atespace's
	// listener on the shim does (AteGateway.claimed). http's *.<domain> already
	// matches the zone's hosts on port 80 and redirects them to https.
	#Claim: {
		name:     string
		domain:   "\(name).\(Self.domain)"
		hostname: "*.\(domain)"

		// resource names the zone's objects: its ListenerSet and Certificate
		// in the Gateway's namespace, and its CertificateRequestPolicy, with
		// approver-policy: before it for the ClusterRole and ClusterRoleBinding
		// that let cert-manager use the policy (components/project).
		//
		// Not the names the claim's atespace has on the shim, project-<claim>
		// and <claim>-wildcard: the project component renders both in one map
		// keyed by kind and name, where the same name in two namespaces is one
		// object and the render fails. Nor project-<claim>-ingress: the policy
		// and its RBAC are cluster-scoped, and the atespace's of a claim named
		// a-ingress is project-a-ingress too, so claims a and a-ingress would
		// fight over one policy. An atespace's policy is project-<claim> and a
		// zone's ingress-project-<claim>, so the two never meet.
		resource: "ingress-project-\(name)"

		// certificate is the wildcard's spec, but for its dnsNames, which the
		// claim's own CertificateRequestPolicy lists (components/project).
		certificate: {
			secretName: "\(resource)-tls"
			privateKey: {
				algorithm: "ECDSA"
				size:      256
			}
			issuerRef: {
				group: "cert-manager.io"
				kind:  "ClusterIssuer"
				name:  PrivateCA.issuer
			}
		}

		// listener is the zone's HTTPS listener, named after the claim, which
		// admits only HTTPRoutes, and only from the claim's namespace, the
		// one place a product bound to it renders its routes. The selector is
		// by the namespace's name, as the ate and k8s listeners' are, which
		// the API server sets and no one can change.
		listener: {
			"name":     name
			"hostname": hostname
			port:       443
			protocol:   "HTTPS"
			tls: {
				mode: "Terminate"
				certificateRefs: [{kind: "Secret", name: certificate.secretName}]
			}
			allowedRoutes: {
				kinds: [{group: "gateway.networking.k8s.io", kind: "HTTPRoute"}]
				namespaces: {
					from: "Selector"
					selector: matchExpressions: [{
						key:      "kubernetes.io/metadata.name"
						operator: "In"
						values: [name]
					}]
				}
			}
		}

		// parentRef attaches an HTTPRoute in the claim's namespace to the
		// listener.
		parentRef: {
			group:       "gateway.networking.k8s.io"
			kind:        "ListenerSet"
			namespace:   Self.namespace
			name:        resource
			sectionName: listener.name
		}
	}

	// claimed are the zones of the claims with a binding on this cluster
	// (clusterBindings, collections.cue), one per claim however many products
	// it binds, so a second product shares the listener and the certificate. A
	// claim with no binding has no zone, since nothing would be served in it.
	claimed: [NAME=string]: #Claim & {name: NAME}
	claimed: {
		for B in clusterBindings[Cluster.name] {(B.project): {}}
	}
}
