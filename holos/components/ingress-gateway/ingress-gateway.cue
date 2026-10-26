package holos

import "encoding/yaml"

// The ingress Gateway (IngressGateway, components/ingress.cue): one Gateway
// of class istio on the private domain, for every platform service, each an
// HTTPRoute on its HTTPS listener. istiod deploys the gateway for it, a
// Deployment, a LoadBalancer Service at the pinned address and a
// ServiceAccount, and owns them; none is rendered here.
//
// Also the HTTPRoutes of components installed before the Gateway API CRDs,
// so that each of those can still be applied by hand at bootstrap: Argo CD's.
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
		// changes.
		Certificate: wildcard: {
			metadata: namespace: IG.namespace
			spec: {
				secretName: "wildcard-tls"
				dnsNames: [IG.wildcard]
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
		// patch); substrate-shim adds the podCertificate volume here. Two
		// replicas, preferably on two nodes, so draining a worker does not
		// drop the gateway.
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
