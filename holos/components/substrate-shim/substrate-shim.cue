package holos

import (
	"encoding/yaml"
	"list"
)

// substrate-shim is the Istio shim in front of Substrate's router (overview
// §5): the only way a person reaches an actor, at
// https://<actor>.<atespace>.ate.<domain>, with a Keycloak ID token. It is
// plain Istio on a Gateway of its own (AteGateway, in
// components/substrate-shim.cue), with no address: the ingress Gateway's
// ate listener passes every *.ate.<domain> connection through to it on SNI,
// so its RequestAuthentication sees only the shim's requests and cannot
// refuse another issuer's bearer token meant for a platform service. A
// request takes this path:
//
//	client
//	  -> 10.20.0.30:443, the ingress Gateway's ate listener (TLS passthrough)
//	  -> this namespace's TLSRoute, to the shim Gateway's ClusterIP Service
//	  -> the shim Gateway's listener for the atespace, which terminates TLS
//	     with the atespace's wildcard certificate
//	  -> RequestAuthentication: a bearer token, if any, must be a Keycloak ID
//	     token for the kubectl client; Envoy drops it once verified
//	  -> AuthorizationPolicy: the host's atespace must have a rule, the
//	     request a token, and the token's groups claim one of the
//	     atespace's groups; everything else is 403
//	  -> TrafficExtension: Lua sets ate-target-actor to <atespace>/<actor>
//	     from the host, replacing any value the client sent
//	  -> the atespace's HTTPRoute in ate-system, to the router's Service
//	  -> mutual TLS to the router (DestinationRule), with the gateway's pod
//	     certificate from Substrate's pod identity signer, whose SPIFFE ID
//	     the router's allowed list holds (components/substrate)
//	  -> the router, which strips ate-target-actor and forwards to the actor
//
// Every tenant boundary is in this policy, since the gateway is the router's
// only client besides kagent's controller. The per-atespace listeners admit
// routes only from ate-system, and no ReferenceGrant into ate-system exists,
// so no other route can reach the router through this Gateway.
//
// It comes after substrate in the registry: the gateway's pods project a
// certificate from the pod identity signer, so they start only once
// Substrate's pod certificate controller and its key pools are up, and its
// HTTPRoutes are in substrate's namespace.

let AG = AteGateway
let IG = IngressGateway
let S = Substrate

// GatewayRef is the shim Gateway, as the policies' targetRefs name it, so
// that each applies to this Gateway alone.
let GatewayRef = {
	group: "gateway.networking.k8s.io"
	kind:  "Gateway"
	name:  AG.name
}

// RouterHost is the router Service's name as Istio's registry knows it. A
// DestinationRule's host with dots is taken as it is, not expanded, so it is
// the fully qualified name.
let RouterHost = "\(S.router.host).\(Cluster.network.dnsDomain)"

// Client is the gateway's client certificate for the router: a pod
// certificate from the pod identity signer, issued for the gateway's
// ServiceAccount, so its SPIFFE ID is AteGateway.spiffeID. The
// DestinationRule wants the key and the chain as two files, so it is
// projected with keyPath and certificateChainPath rather than one credential
// bundle. Every replica gets its own key and certificate, which the kubelet
// renews before it expires, by default after 24 hours; Istio watches the
// files and picks the new pair up (README.md, The Substrate shim, Rotation).
let Client = {
	volume: "router-client"
	dir:    "/var/run/ate/router-client"
	key:    "key.pem"
	chain:  "cert-chain.pem"
}

// RouterCA is the trust bundle the router's serving certificate is checked
// against: the servicedns signer's, which issues it, projected from the
// ClusterTrustBundles the pod certificate controller publishes, the live
// ones, as Substrate's own pods project it.
let RouterCA = {
	volume: "router-ca"
	dir:    "/var/run/ate/router-ca"
	file:   "ca.pem"
}

// Lua is the TrafficExtension's filter. It reads the host, drops a port,
// takes the two labels in front of .<domain> as actor and atespace, and
// replaces ate-target-actor with <atespace>/<actor>, which removes every
// value the client sent and sets one. A host of any other shape is answered
// with 400 rather than routed with a header the router would reject or
// misread. Unphased, it runs after the AuthorizationPolicy, so a request
// that is refused never gets the header.
let Lua = """
	-- <actor>.<atespace>\(Suffix) to ate-target-actor: <atespace>/<actor>.
	local suffix = "\(Suffix)"

	function envoy_on_request(request_handle)
	  local headers = request_handle:headers()
	  local host = string.lower(headers:get(":authority") or "")
	  host = string.gsub(host, ":%d+$", "")
	  local actor, atespace
	  if #host > #suffix and string.sub(host, -#suffix) == suffix then
	    actor, atespace = string.match(string.sub(host, 1, -#suffix - 1), "^([a-z0-9-]+)%.([a-z0-9-]+)$")
	  end
	  if actor == nil then
	    request_handle:respond({[":status"] = "400"}, "host is not <actor>.<atespace>\(Suffix)\\n")
	    return
	  end
	  headers:replace("ate-target-actor", atespace .. "/" .. actor)
	end
	"""
let Suffix = ".\(AG.domain)"

holos: spec: artifacts: [(#ResourcesArtifact & {
	resources: {
		// Not in ambient: the gateway is its own proxy, and the router it
		// dials is outside the mesh. Not exempt from cert-manager's webhook,
		// unlike istio-ingress: the webhook's path is the ingress Gateway's
		// webhooks listener, which this component does not render, so a
		// commit here cannot break the dry run of its own Certificates.
		Namespace: (AG.namespace): {}

		// One wildcard per atespace, from the private CA, ECDSA P-256 as the
		// ingress Gateway's, renewed by cert-manager, which istiod hands to
		// the gateway as it changes.
		for A in AG.atespaces {
			Certificate: "\(A.name)-wildcard": {
				metadata: namespace: AG.namespace
				spec: {
					secretName: "\(A.name)-wildcard-tls"
					dnsNames: [A.hostname]
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
		}

		// The gateway Deployment's customization, which istiod merges into
		// the Deployment it generates (a strategic merge patch): two
		// replicas, preferably on two nodes, as the ingress Gateway's, and
		// the client certificate and the router's trust bundle in the proxy.
		ConfigMap: (AG.parameters): {
			metadata: namespace: AG.namespace
			data: deployment: yaml.Marshal({
				spec: {
					replicas: 2
					template: spec: {
						topologySpreadConstraints: [{
							maxSkew:           1
							topologyKey:       "kubernetes.io/hostname"
							whenUnsatisfiable: "ScheduleAnyway"
							labelSelector: matchLabels: "gateway.networking.k8s.io/gateway-name": AG.name
						}]
						containers: [{
							name: "istio-proxy"
							volumeMounts: [
								{name: Client.volume, mountPath: Client.dir, readOnly: true},
								{name: RouterCA.volume, mountPath: RouterCA.dir, readOnly: true},
							]
						}]
						volumes: [
							{
								name: Client.volume
								projected: sources: [{
									podCertificate: {
										signerName:           S.signers.podIdentity
										keyType:              "ECDSAP256"
										keyPath:              Client.key
										certificateChainPath: Client.chain
									}
								}]
							},
							{
								name: RouterCA.volume
								projected: sources: [{
									clusterTrustBundle: {
										signerName: S.signers.serviceDNS
										labelSelector: matchLabels: "podcert.ate.dev/canarying": "live"
										path: RouterCA.file
									}
								}]
							},
						]
					}
				}
			})
		}

		Gateway: (AG.name): {
			metadata: {
				namespace: AG.namespace
				annotations: {
					// The ServiceAccount istiod creates for the gateway and
					// runs it as, whose pod certificate the router admits.
					"gateway.istio.io/service-account": AG.serviceAccount
					// No address of its own: it is reached only through the
					// ingress Gateway's ate listener.
					"networking.istio.io/service-type": "ClusterIP"
				}
			}
			spec: {
				gatewayClassName: "istio"
				infrastructure: parametersRef: {
					group: ""
					kind:  "ConfigMap"
					name:  AG.parameters
				}
				// Claimed atespaces add their listeners as ListenerSets,
				// from this namespace alone, which only git writes.
				allowedListeners: namespaces: from: "Same"
				// One HTTPS listener per atespace, named after it, which
				// admits only HTTPRoutes from the router's namespace.
				listeners: [for A in AG.atespaces {
					name:     A.name
					hostname: A.hostname
					port:     443
					protocol: "HTTPS"
					tls: {
						mode: "Terminate"
						certificateRefs: [{kind: "Secret", name: "\(A.name)-wildcard-tls"}]
					}
					allowedRoutes: {
						kinds: [{group: "gateway.networking.k8s.io", kind: "HTTPRoute"}]
						namespaces: {
							from: "Selector"
							selector: matchExpressions: [{
								key:      "kubernetes.io/metadata.name"
								operator: "In"
								values: [S.namespace]
							}]
						}
					}
				}]
			}
		}

		// The ingress Gateway's ate listener passes *.<domain> through to
		// the shim Gateway's Service. In this namespace, the only one the
		// listener admits TLSRoutes from, and the Service's, so no
		// ReferenceGrant. Rendered here rather than by ingress-gateway, which
		// comes before this namespace exists.
		TLSRoute: (AG.name): {
			metadata: namespace: AG.namespace
			spec: {
				parentRefs: [{
					group:       IG.parentRef.group
					kind:        IG.parentRef.kind
					namespace:   IG.namespace
					name:        IG.name
					sectionName: IG.listeners.ate
				}]
				hostnames: [AG.wildcard]
				rules: [{backendRefs: [{name: AG.service, port: 443}]}]
			}
		}

		// One route per atespace to the router, in the router's namespace,
		// so it needs no ReferenceGrant, on the atespace's listener.
		for A in AG.atespaces {
			HTTPRoute: "\(AG.name)-\(A.name)": {
				metadata: namespace: S.namespace
				spec: {
					parentRefs: [GatewayRef & {
						namespace:   AG.namespace
						sectionName: A.name
					}]
					rules: [{backendRefs: [{name: S.router.name, port: S.router.port}]}]
				}
			}
		}

		// Mutual TLS to the router: the gateway's pod certificate as the
		// client's, the router's serving certificate checked against the
		// servicedns bundle and for the Service's name, which is sent as
		// SNI. Exported to this namespace alone, where the gateway is the
		// only proxy, so nothing else dials the router with it.
		DestinationRule: (S.router.name): {
			metadata: namespace: AG.namespace
			spec: {
				host: RouterHost
				exportTo: ["."]
				trafficPolicy: tls: {
					mode:              "MUTUAL"
					clientCertificate: "\(Client.dir)/\(Client.chain)"
					privateKey:        "\(Client.dir)/\(Client.key)"
					caCertificates:    "\(RouterCA.dir)/\(RouterCA.file)"
					sni:               S.router.host
					subjectAltNames: [S.router.host]
				}
			}
		}

		// A bearer token, if the request carries one, must be a Keycloak ID
		// token from the platform's realm for the kubectl client (ADR 0002),
		// the token kubectl oidc-login prints; anything else is 401. A
		// request without one passes here and is refused by the
		// AuthorizationPolicy. Only the Authorization header is read, not
		// Istio's default access_token query parameter, so a token never
		// rides in a URL. Envoy removes the token once it is verified, so an
		// actor never holds one it could replay.
		RequestAuthentication: keycloak: {
			metadata: namespace: AG.namespace
			spec: {
				targetRefs: [GatewayRef]
				jwtRules: [{
					issuer: Keycloak.issuer
					audiences: [Keycloak.clients.kubectl]
					fromHeaders: [{name: "Authorization", prefix: "Bearer "}]
					forwardOriginalToken: false
				}]
			}
		}

		// One rule per atespace: its hosts, with or without the port, a
		// verified token from the realm, and one of the atespace's groups in
		// the token's groups claim. A host with no rule, and a request
		// matching no rule, is 403.
		AuthorizationPolicy: (AG.name): {
			metadata: namespace: AG.namespace
			spec: {
				targetRefs: [GatewayRef]
				action: "ALLOW"
				rules: [for A in AG.atespaces {
					from: [{source: requestPrincipals: ["\(Keycloak.issuer)/*"]}]
					to: [{operation: hosts: [A.hostname, "\(A.hostname):443"]}]
					when: [{
						key:    "request.auth.claims[\(Keycloak.groupsClaim)]"
						values: list.SortStrings(A.groups)
					}]
				}]
			}
		}

		// ate-target-actor from the host (Lua, above). No phase, so istiod
		// puts it after the RBAC filter.
		TrafficExtension: "ate-target-actor": {
			metadata: namespace: AG.namespace
			spec: {
				targetRefs: [GatewayRef]
				lua: inlineCode: Lua
			}
		}
	}
}).artifact]
