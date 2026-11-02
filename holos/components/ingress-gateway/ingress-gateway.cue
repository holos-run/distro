package holos

import "encoding/yaml"

// The ingress Gateway (IngressGateway, components/ingress.cue): one Gateway
// of class istio on the private domain, for every platform service, each an
// HTTPRoute on its HTTPS listener. istiod deploys the gateway for it, a
// Deployment, a LoadBalancer Service at the reserved address and a
// ServiceAccount, and owns them; none is rendered here.
//
// Also the HTTPRoutes of components installed before the Gateway API CRDs,
// so that each of those can still be applied by hand at bootstrap: Argo CD's.
// And two TLS passthrough listeners: the one the Substrate shim's hosts pass
// through to its own Gateway (AteGateway), whose TLSRoute substrate-shim
// renders, and the one the Kubernetes API's host passes through to
// holos-authenticator's Gateway (HolosAuthenticator), whose TLSRoute
// holos-authenticator renders.
//
// Applied once istiod is running (it owns the istio GatewayClass) and the
// private CA issues.

let IG = IngressGateway

holos: spec: artifacts: [(#ResourcesArtifact & {
	resources: {
		// Not in ambient: the gateway is its own mesh proxy.
		Namespace: (IG.namespace): _

		// The listener's certificate: the zone's wildcard, from the private
		// CA, renewed by cert-manager, which istiod hands to the gateway as it
		// changes. Its name is its entry's in PrivateCA.requesters
		// (components/private-ca.cue).
		Certificate: wildcard: {
			metadata: namespace: IG.namespace
			spec: {
				PrivateCA.requesters[IG.namespace].wildcard
				secretName: "wildcard-tls"
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
		}

		// The gateway Deployment's customization. istiod merges the
		// deployment key into the Deployment it generates (a strategic merge
		// patch). Two replicas, preferably on two nodes, so draining a worker
		// does not drop the gateway.
		ConfigMap: (IG.parameters): {
			metadata: namespace: IG.namespace
			data: deployment: yaml.Marshal({
				spec: {
					replicas: 2
					template: spec: topologySpreadConstraints: [{
						maxSkew:           1
						topologyKey:       "kubernetes.io/hostname"
						whenUnsatisfiable: "ScheduleAnyway"
						labelSelector: matchLabels: "gateway.networking.k8s.io/gateway-name": IG.name
					}]
				}
			})
		}

		Gateway: (IG.name): {
			metadata: {
				namespace: IG.namespace
				// The ServiceAccount istiod creates for the gateway and runs
				// it as, the name its mesh identity comes from. Without it the
				// name would be <name>-istio, a side effect of the class.
				annotations: "gateway.istio.io/service-account": IG.serviceAccount
			}
			spec: {
				gatewayClassName: "istio"
				// istiod sets it as the Service's loadBalancerIP, which
				// Cilium's LB IPAM honors from the cluster's pool.
				addresses: [{type: "IPAddress", value: IG.address}]
				infrastructure: parametersRef: {
					group: ""
					kind:  "ConfigMap"
					name:  IG.parameters
				}
				listeners: [
					{
						name:     IG.listeners.https
						hostname: IG.wildcard
						port:     443
						protocol: "HTTPS"
						tls: {
							mode: "Terminate"
							certificateRefs: [{kind: "Secret", name: Certificate.wildcard.spec.secretName}]
						}
						// Every namespace's routes may attach.
						allowedRoutes: namespaces: from: "All"
					},
					{
						name:     IG.listeners.http
						hostname: IG.wildcard
						port:     80
						protocol: "HTTP"
						// Only the redirect below.
						allowedRoutes: namespaces: from: "Same"
					},
					{
						name:     IG.listeners.ate
						hostname: AteGateway.wildcard
						port:     443
						protocol: "TLS"
						// The Substrate shim's hosts,
						// <actor>.<atespace>.ate.<domain>, pass through to the
						// shim's own Gateway, which terminates TLS and holds
						// the policy. Envoy matches SNI to the most specific
						// name, so they come here rather than to https's
						// *.<domain>.
						tls: mode: "Passthrough"
						// Only TLSRoutes, and only from the shim's namespace,
						// where the one route to its Gateway's Service is.
						allowedRoutes: {
							kinds: [{group: "gateway.networking.k8s.io", kind: "TLSRoute"}]
							namespaces: {
								from: "Selector"
								selector: matchExpressions: [{
									key:      "kubernetes.io/metadata.name"
									operator: "In"
									values: [AteGateway.namespace]
								}]
							}
						}
					},
					{
						name:     IG.listeners.k8s
						hostname: HolosAuthenticator.host
						port:     443
						protocol: "TLS"
						// The Kubernetes API, k8s.<domain>, passes through to
						// holos-authenticator's own Gateway, which terminates
						// TLS, asks the authenticator about every request and
						// forwards it to the API server as an impersonation.
						// An exact hostname, so it comes here rather than to
						// https's *.<domain>. The impersonator's token and the
						// Lua that writes Impersonate-Group stay off this
						// Gateway.
						tls: mode: "Passthrough"
						// Only TLSRoutes, and only from the authenticator's
						// namespace, where the one route to its Gateway's
						// Service is.
						allowedRoutes: {
							kinds: [{group: "gateway.networking.k8s.io", kind: "TLSRoute"}]
							namespaces: {
								from: "Selector"
								selector: matchExpressions: [{
									key:      "kubernetes.io/metadata.name"
									operator: "In"
									values: [HolosAuthenticator.namespace]
								}]
							}
						}
					},
				]
			}
		}

		// Every plain HTTP request is redirected to the same URL over HTTPS.
		HTTPRoute: "https-redirect": {
			metadata: namespace: IG.namespace
			spec: {
				parentRefs: [{name: IG.name, sectionName: IG.listeners.http}]
				rules: [{
					filters: [{
						type: "RequestRedirect"
						requestRedirect: {
							scheme:     "https"
							statusCode: 301
						}
					}]
				}]
			}
		}

		// Argo CD's UI and API. The gateway terminates TLS and the server
		// serves plain HTTP behind it (server.insecure, components/argocd).
		// The argocd CLI goes through it with --grpc-web.
		HTTPRoute: argocd: {
			metadata: namespace: ArgoCD.namespace
			spec: {
				parentRefs: [IG.parentRef]
				hostnames: [IG.hosts.argocd]
				rules: [{
					backendRefs: [{
						name: "argocd-server"
						port: 80
					}]
				}]
			}
		}
	}
}).artifact]
