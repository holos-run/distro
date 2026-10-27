package holos

// hello is a small echo service in an ambient namespace, routed from the
// ingress Gateway at hello.<privateDomain>, to show the path from the laptop
// through the gateway to a mesh workload: the gateway terminates TLS with the
// private CA's wildcard and reaches the pod over HBONE through its node's
// ztunnel. Traefik's whoami answers with the request it received.

let Name = "hello"
let Port = 8080
let Labels = {"app.kubernetes.io/name": Name}

holos: spec: artifacts: [(#ResourcesArtifact & {
	resources: {
		Namespace: (Name): metadata: labels: Istio.ambient

		// Its own ServiceAccount, so its mesh identity is its own.
		ServiceAccount: (Name): metadata: namespace: Name

		Deployment: (Name): {
			metadata: namespace: Name
			// A label on the Deployment alone, not its pods, so changing it
			// rolls nothing out: the milestone's test of a change through
			// git (README, Syncing).
			metadata: labels: "holos.run/gitops-test": "signed"
			spec: {
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
						containers: [{
							name:  "whoami"
							image: "docker.io/traefik/whoami:v1.11.0@sha256:200689790a0a0ea48ca45992e0450bc26ccab5307375b41c84dfc4f2475937ab"
							args: ["--port", "\(Port)", "--name", Name]
							ports: [{name: "http", containerPort: Port}]
							// The kubelet's probe reaches an ambient pod from
							// 169.254.7.127, which cilium-resources' policy
							// admits.
							readinessProbe: httpGet: {
								path: "/health"
								port: "http"
							}
							resources: {
								requests: {cpu: "10m", memory: "16Mi"}
								limits: memory: "32Mi"
							}
							securityContext: {
								allowPrivilegeEscalation: false
								readOnlyRootFilesystem:   true
								capabilities: drop: ["ALL"]
							}
						}]
					}
				}
			}
		}

		Service: (Name): {
			metadata: namespace: Name
			spec: {
				selector: Labels
				ports: [{name: "http", port: 80, targetPort: "http"}]
			}
		}

		HTTPRoute: (Name): {
			metadata: namespace: Name
			spec: {
				parentRefs: [IngressGateway.parentRef]
				hostnames: [IngressGateway.hosts[Name]]
				rules: [{backendRefs: [{name: Name, port: 80}]}]
			}
		}
	}
}).artifact]
