package holos

import "encoding/json"

// management-namespaces is the Secrets Manager's management organization and
// project (interview Q54): the Namespaces holos-org-platform and
// holos-prj-platform, which git owns rather than the server, and the
// RoleBinding that lets the server work with Secrets in the project. Platform
// secrets are made in holos-prj-platform through the Secrets Manager
// (components/secrets-manager) and copied out by each consumer's
// per-namespace store (#ScopedSecretStore), whose Role and RoleBinding land
// in holos-prj-platform. So the namespaces are a component of their own,
// right after external-secrets in the registry, rather than part of the
// server's, which comes late: a consumer's sync would otherwise fail on a
// namespace that does not exist yet.
//
// Every resource here is a core or RBAC kind, so the component needs no CRD
// and nothing before it. The RoleBinding names the server's ClusterRole and
// ServiceAccount, which secrets-manager renders later; a binding to either
// before it exists grants nothing until it does.

let SM = SecretsManager
let P = SM.platform

// Owner is the platform owners' grant, in the Secrets Manager's annotation
// format: a JSON list of grants, each a principal, here a role by the full
// group path the groups claim carries, and a role on the resource.
let Owner = json.Marshal([{principal: SM.owners, role: "owner"}])

// Managed is the label the server selects every namespace it manages by, and
// Keep the annotation that stops Argo CD pruning or deleting one: deleting a
// management namespace deletes every platform secret in it, and none of them
// is in git.
let Managed = {"app.kubernetes.io/managed-by": "holos.run"}
let Keep = {"argocd.argoproj.io/sync-options": "Prune=false,Delete=false"}

holos: spec: artifacts: [(#ResourcesArtifact & {
	resources: {
		// The organizations and projects are the server's own keys
		// (console/resolver, metadata domain holos.run): a namespace is one
		// when it carries managed-by and resource-type, with the name under
		// the resource's prefix, holos-org- or holos-prj-. The share-roles
		// annotation is a resource's grant.
		//
		// Git owns these. The server writes a Namespace only when someone
		// changes an organization or project in the UI, with a full update,
		// so an edit there to a field rendered here, the display name, the
		// description or a role grant, shows in Argo CD as out of sync and
		// selfHeal puts git's value back. A grant to a person (share-users,
		// default-share-users) is not rendered and stays.
		//
		// Neither is in the mesh: they run nothing.

		// The organization: the SPA lists projects only within the
		// organization a person has chosen, so without one the platform
		// project is invisible. Platform owners own it, so they see it in
		// the organization list and may make projects in it; access to a
		// project's secrets is still the project's own grant. It holds no
		// Secrets: the server reads and writes Secrets only in project
		// namespaces.
		Namespace: (P.orgNamespace): metadata: {
			labels: Managed & {
				"holos.run/resource-type": "organization"
				"holos.run/organization":  P.organization
			}
			annotations: Keep & {
				"holos.run/display-name": "Platform"
				"holos.run/description":  "The platform's organization, holding its management project"
				"holos.run/share-roles":  Owner
			}
		}

		// The management project, in the organization by its label,
		// holos.run/organization, which the server's project list filters
		// on.
		//
		//   - share-roles, the project grant: platform owners are owners of
		//     the project, so they may list, create, update and delete its
		//     secrets and change its grants. A project grant never cascades
		//     to reading a secret's data, but an owner may share a secret to
		//     themselves and then read it.
		//   - default-share-roles, the grants the server puts on every
		//     secret made in the project: platform owners are owners of each
		//     one, so they may read it and share it. The person who made a
		//     secret is always its owner too.
		Namespace: (P.namespace): metadata: {
			labels: Managed & {
				"holos.run/resource-type": "project"
				"holos.run/organization":  P.organization
				"holos.run/project":       P.project
			}
			annotations: Keep & {
				"holos.run/display-name":        "Platform"
				"holos.run/description":         "Platform secrets, copied into the components that use them by External Secrets"
				"holos.run/share-roles":         Owner
				"holos.run/default-share-roles": Owner
			}
		}

		// The server's secrets verbs in this project, and in no other
		// namespace (components/secrets-manager). Every project namespace
		// git renders gets one of these beside it; a project made in the UI
		// gets none until git adds it.
		RoleBinding: (SM.secretsRole): {
			metadata: namespace: P.namespace
			roleRef: {
				apiGroup: "rbac.authorization.k8s.io"
				kind:     "ClusterRole"
				name:     SM.secretsRole
			}
			subjects: [{
				kind:      "ServiceAccount"
				name:      SM.name
				namespace: SM.namespace
			}]
		}
	}
}).artifact]
