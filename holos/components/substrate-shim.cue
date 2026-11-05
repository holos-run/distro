package holos

import "list"

// AteGateway is the Substrate shim's Gateway, which the substrate-shim
// component renders: the one client of Substrate's router, which every actor
// is reached through at https://<actor>.<atespace>.ate.<domain>. It holds
// the policy that would break other clients on the shared ingress Gateway,
// since a RequestAuthentication applies to every request its gateway sees,
// and a bearer JWT from another issuer, such as a Quay registry token, would
// get 401 there. So it is a Gateway of its own, with no address: the ingress
// Gateway's ate listener passes every *.ate.<domain> connection through to
// its Service, untouched, on SNI.
AteGateway: {
	let Self = AteGateway

	// namespace holds the Gateway, its listener certificates, its policy and
	// the Deployment istiod creates for it. Not in ambient, as istio-ingress
	// is not: the gateway is its own proxy, and the router it dials is
	// outside the mesh.
	namespace: "substrate-shim"
	// name is the Gateway's. istiod names the Deployment and the ClusterIP
	// Service it creates <name>-istio.
	name:    "ate"
	service: "\(name)-istio"
	// serviceAccount is the one the Gateway's
	// gateway.istio.io/service-account annotation names and istiod creates.
	// The gateway's pod certificate from Substrate's pod identity signer is
	// issued for it, and spiffeID is the identity that certificate carries:
	// the substrate component puts it on the router's allowed list, from
	// here, so the two cannot disagree.
	serviceAccount: "ate-gateway"
	spiffeID:       "spiffe://\(Istio.trustDomain)/ns/\(namespace)/sa/\(serviceAccount)"
	// parameters is the ConfigMap the Gateway's infrastructure.parametersRef
	// names, whose deployment key adds the pod certificate to the gateway.
	parameters: "ate-gateway"

	// domain is the zone under the cluster's ingress domain every actor's
	// hostname is in, <actor>.<atespace>.<domain> (interview Q9): two labels,
	// the router's atespace slash actor. With the ingress domain's default,
	// that is <actor>.<atespace>.ate.<cluster>.<privateDomain> (the
	// Cluster_Qualified_Hostnames planning project). The private zone's
	// *.<ingressDomain> record already resolves it to the ingress Gateway's
	// address.
	domain:   "ate.\(IngressGateway.domain)"
	wildcard: "*.\(domain)"

	// #Atespace is one Substrate atespace the shim serves: a listener with a
	// wildcard certificate *.<atespace>.<domain>, an HTTPRoute to the router,
	// and an AuthorizationPolicy rule admitting a Keycloak ID token whose
	// groups claim holds one of groups. Any other host under domain has no
	// listener, so the gateway refuses it. The fields here are what the
	// Gateway's atespaces and a claim's have in common, so the two cannot
	// come to differ.
	#Atespace: {
		name:     string
		hostname: "*.\(name).\(Self.domain)"
		// groups are the full group paths (Keycloak.groupsClaim) that may
		// reach the atespace's actors.
		groups: [...string]

		// certificate is the wildcard's spec, but for what its entry in
		// PrivateCA.requesters adds.
		certificate: {
			secretName: "\(name)-wildcard-tls"
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

		// listener is the atespace's HTTPS listener, named after it, which
		// admits only HTTPRoutes from the router's namespace.
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
						values: [Substrate.namespace]
					}]
				}
			}
		}

		// rule is the atespace's AuthorizationPolicy rule: its hosts, with or
		// without the port, a verified token from the realm, and one of its
		// groups in the token's groups claim.
		rule: {
			from: [{source: requestPrincipals: ["\(Keycloak.issuer)/*"]}]
			to: [{operation: hosts: [hostname, "\(hostname):443"]}]
			when: [{
				key:    "request.auth.claims[\(Keycloak.groupsClaim)]"
				values: list.SortStrings(groups)
			}]
		}
	}

	// atespaces are the platform's, each a listener on the Gateway itself.
	atespaces: [NAME=string]: #Atespace & {name: NAME}
	atespaces: {
		// demo is the atespace README.md, Substrate, creates by hand, with
		// the echo and other actors.
		demo: groups: [Keycloak.groups.owners.path]
		// kagent's agents, in the atespace kagent creates for itself.
		(Kagent.atespace): groups: [Keycloak.groups.owners.path]
	}

	// claimed are the atespaces of the claims this cluster takes, one of each
	// claim's name. components/project renders each, as a ListenerSet on the
	// Gateway rather than a listener of its own, so a claim stays inside its
	// own Application: between Applications that already exist, a broken one
	// holds back no other (interview Q66), though a root sync, which walks
	// the waves, waits on it as on any component. The claim's owner group may
	// reach its actors, and so may the platform's owners, as they may
	// everywhere else.
	claimed: [NAME=string]: #Atespace & {name: NAME}
	claimed: {
		for NAME, _ in clusterProjects[Cluster.name] {
			(NAME): groups: [
				(#ProjectRoleGroupPath & {project: NAME, role: "owner"}).claim,
				Keycloak.groups.owners.path,
			]
		}
	}
}
