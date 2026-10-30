package holos

import (
	"encoding/yaml"
	"list"
)

// holos-authenticator puts the Kubernetes API server at https://k8s.<domain>
// behind a Keycloak login (overview §4, interview Q60 to Q63): a person's
// kubeconfig carries the ID token kubelogin prints for the kubectl client,
// and the API server sees the request as an impersonation of them,
// oidc:<username> with their groups by full path, so Kubernetes RBAC does the
// rest. HolosAuthenticator (components/holos-authenticator.cue) holds the
// release, the names, and the users and groups that may be impersonated.
//
// holos-authenticator 0.21.0 is an Envoy external authorization server, gRPC
// on 9000, and a controller that reads Backend resources in its own
// namespace. It is not a proxy: Envoy asks it about each request, and it
// verifies the bearer token as an ID token (signature against the realm's
// JWKS, iss, aud the Backend's client ID, exp, nbf) and answers OK with three
// headers to set, or 401 or 403. A request takes this path:
//
//	kubectl
//	  -> 10.20.0.30:443, the ingress Gateway's k8s listener (TLS passthrough)
//	  -> this namespace's TLSRoute, to this component's Gateway's ClusterIP
//	     Service
//	  -> the Gateway's listener for k8s.<domain>, which terminates TLS
//	  -> ext_authz (the CUSTOM AuthorizationPolicy) to the manager, which
//	     denies a request carrying any Impersonate-* or x-impersonate-groups
//	     header, verifies the token and overwrites Impersonate-User,
//	     x-impersonate-groups (the forwarded groups, joined by |) and
//	     Authorization (the impersonator's token)
//	  -> TrafficExtension: Lua splits x-impersonate-groups into one
//	     Impersonate-Group each, and removes it
//	  -> the HTTPRoute to the kubernetes Service in default, with TLS to the
//	     API server (DestinationRule)
//	  -> the API server, which authenticates the impersonator, checks that it
//	     may impersonate that user and each group, and authorizes the request
//	     as the impersonated user
//
// The Gateway is its own, as the Substrate shim's is, so the impersonator's
// token and the Lua never touch the ingress Gateway: a client cannot have an
// x-impersonate-groups header turned into Impersonate-Group on its way to any
// other backend.
//
// It comes after keycloak-realm in the registry: the Backend verifies tokens
// against the realm's issuer, and it impersonates the realm's users and
// groups. It needs istiod's extension provider and ingress-gateway's k8s
// listener, both earlier, and the Gateway API CRDs and the private-ca
// ClusterIssuer and ConfigMap. The manager registers no admission webhook.

let HA = HolosAuthenticator
let GW = HA.gateway
let IG = IngressGateway
let NS = HA.namespace
let Name = HA.name
let Labels = {"app.kubernetes.io/name": Name}

// The vendored release (vendor/<version>/crd): the Backend CRD from aavis-ops
// at tag holos-authenticator-v0.21.0, config/crd/holos-authenticator/bases,
// unmodified, which is the same file at tag v0.21.0:
//
//	crd/authenticator.holos.run_backends.yaml   sha256:ddb4c2f46808e9090cc5c94f685deca7b27f12b651a025ada399dc54cf10a407
//
// The manager's Deployment and RBAC are written here rather than vendored:
// aavis-ops renders them from its own CUE, not from a release manifest.
let Vendor = "vendor/\(HA.version)"

// GatewayRef is this component's Gateway, as the policies' targetRefs name
// it, so that each applies to this Gateway alone.
let GatewayRef = {
	group: "gateway.networking.k8s.io"
	kind:  "Gateway"
	name:  GW.name
}

// APIServer is the kubernetes Service in default, the API server as pods
// reach it, and host its name in Istio's registry. Its endpoint is the
// control plane's address on 6443, off the pod network (ADR 0001), which
// pods reach as they always do.
let APIServer = {
	namespace: "default"
	name:      "kubernetes"
	port:      443
	host:      "\(name).\(namespace).svc.\(Cluster.network.dnsDomain)"
	// sni is the name the API server's serving certificate is checked for,
	// one of the names Talos issues it for.
	sni: "\(name).\(namespace).svc"
}

// GroupsHeader is the header the manager writes the forwarded groups into,
// joined by Separator, its --impersonate-groups-header default and the
// Backend's groupsHeaderSeparator default. Envoy's ext_authz drops an
// appended header the request did not carry, so the manager overwrites one
// header and the Lua below splits it.
let GroupsHeader = "x-impersonate-groups"
let Separator = "|"

// Lua is the TrafficExtension's filter, the one in aavis-ops' buildplan.cue
// with the header and the separator from here. It removes GroupsHeader and
// adds one Impersonate-Group per group in it, trimmed. The manager has
// already refused a request that carried the header, and refuses a group
// holding the separator or leading or trailing space, so what the Lua reads
// is the manager's own value. Unphased, it runs after ext_authz (README.md,
// holos-authenticator).
let Lua = """
	-- \(GroupsHeader): g1\(Separator)g2 to Impersonate-Group: g1, Impersonate-Group: g2.
	function envoy_on_request(handle)
	  local sep = "\(Separator)"
	  local class = sep:gsub("%W", "%%%0")
	  local joined = handle:headers():get("\(GroupsHeader)")
	  if joined == nil or joined == "" then
	    return
	  end
	  handle:headers():remove("\(GroupsHeader)")
	  for group in string.gmatch(joined, "([^" .. class .. "]+)") do
	    local g = group:gsub("^%s*(.-)%s*$", "%1")
	    if g ~= "" then
	      handle:headers():add("Impersonate-Group", g)
	    end
	  end
	end
	"""

// CAMount is where the manager mounts the private root, which it adds to
// Go's system trust (Deployment, below).
let CAMount = "/etc/ssl/private-ca"

holos: spec: artifacts: [(#FileArtifact & {
	files: ["\(Vendor)/crd/authenticator.holos.run_backends.yaml"]

	// Argo CD does not prune the CRD: deleting it deletes every Backend, and
	// kubectl through k8s.<domain> with them.
	patches: [{
		target: {
			group: "apiextensions.k8s.io"
			kind:  "CustomResourceDefinition"
		}
		patch: yaml.Marshal({
			apiVersion: "apiextensions.k8s.io/v1"
			kind:       "CustomResourceDefinition"
			metadata: {
				name: "any"
				annotations: "argocd.argoproj.io/sync-options": "Prune=false,Delete=false"
			}
		})
	}]

	resources: {
		// In the mesh, so ztunnel enforces the gRPC policy below. The
		// gateway's pods are not captured: istiod labels every gateway it
		// deploys istio.io/dataplane-mode: none. Not exempt from
		// cert-manager's webhook, as substrate-shim is not: the webhook's
		// path is the ingress Gateway's webhooks listener, which this
		// component does not render.
		Namespace: (NS): metadata: labels: Istio.ambient

		// The manager's own identity. It reads Backends, writes their
		// status and events, holds its leader election Lease, and mints
		// the impersonator's token, all in this namespace: it watches only
		// its own namespace, by POD_NAMESPACE, so a Backend anywhere else
		// is never served. So one Role, from the release's RBAC markers
		// (cmd/holos-authenticator/main.go), without their secrets get,
		// which only a Backend's credentialsSecretRef needs.
		ServiceAccount: (Name): metadata: namespace: NS
		Role: (Name): {
			metadata: namespace: NS
			rules: [
				{
					apiGroups: ["authenticator.holos.run"]
					resources: ["backends"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["authenticator.holos.run"]
					resources: ["backends/status"]
					verbs: ["get", "patch", "update"]
				},
				{
					apiGroups: ["authenticator.holos.run"]
					resources: ["backends/finalizers"]
					verbs: ["update"]
				},
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch"]
				},
				{
					apiGroups: ["coordination.k8s.io"]
					resources: ["leases"]
					verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
				},
				{
					apiGroups: [""]
					resources: ["serviceaccounts/token"]
					resourceNames: [HA.impersonator]
					verbs: ["create"]
				},
			]
		}
		RoleBinding: (Name): {
			metadata: namespace: NS
			roleRef: {
				apiGroup: "rbac.authorization.k8s.io"
				kind:     "Role"
				name:     Name
			}
			subjects: [{
				kind:      "ServiceAccount"
				name:      Name
				namespace: NS
			}]
		}

		// The impersonator: the identity the API server authenticates every
		// forwarded request as, with a token the manager mints for an hour
		// and renews. It may impersonate the users and the groups
		// HolosAuthenticator lists, by name, and do nothing else, so a
		// stolen token can become only those. The API server adds
		// system:authenticated to an impersonated user itself, which needs
		// no grant. resourceNames are never empty: an empty list would allow
		// every name.
		ServiceAccount: (HA.impersonator): metadata: namespace: NS
		ClusterRole: (HA.impersonator): rules: [
			{
				apiGroups: [""]
				resources: ["users"]
				verbs: ["impersonate"]
				resourceNames: [for U in HA.users {"\(HA.usernamePrefix)\(U)"}] & [_, ...]
			},
			{
				apiGroups: [""]
				resources: ["groups"]
				verbs: ["impersonate"]
				resourceNames: list.SortStrings(HA.groups) & [_, ...]
			},
		]
		ClusterRoleBinding: (HA.impersonator): {
			roleRef: {
				apiGroup: "rbac.authorization.k8s.io"
				kind:     "ClusterRole"
				name:     HA.impersonator
			}
			subjects: [{
				kind:      "ServiceAccount"
				name:      HA.impersonator
				namespace: NS
			}]
		}

		// /platform/owners is cluster-admin (interview Q63), as it is Argo
		// CD's role:admin. The subject is the group, so access follows
		// membership in the realm, not this file.
		ClusterRoleBinding: "platform-owners-cluster-admin": {
			roleRef: {
				apiGroup: "rbac.authorization.k8s.io"
				kind:     "ClusterRole"
				name:     "cluster-admin"
			}
			subjects: [{
				apiGroup: "rbac.authorization.k8s.io"
				kind:     "Group"
				name:     Keycloak.groups.owners.path
			}]
		}

		// The manager: the ext_authz server and the Backend controller in one
		// process. Two replicas, preferably on two nodes, as the gateway has:
		// every replica answers ext_authz from its own copy of the Backends,
		// and leader election decides only which one writes their status.
		// The ext_authz provider does not fail open, so with no replica up
		// every request through k8s.<domain> gets 403; the talosconfig
		// kubeconfig still works.
		Deployment: (Name): {
			metadata: namespace: NS
			spec: {
				replicas: 2
				selector: matchLabels: Labels
				template: {
					metadata: labels: Labels
					spec: {
						serviceAccountName: Name
						securityContext: {
							runAsNonRoot: true
							runAsUser:    65532
							runAsGroup:   65532
							seccompProfile: type: "RuntimeDefault"
						}
						topologySpreadConstraints: [{
							maxSkew:           1
							topologyKey:       "kubernetes.io/hostname"
							whenUnsatisfiable: "ScheduleAnyway"
							labelSelector: matchLabels: Labels
						}]
						containers: [{
							name:  "manager"
							image: HA.image
							args:  Args
							env: [
								// The namespace it watches, mints tokens in and
								// holds its Lease in.
								{
									name: "POD_NAMESPACE"
									valueFrom: fieldRef: fieldPath: "metadata.namespace"
								},
								// The private root, for OIDC discovery and the
								// JWKS at Keycloak's public URL, through the
								// ingress Gateway, whose certificate the private
								// CA issues. The root is minted in the cluster
								// and is not in git (Q52), so the Backend's
								// oidc.caBundle, base64 PEM, stays empty, and an
								// empty caBundle uses Go's system pool. With
								// SSL_CERT_DIR set, Go reads every file in the
								// directory after the image's SSL_CERT_FILE, as
								// holos-controller's manager does. Go reads the
								// pool once, so a new root needs a restart.
								{name: "SSL_CERT_DIR", value: CAMount},
							]
							ports: [
								{name: "grpc", containerPort: HA.grpcPort},
								{name: "health", containerPort: HealthPort},
							]
							// The kubelet's probes reach an ambient pod from
							// 169.254.7.127, which cilium-resources' policy
							// admits and ztunnel's policy does not see.
							livenessProbe: httpGet: {
								path: "/healthz"
								port: "health"
							}
							readinessProbe: httpGet: {
								path: "/readyz"
								port: "health"
							}
							volumeMounts: [{name: "private-ca", mountPath: CAMount, readOnly: true}]
							resources: {
								requests: {cpu: "10m", memory: "64Mi"}
								limits: memory: "128Mi"
							}
							securityContext: {
								allowPrivilegeEscalation: false
								readOnlyRootFilesystem:   true
								capabilities: drop: ["ALL"]
							}
						}]
						// Not optional: trust-manager comes earlier in the
						// registry, and without the root no Backend is
						// ready.
						volumes: [{name: "private-ca", configMap: name: PrivateCA.bundle}]
						terminationGracePeriodSeconds: 10
					}
				}
			}
		}

		// The extension provider's Service (components/istiod), the gRPC
		// port alone.
		Service: (Name): {
			metadata: namespace: NS
			spec: {
				selector: Labels
				ports: [{name: "grpc", port: HA.grpcPort, targetPort: "grpc", appProtocol: "grpc"}]
			}
		}

		// The Check response carries the impersonator's token, so only the
		// gateway may call the gRPC port: ztunnel admits the gateway's mesh
		// identity, over HBONE, and refuses every other pod and every other
		// port. The gateway's pods are not in ambient but speak HBONE to an
		// ambient workload themselves, with that identity. istio-cni lets the
		// manager's node's own network namespace through unchecked, for the
		// kubelet's probes, so a hostNetwork pod on that node is not refused:
		// only cilium and the ceph-csi node plugin run there today.
		AuthorizationPolicy: "\(Name)-grpc": {
			metadata: namespace: NS
			spec: {
				selector: matchLabels: Labels
				action: "ALLOW"
				rules: [{
					from: [{source: principals: [GW.principal]}]
					to: [{operation: ports: ["\(HA.grpcPort)"]}]
				}]
			}
		}

		// The one Backend: k8s.<domain> to this cluster's API server. The
		// token's aud must be the kubectl client (interview Q61, ADR 0002),
		// whose ID token kubelogin already caches for the Substrate shim.
		// The user is usernamePrefix and preferred_username, oidc:jeff
		// (Q62); the groups are the groups claim's full paths, of which
		// only HA.groups are forwarded. server.url is what the manager
		// reports; Envoy dials the API server by the HTTPRoute.
		Backend: kubernetes: {
			metadata: namespace: NS
			spec: {
				host: HA.host
				server: url: "https://\(APIServer.sni)"
				oidc: {
					issuerURL:      Keycloak.issuer
					clientID:       Keycloak.clients.kubectl
					usernameClaim:  HA.usernameClaim
					usernamePrefix: HA.usernamePrefix
					groupsClaim:    Keycloak.groupsClaim
				}
				groupMapping: anyOf: list.SortStrings(HA.groups)
				groupsHeaderSeparator: Separator
				serviceAccountRef: name: HA.impersonator
			}
		}

		// k8s.<domain>'s certificate, from the private CA, ECDSA P-256 as the
		// other gateways', renewed by cert-manager, which istiod hands to
		// the gateway as it changes. Its name is its entry's in
		// PrivateCA.requesters (components/private-ca.cue).
		Certificate: (GW.name): {
			metadata: namespace: NS
			spec: {
				PrivateCA.requesters[NS][GW.name]
				secretName: "\(GW.name)-tls"
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

		// The gateway Deployment's customization, which istiod merges into
		// the Deployment it generates: two replicas, preferably on two
		// nodes, as the ingress Gateway's.
		ConfigMap: (GW.parameters): {
			metadata: namespace: NS
			data: deployment: yaml.Marshal({
				spec: {
					replicas: 2
					template: spec: topologySpreadConstraints: [{
						maxSkew:           1
						topologyKey:       "kubernetes.io/hostname"
						whenUnsatisfiable: "ScheduleAnyway"
						labelSelector: matchLabels: "gateway.networking.k8s.io/gateway-name": GW.name
					}]
				}
			})
		}

		Gateway: (GW.name): {
			metadata: {
				namespace: NS
				annotations: {
					// The ServiceAccount istiod creates for the gateway and
					// runs it as, the identity the gRPC policy admits.
					"gateway.istio.io/service-account": GW.serviceAccount
					// No address of its own: it is reached only through the
					// ingress Gateway's k8s listener.
					"networking.istio.io/service-type": "ClusterIP"
				}
			}
			spec: {
				gatewayClassName: "istio"
				infrastructure: parametersRef: {
					group: ""
					kind:  "ConfigMap"
					name:  GW.parameters
				}
				// One listener, for the one host, which admits only
				// HTTPRoutes from this namespace, where only git writes.
				listeners: [{
					name:     "https"
					hostname: HA.host
					port:     443
					protocol: "HTTPS"
					tls: {
						mode: "Terminate"
						certificateRefs: [{kind: "Secret", name: Certificate[GW.name].spec.secretName}]
					}
					allowedRoutes: {
						kinds: [{group: "gateway.networking.k8s.io", kind: "HTTPRoute"}]
						namespaces: from: "Same"
					}
				}]
			}
		}

		// The ingress Gateway's k8s listener passes k8s.<domain> through to
		// this Gateway's Service. In this namespace, the only one the
		// listener admits TLSRoutes from, and the Service's, so no
		// ReferenceGrant. Rendered here rather than by ingress-gateway, which
		// comes before this namespace exists.
		TLSRoute: (GW.name): {
			metadata: namespace: NS
			spec: {
				parentRefs: [{
					group:       IG.parentRef.group
					kind:        IG.parentRef.kind
					namespace:   IG.namespace
					name:        IG.name
					sectionName: IG.listeners.k8s
				}]
				hostnames: [HA.host]
				rules: [{backendRefs: [{name: GW.service, port: 443}]}]
			}
		}

		// Every request to the API server. In this namespace, on the
		// listener that admits only this namespace's routes, so the route
		// to the kubernetes Service in default needs the ReferenceGrant
		// below. No timeout: Istio sets none on a route unless asked, which
		// watches, logs -f, exec and port-forward need. The gateway appends to
		// a client's X-Forwarded-For rather than replacing it, and the API
		// server records every entry in the audit log's sourceIPs, so the
		// route drops it, and X-Real-IP: the address the gateway sees is the
		// ingress pod's anyway.
		HTTPRoute: (APIServer.name): {
			metadata: namespace: NS
			spec: {
				parentRefs: [GatewayRef & {namespace: NS}]
				hostnames: [HA.host]
				rules: [{
					filters: [{
						type: "RequestHeaderModifier"
						requestHeaderModifier: remove: ["X-Forwarded-For", "X-Real-IP"]
					}]
					backendRefs: [{
						namespace: APIServer.namespace
						name:      APIServer.name
						port:      APIServer.port
					}]
				}]
			}
		}

		// Lets the HTTPRoute above, and only HTTPRoutes in this namespace,
		// name the kubernetes Service in default, and no other Service.
		ReferenceGrant: "\(Name)-kubernetes": {
			metadata: namespace: APIServer.namespace
			spec: {
				from: [{
					group:     "gateway.networking.k8s.io"
					kind:      "HTTPRoute"
					namespace: NS
				}]
				to: [{
					group: ""
					kind:  "Service"
					name:  APIServer.name
				}]
			}
		}

		// The gateway terminates the client's TLS, and the API server speaks
		// only TLS, so this originates it again: one-way, the API server's
		// certificate checked against the cluster's CA, which every pod has
		// at the ServiceAccount path, for the Service's name, which is also
		// the SNI. The API server is not a mesh workload, so there is no
		// mutual TLS. Exported to this namespace alone, where the gateway is
		// the only proxy.
		DestinationRule: (APIServer.name): {
			metadata: namespace: NS
			spec: {
				host: APIServer.host
				exportTo: ["."]
				trafficPolicy: tls: {
					mode:           "SIMPLE"
					caCertificates: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
					sni:            APIServer.sni
					subjectAltNames: [APIServer.sni]
				}
			}
		}

		// Every request on the gateway goes to the manager first (the
		// extension provider in istiod's mesh configuration). The gateway
		// serves one host, so there is nothing to scope the rule to: a
		// request for another host gets 404 from the gateway, and one whose
		// :authority is not exactly HA.host, such as host:443, gets 403
		// from the manager.
		AuthorizationPolicy: (GW.name): {
			metadata: namespace: NS
			spec: {
				targetRefs: [GatewayRef]
				action: "CUSTOM"
				provider: name: HA.provider.name
				rules: [{}]
			}
		}

		// The groups header to Impersonate-Group (Lua, above). No phase,
		// so istiod puts it after the authorization filters, ext_authz
		// among them.
		TrafficExtension: "impersonate-groups": {
			metadata: namespace: NS
			spec: {
				targetRefs: [GatewayRef]
				lua: inlineCode: Lua
			}
		}
	}
}).artifact]

// HealthPort is the manager's probe port, its --health-probe-bind-address
// default.
let HealthPort = 8081

// Args are the manager's flags (cmd/holos-authenticator/main.go at the
// release):
//
//   - --grpc-bind-address, the ext_authz server, plaintext; only the gateway
//     reaches it, over HBONE.
//   - --health-probe-bind-address, /healthz and /readyz.
//   - --metrics-bind-address=0: nothing scrapes Prometheus metrics here, so
//     the endpoint is off rather than open on the pod.
//   - --leader-elect, so one replica writes the Backends' status.
//   - --impersonate-groups-header, the default, stated, since the Lua names
//     it.
let Args = [
	"--grpc-bind-address=:\(HA.grpcPort)",
	"--health-probe-bind-address=:\(HealthPort)",
	"--metrics-bind-address=0",
	"--leader-elect",
	"--impersonate-groups-header=\(GroupsHeader)",
]
