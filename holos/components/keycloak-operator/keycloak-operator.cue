package holos

import "encoding/yaml"

// keycloak-operator is the Keycloak Operator, its CRDs and its RBAC, in the
// ambient namespace keycloak. It runs no Keycloak itself: the keycloak
// component writes the Keycloak resource, in the same namespace, and the
// operator runs the server from it. The operator watches its own namespace
// only (JOSDK_WATCH_CURRENT, as released), so every Keycloak resource it
// reconciles is in keycloak, and its permissions there are RoleBindings.
//
// 26.8.1 (2026-10-13), the latest release, from the release's tag of
// https://github.com/keycloak/keycloak-k8s-resources, directory kubernetes/,
// vendored unmodified in vendor/26.8.1/:
//
//	keycloaks.k8s.keycloak.org-v1.yml             sha256:20c51247cb6cbc6158098caabeaf6b429dc8c016e35829f5ddd9c468b7582667
//	keycloakrealmimports.k8s.keycloak.org-v1.yml  sha256:8d552e1864d78117a07e535479ddb36e16a42b2695726c875f44828e1323edd4
//	keycloakoidcclients.k8s.keycloak.org-v1.yml   sha256:15d9199822d1918438bd1d093eee3ec8406e7f9d0837c4527fd6da99c63b058a
//	keycloaksamlclients.k8s.keycloak.org-v1.yml   sha256:7c69d146f610f3c40acf4466518e89615b6fce7ee2a03d75cd93b7a9a7bf259e
//	kubernetes.yml                                sha256:2b95907f094e7a274647ba2db22bcc2f9397e33836768990dc4e4b39437e2cba
//
// All four CRDs, the release's kustomization.yml's list. The platform uses
// Keycloak and KeycloakRealmImport, which imports the realm once
// (keycloak-realm), and holos-controller, not the operator, reconciles the
// realm's clients and groups after that; but the 26.8.1 operator starts a
// controller for each of the four kinds, and one whose CRD is missing stops
// the operator at startup.
//
// kubernetes.yml names no namespace, as the release's kustomization.yml
// sets it, so namespace below does the same. The operator's image and the
// server image it runs (RELATED_IMAGE_KEYCLOAK) are both pinned by the
// release to quay.io/keycloak/keycloak-operator:26.8.1 and
// quay.io/keycloak/keycloak:26.8.1, so the Keycloak resource names no image
// and the server stays on the operator's version. The Deployment tolerates no
// taint, so the control plane's NoSchedule taint keeps it, and every
// Keycloak pod, on the workers. The operator registers no admission webhook.
// Keycloak (components/keycloak.cue) holds the version and the namespace.

let Vendor = "vendor/\(Keycloak.version)"

holos: spec: artifacts: [(#FileArtifact & {
	files: [
		for CRD in ["keycloaks", "keycloakrealmimports", "keycloakoidcclients", "keycloaksamlclients"] {
			"\(Vendor)/\(CRD).k8s.keycloak.org-v1.yml"
		},
		"\(Vendor)/kubernetes.yml",
	]
	namespace: Keycloak.namespace

	// The namespace is in the mesh, like hello's and rustfs's, so the
	// gateway reaches Keycloak over HBONE. The operator and the database
	// are in it too.
	resources: Namespace: (Keycloak.namespace): metadata: labels: Istio.ambient

	patches: [
		// Argo CD does not prune the CRDs. Deleting one deletes every
		// resource of its kind, the Keycloak resource among them, so a CRD
		// dropping out of the render while the Application stays would
		// otherwise take the server down.
		{
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
		},
		// The release's Deployment sets no security context, which Talos's
		// baseline enforcement allows and its restricted warning flags. The
		// operator needs nothing restricted takes away, and its image runs
		// as uid 1000, so it meets the restricted standard, as
		// cloudnative-pg's and external-secrets' pods do.
		{
			target: {kind: "Deployment", name: "keycloak-operator"}
			patch: yaml.Marshal({
				apiVersion: "apps/v1"
				kind:       "Deployment"
				metadata: {
					name:      "keycloak-operator"
					namespace: Keycloak.namespace
				}
				spec: template: spec: {
					securityContext: {
						runAsNonRoot: true
						seccompProfile: type: "RuntimeDefault"
					}
					containers: [{
						name: "keycloak-operator"
						securityContext: {
							allowPrivilegeEscalation: false
							capabilities: drop: ["ALL"]
						}
					}]
				}
			})
		},
	]
}).artifact]
