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
// And the TLS passthrough listener the API server reaches the admission
// webhooks through, with a TLSRoute per webhook Service (webhooks.cue).
//
// Applied once istiod is running (it owns the istio GatewayClass) and the
// private CA issues.

let IG = IngressGateway

holos: spec: artifacts: [(#ResourcesArtifact & {
	resources: {
		// Not in ambient: the gateway is its own mesh proxy. Exempt from
		// cert-manager's validating webhook, because once webhooks fail
		// closed the wildcard Certificate's dry run would depend on the very
		// listener this component renders, and a commit that broke the
		// webhook path could not be rolled back through Argo CD. The label
		// must be live before enforcing is turned on.
		Namespace: (IG.namespace): metadata: labels: "cert-manager.io/disable-validation": "true"

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
					{
						name:     IG.listeners.webhooks
						hostname: IG.webhooks.hostname
						port:     IG.webhooks.port
						protocol: "TLS"
						// The gateway reads only the SNI and forwards the
						// connection; the webhook's Pods terminate TLS with
						// their own serving certificates.
						tls: mode: "Passthrough"
						// Only the webhook TLSRoutes below, from the webhook
						// Services' namespaces. A TLSRoute in its backend's
						// namespace needs no ReferenceGrant.
						allowedRoutes: {
							kinds: [{group: "gateway.networking.k8s.io", kind: "TLSRoute"}]
							namespaces: {
								from: "Selector"
								selector: matchExpressions: [{
									key:      "kubernetes.io/metadata.name"
									operator: "In"
									values:   IG.webhooks.namespaces
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

		// The admission webhooks: one TLSRoute per webhook Service, in the
		// Service's namespace, matching its hostname (Cluster.webhooks.hosts)
		// as SNI on the webhooks listener and forwarding to the Service's
		// port. Rendered here, from the registry, so the listener and its
		// routes change together.
		for K, S in webhookServices {
			TLSRoute: (K): {
				metadata: namespace: S.namespace
				spec: {
					parentRefs: [{
						group:       IG.parentRef.group
						kind:        IG.parentRef.kind
						namespace:   IG.namespace
						name:        IG.name
						sectionName: IG.listeners.webhooks
					}]
					hostnames: [Cluster.webhooks.hosts[K]]
					rules: [{
						backendRefs: [{
							name: S.name
							port: S.port
						}]
					}]
				}
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
