package holos

import "strings"

// project renders one ProjectClaim, projects.<project> (projects/), as the
// component project-<project>: the registry adds one per claim, each from
// this directory with the parameter project (collections.cue), and
// argocd-apps gives each an Application in the platform AppProject. The
// claim is a few lines of CUE, and this is everything it stands for, ported
// from aavis-ops' project component:
//
//   - the project's namespace, named for it, in the mesh;
//   - its owner, editor and viewer groups in the realm, each owner's user,
//     and the owners' membership in the owner group;
//   - its Quay organization, with a team synced from each group;
//   - the RoleBinding that gives the owner group ownerAccess, admin by
//     default, in the namespace, and nowhere else;
//   - its Argo CD AppProject, confined to the namespace, and its
//     Application, which syncs the project's own directory in deploy/.
//
// The owner group's claim and the owners' usernames reach
// holos-authenticator's allowlist from collections.cue, so the same
// definition names the group the RoleBinding binds and the group the
// authenticator forwards.
//
// No Keycloak client: aavis-ops makes one per project only so that Quay
// teams can sync from its client roles, and Quay here syncs teams from the
// full group paths in the groups claim (interview Q65). No Secrets Manager
// project, holos-prj-<project>, yet (Q64). No ResourceQuota, and no RBAC
// for the editor and viewer groups, which nothing binds.
//
// Every kind's CRD comes from an earlier component: Group, User,
// GroupMembership, Organization and the security.holos.run ReferenceGrant
// from holos-controller, AppProject and Application from argocd. The
// Instance the Keycloak resources name is keycloak-realm's, and the Quay
// credential the Organization is reconciled with is quay's copy in
// holos-controller's namespace.

// ProjectName is the claim this instance renders, the project parameter
// its registry entry passes (#ProjectRegistrations). Projects.#Unreserved
// refuses a name the platform uses, so a claim that takes one fails the
// render here. Without the parameter, as `cue vet ./...` evaluates this
// directory, it is empty and the instance renders nothing.
ProjectName: string | *"" @tag(project)

let NAME = ProjectName & Projects.#Unreserved
let P = projects[NAME]

// Labels mark everything the claim renders as the project's.
let Labels = {"holos.run/project": NAME}

// Groups are the Keycloak groups of the roles (#ProjectRoleGroupPath),
// each with its Group resource's name, the path after projects/ with
// dashes.
let Groups = {
	for ROLE in #ProjectRoles {
		(ROLE): (#ProjectRoleGroupPath & {project: NAME, role: ROLE}) & {
			resource: "\(NAME)-roles-\(ROLE)"
		}
	}
}

// Owners are the claim's owners, each checked against the realm's people
// (Projects.people, Projects.usernames and Projects.#Person), so an owner
// whose username is another person's, who is one of the platform's people
// under another username, or who is a platform service user, fails the
// render. The checks are folded into email, which the owner group's
// membership and the ConfigMap always render, so they hold for an owner
// with no User too. platform is whether Keycloak already has them, for
// whom no User is rendered.
let Owners = {
	for EMAIL, O in P.owners {
		(EMAIL): {
			let USERNAME = O.username & Projects.usernames[EMAIL] & Projects.#Person
			username: USERNAME
			email:    EMAIL & Projects.people[USERNAME].email
			platform: Projects.people[USERNAME].platform
		}
	}
}

// Directory is the project's own directory in deploy/, which its
// Application syncs: the second artifact, outside
// deploy/clusters/<cluster>/components, where only the platform's
// Applications look, and inside deploy/clusters, so a render from a clean
// deploy/clusters writes it again. It holds only what this component
// renders: the render removes deploy/clusters first, so a file put there by
// hand would be gone at the next render, and CI would fail the pull request
// that committed it.
let Directory = "clusters/\(Cluster.name)/projects/\(NAME)"

if ProjectName != "" {holos: spec: artifacts: [
	(#ResourcesArtifact & {
		resources: {
			// The namespace, named for the project, which is its one namespace.
			// In the mesh, as hello's is: the project's workloads talk to each
			// other and to the gateway over ztunnel's mutual TLS.
			Namespace: (NAME): metadata: labels: Istio.ambient & Labels

			// The owner, editor and viewer groups, at
			// /projects/<project>/roles/<role>. holos-controller makes the
			// parents, /projects, /projects/<project> and its roles, as it
			// walks a path, so they have no resources of their own; deleting a
			// Group deletes only its own group, and leaves the parents in the
			// realm (README.md, Removing a project). Only the
			// owner group has members, and only it is bound to anything in
			// Kubernetes; editor and viewer sync Quay teams, and their members
			// are added in Keycloak by hand.
			for ROLE, G in Groups {
				Group: (G.resource): {
					metadata: {
						namespace: NAME
						labels:    Labels
					}
					spec: {
						path:        G.path
						instanceRef: HolosController.instance
					}
				}
			}

			// Each owner's user, unless Keycloak already has them as one of
			// the platform's people, as jeff, whom the realm import creates:
			// holos-controller finds a member by email, so the membership needs
			// no User. No password: it is set in Keycloak by hand (README.md,
			// Projects). adopt, because one person may own several projects,
			// each with its own resource for them, and Orphan, because a person
			// is not a project's to delete: removing a claim, or one of its
			// owners, leaves the user and their password in the realm, and
			// takes them only out of the group.
			for O in Owners if !O.platform {
				User: (O.username): {
					metadata: {
						namespace: NAME
						labels:    Labels
					}
					spec: {
						email:          O.email
						username:       O.username
						instanceRef:    HolosController.instance
						adopt:          true
						deletionPolicy: "Orphan"
					}
				}
			}

			// The owners in the owner group: at least one, so a claim with
			// no owners fails the render rather than make a project nobody
			// may use.
			GroupMembership: (Groups.owner.resource): {
				metadata: {
					namespace: NAME
					labels:    Labels
				}
				spec: {
					instanceRef: HolosController.instance
					groupRef: name: Groups.owner.resource
					members: [for O in Owners {email: O.email}] & [_, ...]
				}
			}

			// The Keycloak resources above name the Instance in keycloak,
			// another namespace, which holos-controller allows only with a
			// ReferenceGrant there, from these kinds in the project's
			// namespace to that one Instance. Nothing else in the namespace may
			// create or change one: the admin ClusterRole the owners hold has
			// no write verb on holos-controller's kinds (only get, list and
			// watch on GroupMemberships, which the controller's
			// groupmembership-viewer-role aggregates to view), and the
			// project's AppProject refuses them. Wave -1, so it exists before the resources that
			// need it: a Group reconciled first reports ReferenceNotGranted
			// until its retry. It must also outlive them: their finalizers
			// need it to reach the Instance (README.md, Removing a project).
			ReferenceGrant: "project-\(NAME)": {
				apiVersion: "security.holos.run/v1alpha1"
				metadata: {
					namespace: HolosController.instance.namespace
					labels:    Labels
					annotations: "argocd.argoproj.io/sync-wave": "-1"
				}
				spec: {
					from: [for KIND in ["Group", "User", "GroupMembership"] {
						group:     "keycloak.holos.run"
						kind:      KIND
						namespace: NAME
					}]
					to: [{
						group: "keycloak.holos.run"
						kind:  "Instance"
						name:  HolosController.instance.name
					}]
				}
			}

			// The project's Quay organization, named for it, with a team synced
			// from each of its groups by claim, and platformowners, as every
			// organization has (Quay.ownersTeam). In the project's namespace:
			// holos-controller reads its Quay credential from its own namespace
			// whatever namespace names it, so the credential is not copied
			// here. Orphan, as demo is, so removing the claim leaves the
			// organization and its images in Quay. Team membership follows the
			// groups claim at each login, so a person added to a group joins
			// the team when they next log in to Quay.
			Organization: (NAME): {
				metadata: {
					namespace: NAME
					labels:    Labels
				}
				spec: {
					name:           NAME
					email:          "quay+\(NAME)@\(IngressGateway.domain)"
					deletionPolicy: "Orphan"
					syncedTeams: [
						{
							name:      Quay.ownersTeam
							oidcGroup: Keycloak.groups.owners.path
							role:      "admin"
						},
						for ROLE in #ProjectRoles {
							Projects.teams[ROLE] & {oidcGroup: Groups[ROLE].claim}
						},
					]
				}
			}

			// The owners' access to the namespace, and to no other: the owner
			// group bound to the built-in ClusterRole ownerAccess, admin by
			// default, by a RoleBinding here.
			//
			// The subject is the group's full path with its leading slash,
			// /projects/<project>/roles/owner, and the slash is the point. The
			// realm writes full paths into the groups claim, holos-authenticator
			// forwards each as an Impersonate-Group header with no prefix, and
			// the API server compares the header with this subject character
			// for character. The bare path, without the slash, which
			// holos-substrate's collection binds, matches nothing: the owner
			// has no access, and nothing reports it. So the subject is the
			// group's claim (#ProjectRoleGroupPath), the definition the
			// authenticator's allowlist is made from (#ProjectOwnerGroupClaims),
			// and `grep -r /projects/<project>/roles/owner deploy/` finds both.
			RoleBinding: "\(NAME)-owners": {
				metadata: {
					namespace: NAME
					labels:    Labels
				}
				roleRef: {
					apiGroup: "rbac.authorization.k8s.io"
					kind:     "ClusterRole"
					name:     P.ownerAccess
				}
				subjects: [{
					apiGroup: "rbac.authorization.k8s.io"
					kind:     "Group"
					name:     Groups.owner.claim
				}]
			}

			// The project's AppProject. Its Application may sync only from
			// this repository, at commits signed as the platform's are, into
			// the project's namespace alone, and no cluster-scoped kind, since
			// it has no clusterResourceWhitelist. Within the namespace it may
			// sync any kind but these, which would let a project grant itself
			// more than its claim does:
			//
			//   - Role and RoleBinding, as in aavis-ops: the claim's
			//     RoleBinding is the platform's, in the Application above;
			//   - holos-controller's kinds: the ReferenceGrant lets this
			//     namespace's Keycloak resources name the realm's Instance, so
			//     an adopting Group or GroupMembership synced here could take
			//     over any group in the realm, /platform/owners among them,
			//     and an Organization here is reconciled with the platform's
			//     Quay credential.
			//
			// Wave -1, so it exists before the Application that names it.
			AppProject: (NAME): {
				metadata: {
					namespace: ArgoCD.namespace
					labels:    Labels
					annotations: "argocd.argoproj.io/sync-wave": "-1"
				}
				spec: {
					description: "The project \(NAME), synced from \(ArgoCD.repoURL)"
					sourceRepos: [ArgoCD.repoURL]
					destinations: [{
						server:    "https://kubernetes.default.svc"
						namespace: NAME
					}]
					namespaceResourceWhitelist: [{group: "*", kind: "*"}]
					namespaceResourceBlacklist: [
						{group: "rbac.authorization.k8s.io", kind: "Role"},
						{group: "rbac.authorization.k8s.io", kind: "RoleBinding"},
						{group: "keycloak.holos.run", kind: "*"},
						{group: "quay.holos.run", kind: "*"},
						{group: "security.holos.run", kind: "*"},
					]
					signatureKeys: [for K in ArgoCD.signingKeys {keyID: K.id}]
				}
			}

			// The project's Application, in its AppProject, syncing its own
			// directory (Directory, the second artifact below) from main into
			// its namespace, as the platform's Applications do
			// (components/argocd-apps): automated, with prune and selfHeal,
			// server-side, and retried. No resources-finalizer, as theirs have
			// none, so deleting it leaves what it synced.
			Application: (NAME): {
				metadata: {
					namespace: ArgoCD.namespace
					labels:    Labels
				}
				spec: {
					project: NAME
					destination: {
						server:    "https://kubernetes.default.svc"
						namespace: NAME
					}
					source: {
						repoURL:        ArgoCD.repoURL
						targetRevision: ArgoCD.targetRevision
						path:           "holos/deploy/\(Directory)"
					}
					syncPolicy: {
						automated: {
							prune:    true
							selfHeal: true
						}
						syncOptions: ["ServerSideApply=true"]
						retry: {
							limit: 10
							backoff: {
								duration:    "5s"
								factor:      2
								maxDuration: "3m"
							}
						}
					}
				}
			}
		}
	}).artifact,

	// The project's own directory, which its Application syncs. It holds only
	// the one ConfigMap project, describing the claim, so the Application has
	// something to be Synced and Healthy with. A project's own manifests are
	// future work: they would have to be rendered from CUE here, or live
	// outside deploy/clusters, since this directory is rewritten by every
	// render.
	(#ResourcesArtifact & {
		directory: Directory
		generated: "project-resources.yaml"
		resources: ConfigMap: project: {
			metadata: {
				namespace: NAME
				labels:    Labels
			}
			data: {
				name: NAME
				owners: strings.Join([for O in Owners {O.email}], "\n")
				ownerAccess: P.ownerAccess
				ownerGroup:  Groups.owner.claim
			}
		}
	}).artifact,
]}
