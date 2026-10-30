package holos

// toolhive is the platform's one ToolHive MCP server (ToolHive,
// components/toolhive.cue) at https://toolhive.<privateDomain>/mcp, behind
// a Keycloak ID token and Cedar. The toolhive-operator component, before
// it, holds its namespace.
//
// For the MCPServer the operator runs a proxy runner, the Deployment and
// Service mcp-<name>-proxy, which checks every request's bearer token
// against the realm and every MCP call against the Cedar policies, and the
// proxy runner creates the MCP server itself, the StatefulSet <name> and
// the Service mcp-<name>, which it forwards permitted requests to. Neither
// creates a route or a NetworkPolicy (stacklok/toolhive issue 1129), so both
// are here: the route to the proxy, and the policies that make the proxy
// the only way to the MCP server (Isolation, below).
//
// Every kind's CRD comes from an earlier component: the toolhive.stacklok.dev
// kinds from toolhive-crds, HTTPRoute from gateway-api.
let T = ToolHive
let S = T.server
let NS = S.namespace

// The pods' labels, which the NetworkPolicies select on: the proxy runner's
// (labelsForMCPServer, cmd/thv-operator/controllers/mcpserver_controller.go)
// and the MCP server's, which the proxy runner sets on its StatefulSet
// (pkg/container/kubernetes/client.go, DeployWorkload).
let Pods = {
	proxy: {
		"app.kubernetes.io/name":     "mcpserver"
		"app.kubernetes.io/instance": S.name
	}
	server: {
		app:      S.name
		toolhive: "true"
	}
}

// OIDC and Authz are the MCPOIDCConfig and MCPAuthzConfig the MCPServer
// names.
let OIDC = "keycloak"
let Authz = S.name

// Restricted is the MCP server container's security context. The proxy
// runner already applies one that satisfies the namespace's restricted Pod
// Security; this pins it explicitly, so a change upstream cannot loosen it.
let Restricted = {
	allowPrivilegeEscalation: false
	runAsNonRoot:             true
	capabilities: drop: ["ALL"]
	seccompProfile: type: "RuntimeDefault"
}

holos: spec: artifacts: [(#ResourcesArtifact & {resources: _Resources}).artifact]

_Resources: #Resources & {
	// The realm, by its ID tokens (ADR 0002): the proxy runner fetches the
	// realm's discovery document and keys through the ingress Gateway, at
	// a private address, trusting the private root alone. The audience is
	// set on the MCPServer.
	MCPOIDCConfig: (OIDC): {
		metadata: namespace: NS
		spec: {
			type: "inline"
			inline: {
				issuer: Keycloak.issuer
				caBundleRef: configMapRef: {
					name: PrivateCA.bundle
					key:  PrivateCA.bundleKey
				}
				// Keycloak's name resolves to the ingress Gateway's
				// LoadBalancer address, which is private, and the proxy
				// runner refuses a private discovery or JWKS address
				// without this.
				jwksAllowPrivateIP: true
			}
		}
	}

	// Cedar. Once any authorization is configured the proxy denies what no
	// policy permits, and it filters tools/list, prompts/list and
	// resources/list to what the caller may call, get or read. The principal
	// is Client::"<sub>", a member of THVGroup::"<group>" for each entry of
	// the token's groups claim, which the realm writes as full paths
	// (Keycloak.groupsClaim).
	//
	// /platform/owners may call every tool, get every prompt and read every
	// resource, but nobody may call get-env, which returns the MCP server's
	// whole environment. Everyone else may open a session but is denied
	// every tool, prompt and resource, and sees empty lists.
	MCPAuthzConfig: (Authz): {
		metadata: namespace: NS
		spec: {
			type: "cedarv1"
			config: {
				group_claim_name: Keycloak.groupsClaim
				entities_json:    "[]"
				policies: [
					"permit(principal in THVGroup::\"\(Keycloak.groups.owners.path)\", action in [Action::\"call_tool\", Action::\"get_prompt\", Action::\"read_resource\"], resource);",
					"forbid(principal, action == Action::\"call_tool\", resource == Tool::\"get-env\");",
				]
			}
		}
	}

	MCPServer: (S.name): {
		metadata: namespace: NS
		spec: {
			image: S.image
			// Over HTTP: the proxy reaches the MCP server at mcp-<name>,
			// port mcpPort, never by attaching to its stdio, so the proxy's
			// Role has no pods/attach.
			transport: "streamable-http"
			args: ["streamableHttp"]
			env: [{name: "PORT", value: "\(S.port)"}]
			mcpPort:   S.port
			proxyPort: S.proxy.port

			// ID tokens of the kubectl client, the audience every Holos
			// service behind a person's token checks (the Substrate shim,
			// holos-authenticator, interview Q61). resourceUrl is what the
			// proxy's protected resource metadata names, the public URL.
			oidcConfigRef: {
				name:        OIDC
				audience:    Keycloak.clients.kubectl
				resourceUrl: "\(S.url)/mcp"
				scopes: ["openid", "profile", "email", Keycloak.groupsClaim]
			}
			authzConfigRef: name: Authz

			// Every MCP request's outcome, allowed or denied, with the
			// caller's identity, in the proxy runner's log.
			audit: enabled: true

			resources: {
				requests: {cpu: "10m", memory: "64Mi"}
				limits: memory: "256Mi"
			}
			// The MCP server's container, mcp, pinned to restricted Pod
			// Security (Restricted, above).
			podTemplateSpec: spec: {
				securityContext: {
					runAsNonRoot: true
					seccompProfile: type: "RuntimeDefault"
				}
				containers: [{
					name:            "mcp"
					securityContext: Restricted
				}]
			}
		}
	}

	// The route: every path of the host to the proxy runner, never to the
	// MCP server, which would bypass the token and the policies. The https
	// listener takes routes from every namespace.
	HTTPRoute: (S.name): {
		metadata: namespace: NS
		spec: {
			parentRefs: [IngressGateway.parentRef]
			hostnames: [S.host]
			rules: [{backendRefs: [{name: S.proxy.service, port: S.proxy.port}]}]
		}
	}

	// Isolation. The MCP server checks no token, so its pod admits only the
	// proxy runner, at its port, and may send nothing anywhere: it needs no
	// network beyond answering. The proxy runner admits only the ingress
	// Gateway's pods. The namespace is outside the mesh, so nothing else
	// is in the path. The kubelet's probes come from the node, which Cilium
	// always admits.
	NetworkPolicy: "\(S.name)-server": {
		metadata: namespace: NS
		spec: {
			podSelector: matchLabels: Pods.server
			policyTypes: ["Ingress", "Egress"]
			ingress: [{
				from: [{podSelector: matchLabels: Pods.proxy}]
				ports: [{protocol: "TCP", port: S.port}]
			}]
			egress: []
		}
	}
	// The proxy runner may send to four places alone: the cluster's DNS;
	// the MCP server; Keycloak, through the ingress Gateway, whose address
	// keycloak.<privateDomain> resolves to and which Cilium translates to
	// the gateway's pods before it applies the policy; and the API server,
	// where it creates and watches the MCP server's StatefulSet and
	// Services. The API server is on the control plane node, which runs no
	// Cilium agent (interview Q33), so it is matched by its address.
	NetworkPolicy: "\(S.name)-proxy": {
		metadata: namespace: NS
		spec: {
			podSelector: matchLabels: Pods.proxy
			policyTypes: ["Ingress", "Egress"]
			ingress: [{
				from: [{
					namespaceSelector: matchLabels: "kubernetes.io/metadata.name":      IngressGateway.namespace
					podSelector: matchLabels: "gateway.networking.k8s.io/gateway-name": IngressGateway.name
				}]
				ports: [{protocol: "TCP", port: S.proxy.port}]
			}]
			egress: [
				{
					to: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "kube-system"
						podSelector: matchLabels: "k8s-app":                           "kube-dns"
					}]
					ports: [{protocol: "UDP", port: 53}, {protocol: "TCP", port: 53}]
				},
				{
					to: [{podSelector: matchLabels: Pods.server}]
					ports: [{protocol: "TCP", port: S.port}]
				},
				{
					to: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name":      IngressGateway.namespace
						podSelector: matchLabels: "gateway.networking.k8s.io/gateway-name": IngressGateway.name
					}]
					ports: [{protocol: "TCP", port: 443}]
				},
				{
					to: [{ipBlock: cidr: "\(Cluster.apiServer.address)/32"}]
					ports: [{protocol: "TCP", port: Cluster.apiServer.port}]
				},
			]
		}
	}
}
