package holos

import "encoding/yaml"

// holos-controller reconciles the realm's groups, group memberships, users and
// clients from keycloak.holos.run resources, against an Instance naming a
// realm that already exists (the keycloak-realm component's import). It also
// serves quay.holos.run, unused until Quay, and reads security.holos.run
// ReferenceGrants, which authorize a reference from one namespace to an
// Instance or Group in another.
//
// The source of truth is aavis-ops at tag holos-controller-v0.22.0, not the
// empty holos-run/holos-controller repository. Its CRD base,
// config/crd/holos-controller/bases, and its deploy base,
// config/deploy/holos-controller without its kustomization.yaml files, are
// vendored unmodified in vendor/0.22.0/:
//
//	crd/keycloak.holos.run_clients.yaml               sha256:b8f8967bfb272cc8c1df72e0a93fbdbb1205f929d764cd7e1aeb577c7215a75f
//	crd/keycloak.holos.run_groupmemberships.yaml      sha256:be72d7c65e9932b3fae7f43e9ee404107979ddcd20aee7196c54541d933190ae
//	crd/keycloak.holos.run_groups.yaml                sha256:ddff14403dfd80ab80ce92f53acb0b8a424ec6dd9556ff2224db653b65abe6d2
//	crd/keycloak.holos.run_instances.yaml             sha256:7ba9b6cdf12bae65be7e39063ee873561282393aa51c42ebe12902e051285493
//	crd/keycloak.holos.run_users.yaml                 sha256:8c076fdc29212f33020bb76b83b865d10ccd890fd1d541ceb9df8c6350c4cafd
//	crd/quay.holos.run_organizations.yaml             sha256:b4b323d75e8443efeac95a7119bc520ca03db427a8afe282d45cdc2c5b8a0817
//	crd/quay.holos.run_repositories.yaml              sha256:e0a3a979941fa72d5efa3592a269fed05242a19b4f01979f344d66202bf1736d
//	crd/security.holos.run_referencegrants.yaml       sha256:7ee828bad59cb621bb3c9d19e69cc73c7d34af5180c72fcb264810c25d815578
//	deploy/manager.yaml                               sha256:6baac2aa526f9ca6aeaa6ee2d31a26c46970eb6ee6679ea572c13c285be200f0
//	deploy/metrics_service.yaml                       sha256:4f3d5cfea1c79f680a0b47603c718d4d23bd4128d67068f2e95791987d02e3c0
//	deploy/rbac/groupmembership_editor_role.yaml      sha256:179d2c962fc96b56654988ddbc813532b6c4e10da64d45a330aa98217720d2d4
//	deploy/rbac/groupmembership_viewer_role.yaml      sha256:b29f0f94e74f5f370027304b3660b17bf6e6ca5b0569416f37d4d08c8413edde
//	deploy/rbac/leader_election_role_binding.yaml     sha256:5ae02945ea08e3f6db336814de02122f97d3d3d32db1220e76c4e4e3fb86a597
//	deploy/rbac/leader_election_role.yaml             sha256:a84ab79997e6c6c4ee1f17ca62c70b6e11cdd11b00f25568c2e54837cb0a1e57
//	deploy/rbac/metrics_reader_role.yaml              sha256:843f412251790c1a346b49300b5e4a9620f178036656b5d5c81c3025dae64f41
//	deploy/rbac/role_binding.yaml                     sha256:a452256b8eca3573bc013bd17632df6e98dfd76589efb521807ae73c95711bad
//	deploy/rbac/role.yaml                             sha256:ab276b271178914548422dd33d84230126b99207dbeb08b7c368f2d72e8fcaa5
//	deploy/rbac/service_account.yaml                  sha256:c689a096d5b87f1232b2a4a5e40c44e085570a1ba2b0c9a606cb6ef4751a1300
//
// All eight CRDs, quay.holos.run's too: the manager starts a controller for
// every kind it serves and needs each kind's CRD to start. The manager
// registers no admission webhook, so it needs no route on the gateway's
// webhooks listener. Its own resources, the Instance and the rest, are the
// keycloak-realm component's, after this one, so their CRDs are established
// before Argo CD applies them.
//
// The manager reads its Keycloak credential from Secret
// holos-controller-keycloak-creds in its own namespace, by POD_NAMESPACE,
// which keycloak-realm writes; until it exists, each resource reports
// CredentialsNotFound and is retried. HolosController
// (components/keycloak.cue) holds the version, the image and the names.

let Vendor = "vendor/\(HolosController.version)"
let NS = HolosController.namespace

holos: spec: artifacts: [(#FileArtifact & {
	files: [
		for F in [
			"keycloak.holos.run_clients",
			"keycloak.holos.run_groupmemberships",
			"keycloak.holos.run_groups",
			"keycloak.holos.run_instances",
			"keycloak.holos.run_users",
			"quay.holos.run_organizations",
			"quay.holos.run_repositories",
			"security.holos.run_referencegrants",
		] {"\(Vendor)/crd/\(F).yaml"},
		for F in [
			"rbac/service_account",
			"rbac/role",
			"rbac/role_binding",
			"rbac/groupmembership_editor_role",
			"rbac/groupmembership_viewer_role",
			"rbac/leader_election_role",
			"rbac/leader_election_role_binding",
			"rbac/metrics_reader_role",
			"manager",
			"metrics_service",
		] {"\(Vendor)/deploy/\(F).yaml"},
	]
	// The deploy base names no namespace for the Deployment and the Service,
	// as its kustomization.yaml sets it, so namespace does the same.
	namespace: NS

	// The manager's namespace is in the mesh, like keycloak's: it calls
	// Keycloak at its public URL, through the gateway, as any pod does.
	resources: Namespace: (NS): metadata: labels: Istio.ambient

	patches: [
		// Argo CD does not prune the CRDs: deleting one deletes every
		// resource of its kind, and the controller's finalizers would then
		// delete the groups and clients they own in Keycloak.
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
		// The release's image, in place of the deploy base's development
		// default, controller:dev, which its kustomization's images
		// transformer would set. Pinned by digest, so pulled only when
		// missing. The manager already runs restricted: non-root, no
		// privilege escalation, all capabilities dropped, a read-only root.
		{
			target: {kind: "Deployment", name: "holos-controller-manager"}
			patch: yaml.Marshal({
				apiVersion: "apps/v1"
				kind:       "Deployment"
				metadata: {
					name:      "holos-controller-manager"
					namespace: NS
				}
				spec: template: spec: containers: [{
					name:            "manager"
					image:           HolosController.image
					imagePullPolicy: "IfNotPresent"
				}]
			})
		},
	]
}).artifact]
