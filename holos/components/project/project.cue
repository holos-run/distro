package holos

import (
	"encoding/json"
	"strings"
)

// project renders one ProjectClaim, projects.<project> (projects/), as the
// component project-<project>: the registry adds one per claim, each from
// this directory with the parameter project (collections.cue), a cluster
// takes the claims that select it (clusterProjects), and argocd-apps gives
// each an Application in the platform AppProject. The claim is a few lines of
// CUE, and this is everything it stands for, ported from aavis-ops' project
// component:
//
//   - the project's namespace, named for it, in the mesh;
//   - its owner, editor and viewer groups in the realm, the user of each of
//     its owners, editors and viewers, and their membership in the groups;
//   - its Quay organization, with a team synced from each group;
//   - the RoleBinding that gives the owner group ownerAccess, admin by
//     default, in the namespace, and nowhere else;
//   - its Argo CD AppProject, confined to the namespace, and its
//     Application, which syncs the project's own directory in deploy/;
//   - on a cluster that names substrate and substrate-shim, its Substrate
//     atespace, named for it, and the atespace's route through the Substrate
//     shim, https://<actor>.<project>.ate.<domain> (Atespace, below);
//   - on a cluster where a product is bound to it, its zone on the ingress
//     Gateway, *.<project>.<domain>, where the products have their hostnames:
//     a ListenerSet and a wildcard, with the wildcard's own approval (Zone,
//     below).
//
// The owner group's claim and the owners' usernames reach
// holos-authenticator's allowlist from collections.cue, so the same
// definition names the group the RoleBinding binds and the group the
// authenticator forwards.
//
// No Keycloak client: aavis-ops makes one per project only so that Quay
// teams can sync from its client roles, and Quay here syncs teams from the
// full group paths in the groups claim (interview Q65). No Secrets Manager
// project, seabank-prj-<project>, yet (Q64). No ResourceQuota, and no RBAC
// for the editor and viewer groups, which nothing in Kubernetes binds: their
// members reach the project's Quay organization, and what a product bound to the
// claim opens to them, such as the Planboard's board, and nothing else of it, and
// neither group joins the allowlist (#ProjectOwnerGroupClaims, collections.cue).
//
// Every kind's CRD comes from an earlier component: Group, User,
// GroupMembership, Organization and the security.holos.run ReferenceGrant
// from holos-controller, AppProject and Application from argocd, Certificate
// from cert-manager, CertificateRequestPolicy from approver-policy,
// ListenerSet and HTTPRoute from gateway-api, AuthorizationPolicy from
// istio-base. The Instance the Keycloak resources name is keycloak-realm's,
// and the Quay credential the Organization is reconciled with is quay's copy
// in the platform controller's namespace, which the Organization names.

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

// Claimed is the claim's map of each role (#ProjectRoles).
let Claimed = {
	owner:  P.owners
	editor: P.editors
	viewer: P.viewers
}

// Members are the claim's members by role and then email, each checked against
// the realm's people (Projects.people, Projects.usernames and Projects.#Person),
// so a member whose username is another person's, who is one of the platform's
// people under another username, or who is a platform service user, fails the
// render, in whichever role they are named. The checks are folded into email,
// which the role group's membership and the ConfigMap always render, so they
// hold for a member with no User too. platform is whether Keycloak already has
// them, and person whether they are in the people collection on this cluster,
// whose User keycloak-realm renders; neither has a User rendered here.
let Members = {
	for ROLE in #ProjectRoles {
		(ROLE): {
			for EMAIL, O in Claimed[ROLE] {
				(EMAIL): {
					let USERNAME = O.username & Projects.usernames[EMAIL] & Projects.#Person
					username: USERNAME
					email:    EMAIL & Projects.people[USERNAME].email
					platform: Projects.people[USERNAME].platform
					person:   Projects.people[USERNAME].person
				}
			}
		}
	}
}

// Atespace is the claim's atespace on the Substrate shim (AteGateway.claimed),
// on a cluster that serves it (AteGateway.servesClaims); on any other it has no
// entry there and is read nowhere. An atespace is an object in Substrate's API,
// not in Kubernetes, so it cannot be declared here; the Job below makes it.
// What can be is rendered beside the claim's other objects: the shim's half of
// the atespace, in substrate-shim and ate-system, stays in this component's
// Application.
// Between Applications that already exist, each syncing on its own, a broken
// claim holds back only its own (interview Q66). During a root sync, which
// walks the waves, it holds back the wave after it too, as any component does.
//
// No pool is named anywhere: an actor runs on the platform's gVisor pool
// (Substrate.workerPool) unless its template says otherwise, so the claim
// needs no reference to it, and a project cannot have a pool of its own,
// since a pool's workers need the privileged Pod Security level.
let Atespace = AteGateway.claimed[NAME]
let S = Substrate
let AG = AteGateway

// Zone is the claim's zone on the ingress Gateway, *.<project>.<domain>
// (IngressGateway.#Claim), on a cluster where the claim has a binding, and
// otherwise bottom, which the block that renders it tests for.
let IG = IngressGateway
let Zone = IG.claimed[NAME]

// Bound is whether the claim has a binding on this cluster (clusterBindings,
// collections.cue), and KeycloakKinds the kinds of keycloak.holos.run the
// claim's namespace may make in the realm (the ReferenceGrant, below): the
// claim's own Group, User and GroupMembership, and, where it is bound,
// Client, which a bound product makes for its login, as Planboard's does
// (components/product-planboard). Only there, so a cluster with no binding
// renders as it did (Second_Cluster Q6).
let Bound = len([for B in clusterBindings[Cluster.name] if B.project == NAME {B}]) > 0
let KeycloakKinds = ["Group", "User", "GroupMembership", if Bound {"Client"}]

// ProjectClient is the ServiceAccount the claim makes in its namespace, the
// one principal of the atespace's access policy. A token for it owns this
// atespace and nothing else, so an owner of the project, who may mint one,
// gets no more than the claim gave them.
let ProjectClient = "system:serviceaccount:\(NAME):\(S.client.serviceAccount)"

// SetupDir is where the Job's pod has its credential (#AteAPIJob).
let SetupDir = S.atespaceSetup.dir

// SetupScript calls the two RPCs kubectl ate create atespace and kubectl ate
// create access-policy do. grpcurl exits with 64 plus a call's gRPC status
// code, so 70 is AlreadyExists: each call succeeds once, and on every later
// sync of the claim changes nothing. That is also why a policy changed through
// the API, by the atespace's owner or the platform's, stays as it was, and why
// a claim on the name of an atespace Substrate already has inherits it, with
// its actors and whatever policy it has, which may not bind ProjectClient
// (README.md, Projects). Anything else fails the Job, and with it the sync.
let SetupScript = """
	set -eu
	ATE_TOKEN=$(cat \(SetupDir)/token)
	export ATE_TOKEN

	call() {
	  status=0
	  grpcurl -cacert \(SetupDir)/ca.pem -max-time 30 \\
	    -expand-headers -H 'authorization: Bearer ${ATE_TOKEN}' \\
	    -d "$2" \(S.api.host):\(S.api.port) \(S.api.service)/"$1" || status=$?
	  case "$status" in
	  0) echo "$1: created" ;;
	  70) echo "$1: already exists" ;;
	  *) exit "$status" ;;
	  esac
	}

	call CreateAtespace '\(json.Marshal({atespace: metadata: name: NAME}))'
	call CreateAtespaceAccessPolicy '\(json.Marshal(SetupPolicy))'
	"""

// SetupPolicy is the CreateAtespaceAccessPolicy request: a policy's name is
// always default, and its members are principals as kubectl ate's manifests
// write them, with the user: prefix.
let SetupPolicy = {
	atespace: name: NAME
	accessPolicy: {
		metadata: name: "default"
		bindings: [{
			role: "owner"
			members: ["user:\(ProjectClient)"]
		}]
	}
}

// Directory is the project's own directory in deploy/ (#ProjectDirectory),
// which its Application syncs: the second artifact. It holds only what this
// component and the products bound to the claim render: the render removes
// deploy/clusters first, so a file put there by hand would be gone at the next
// render, and CI would fail the pull request that committed it.
let Directory = (#ProjectDirectory & {project: NAME}).path

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
			// realm (README.md, Removing a project). Only the owner group is
			// bound to anything in Kubernetes; editor and viewer sync Quay
			// teams. Their members are the claim's, below, and whoever was
			// added in Keycloak by hand, whom the claim leaves alone.
			for ROLE, G in Groups {
				Group: (G.resource): {
					metadata: {
						namespace: NAME
						labels:    Labels
					}
					spec: {
						path:        G.path
						instanceRef: PlatformController.instance
					}
				}
			}

			// Each member's user, unless Keycloak already has them as one of
			// the platform's people, as jeff, whom the realm import creates, or
			// they are in the people collection on this cluster, whose User is
			// keycloak-realm's: holos-controller finds a member by email, so the
			// membership needs no User of the claim's. No password: it is set in
			// Keycloak by hand (README.md, Projects). adopt, because one person
			// may be in several projects, each with its own resource for them, and
			// Orphan, because a person is not a project's to delete: removing a
			// claim, or one of its members, leaves the user and their password in
			// the realm, and takes them only out of the group. Someone in two
			// roles is one user, and the same fields here unify to one resource.
			for MEMBERS in Members for O in MEMBERS if !O.platform if !O.person {
				User: (O.username): {
					metadata: {
						namespace: NAME
						labels:    Labels
					}
					spec: {
						email:          O.email
						username:       O.username
						instanceRef:    PlatformController.instance
						adopt:          true
						deletionPolicy: "Orphan"
					}
				}
			}

			// The members in their role's group. The owner group's membership
			// always renders and needs at least one member, so a claim with no
			// owners fails the render rather than make a project nobody may use.
			// An editor or viewer role nobody is named in renders none, so a
			// claim that sets neither map renders as it did. Emptying a map
			// removes the resource, and the controller's finalizer then takes
			// everyone it added out of the group, since deletionPolicy is unset,
			// as it does when one email leaves the map (README.md, Editors and
			// viewers).
			for ROLE, MEMBERS in Members if ROLE == "owner" || len(MEMBERS) > 0 {
				GroupMembership: (Groups[ROLE].resource): {
					metadata: {
						namespace: NAME
						labels:    Labels
					}
					spec: {
						instanceRef: PlatformController.instance
						groupRef: name: Groups[ROLE].resource
						members: [for O in MEMBERS {email: O.email}] & [_, ...]
					}
				}
			}

			// The Keycloak resources above, and a bound product's Client,
			// name the Instance in keycloak, another namespace, which
			// holos-controller allows only with a ReferenceGrant there, from
			// these kinds (KeycloakKinds) in the project's namespace to that
			// one Instance. Nothing else in the namespace may create or change
			// one: the admin ClusterRole the owners hold has no write verb on
			// holos-controller's kinds (only get, list and watch on
			// GroupMemberships, which the controller's
			// groupmembership-viewer-role aggregates to view), and the
			// project's AppProject refuses them. Wave -1, so it exists before
			// the resources that need it: a Group reconciled first reports
			// ReferenceNotGranted until its retry. It must also outlive them:
			// their finalizers need it to reach the Instance (README.md,
			// Removing a project).
			ReferenceGrant: "project-\(NAME)": {
				apiVersion: "security.holos.run/v1alpha1"
				metadata: {
					namespace: PlatformController.instance.namespace
					labels:    Labels
					annotations: "argocd.argoproj.io/sync-wave": "-1"
				}
				spec: {
					from: [for KIND in KeycloakKinds {
						group:     "keycloak.holos.run"
						kind:      KIND
						namespace: NAME
					}]
					to: [{
						group: "keycloak.holos.run"
						kind:  "Instance"
						name:  PlatformController.instance.name
					}]
				}
			}

			// The project's Quay organization, named for it, with a team synced
			// from each of its groups by claim, and platformowners, as every
			// organization has (Quay.ownersTeam). In the project's namespace:
			// holos-controller reads its Quay credential from its own namespace
			// whatever namespace names it, so the credential is not copied
			// here; credentialsSecretRef names the copy there, as the CRD's
			// default is the upstream name (Quay.credentials). Orphan, as demo is, so removing the claim leaves the
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
					email:          "quay+\(NAME)@\(Cluster.site.privateDomain)"
					deletionPolicy: "Orphan"
					credentialsSecretRef: name: Quay.credentials.controller
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

			// Everything of the atespace, on a cluster that serves it
			// (AteGateway.servesClaims). Elsewhere the claim is the objects
			// outside this block, which need nothing of Substrate or the shim.
			if AG.servesClaims {
				// Its pods may reach Substrate's API, whose NetworkPolicy reads
				// the label; what they may do there is the atespace's access
				// policy.
				Namespace: (NAME): metadata: labels: S.api.access

				// The principal of the atespace's access policy (ProjectClient).
				// This is not the ate-client ksa, the one in ate-system, which is a
				// global owner: only the name is the same, and kubectl ate's
				// default is what the name is for.
				ServiceAccount: (S.client.serviceAccount): metadata: {
					namespace: NAME
					labels:    Labels
				}

				// The atespace and its access policy, made through Substrate's API.
				//
				// #AteAPIJob holds where it runs, under what credential, and why,
				// and what a failure does. This one runs on every sync of the
				// claim, and the ServiceAccount in the policy need not exist yet.
				Job: "atespace-\(NAME)": (#AteAPIJob & {
					labels: Labels
					script: SetupScript
				}).job

				// The claim's own approval for its wildcard, this one name from the
				// private CA, in the shim's namespace, and no CA. Not an entry in
				// PrivateCA.requesters: that would reach the cluster on private-ca's
				// sync, which nothing orders against this one, and a request denied
				// first waits on cert-manager's back-off. Wave -1, and Argo CD's
				// health check for the kind holds the next wave until
				// approver-policy reports it Ready (components/argocd), so the policy
				// is in place before the Certificate is.
				//
				// One policy that applies and allows a request is enough, so
				// private-ca-substrate-shim, which does not list the name, and
				// deny-all do not stand in its way. The name is checked to be within
				// the root's subtrees, as an entry in PrivateCA.requesters is.
				CertificateRequestPolicy: "project-\(NAME)": {
					metadata: {
						labels: Labels
						annotations: "argocd.argoproj.io/sync-wave": "-1"
					}
					spec: {
						allowed: {
							dnsNames: (#Exactly & {names: [Atespace.hostname & PrivateCA.#Within]}).out
							isCA: false
						}
						selector: {
							issuerRef: PrivateCA.issuerRef
							namespace: matchNames: [AG.namespace]
						}
					}
				}

				// cert-manager's controller may use that one policy, as it may the
				// platform's (components/private-ca). Without this the policy does
				// not apply to the request, and deny-all denies it.
				ClusterRole: "approver-policy:project-\(NAME)": {
					metadata: {
						labels: Labels
						annotations: "argocd.argoproj.io/sync-wave": "-1"
					}
					rules: [{
						apiGroups: ["policy.cert-manager.io"]
						resources: ["certificaterequestpolicies"]
						verbs: ["use"]
						resourceNames: ["project-\(NAME)"]
					}]
				}
				ClusterRoleBinding: "approver-policy:project-\(NAME)": {
					metadata: {
						labels: Labels
						annotations: "argocd.argoproj.io/sync-wave": "-1"
					}
					roleRef: {
						apiGroup: "rbac.authorization.k8s.io"
						kind:     "ClusterRole"
						name:     "approver-policy:project-\(NAME)"
					}
					subjects: [{
						kind:      "ServiceAccount"
						name:      PrivateCA.certManager.name
						namespace: PrivateCA.certManager.namespace
					}]
				}

				// The atespace's wildcard, in the shim's namespace.
				Certificate: "\(Atespace.name)-wildcard": {
					metadata: {
						namespace: AG.namespace
						labels:    Labels
					}
					spec: Atespace.certificate & {dnsNames: [Atespace.hostname]}
				}

				// The atespace's listener on the shim's Gateway, which allows
				// ListenerSets from its own namespace.
				ListenerSet: "project-\(NAME)": {
					metadata: {
						namespace: AG.namespace
						labels:    Labels
					}
					spec: {
						parentRef: {
							group: "gateway.networking.k8s.io"
							kind:  "Gateway"
							name:  AG.name
						}
						listeners: [Atespace.listener]
					}
				}

				// The route to the router on that listener, in the router's
				// namespace, as the platform's atespaces' are, so it needs no
				// ReferenceGrant.
				HTTPRoute: "\(AG.name)-\(NAME)": {
					metadata: {
						namespace: S.namespace
						labels:    Labels
					}
					spec: {
						parentRefs: [{
							group:       "gateway.networking.k8s.io"
							kind:        "ListenerSet"
							namespace:   AG.namespace
							name:        "project-\(NAME)"
							sectionName: Atespace.listener.name
						}]
						rules: [{backendRefs: [{name: S.router.name, port: S.router.port}]}]
					}
				}

				// The atespace's rule, on the shim's Gateway. A policy of its own
				// rather than a rule in the Gateway's ate, so that the claim stays
				// in this Application: ALLOW policies on a Gateway add up, and no
				// other claim's rule, or the platform's, reads this one.
				AuthorizationPolicy: "project-\(NAME)": {
					metadata: {
						namespace: AG.namespace
						labels:    Labels
					}
					spec: {
						targetRefs: [{
							group: "gateway.networking.k8s.io"
							kind:  "Gateway"
							name:  AG.name
						}]
						action: "ALLOW"
						rules: [Atespace.rule]
					}
				}
			}

			// The claim's zone on the ingress Gateway, *.<claim>.<domain>, on
			// a cluster where it has a binding (IngressGateway.claimed), and
			// on no other. Here rather than in a product's component because a
			// second product bound to the claim has its hostname in the same
			// zone, and shares the listener and the certificate. The pattern
			// is the atespace's on the shim, above, in istio-ingress.
			if Zone != _|_ {
				// The claim's own approval for the zone's wildcard, this one
				// name from the private CA, in the ingress Gateway's namespace,
				// and no CA, at wave -1, for the reasons the atespace's has
				// (above). private-ca-istio-ingress does not list the name and
				// need not. Its name, and the zone's other objects', is not the
				// atespace's (IngressGateway.#Claim.resource).
				CertificateRequestPolicy: (Zone.resource): {
					metadata: {
						labels: Labels
						annotations: "argocd.argoproj.io/sync-wave": "-1"
					}
					spec: {
						allowed: {
							dnsNames: (#Exactly & {names: [Zone.hostname & PrivateCA.#Within]}).out
							isCA: false
						}
						selector: {
							issuerRef: PrivateCA.issuerRef
							namespace: matchNames: [IG.namespace]
						}
					}
				}

				// cert-manager's controller may use that one policy.
				ClusterRole: "approver-policy:\(Zone.resource)": {
					metadata: {
						labels: Labels
						annotations: "argocd.argoproj.io/sync-wave": "-1"
					}
					rules: [{
						apiGroups: ["policy.cert-manager.io"]
						resources: ["certificaterequestpolicies"]
						verbs: ["use"]
						resourceNames: [Zone.resource]
					}]
				}
				ClusterRoleBinding: "approver-policy:\(Zone.resource)": {
					metadata: {
						labels: Labels
						annotations: "argocd.argoproj.io/sync-wave": "-1"
					}
					roleRef: {
						apiGroup: "rbac.authorization.k8s.io"
						kind:     "ClusterRole"
						name:     "approver-policy:\(Zone.resource)"
					}
					subjects: [{
						kind:      "ServiceAccount"
						name:      PrivateCA.certManager.name
						namespace: PrivateCA.certManager.namespace
					}]
				}

				// The zone's wildcard, in the ingress Gateway's namespace, where
				// the listener reads its Secret.
				Certificate: (Zone.resource): {
					metadata: {
						namespace: IG.namespace
						labels:    Labels
					}
					spec: Zone.certificate & {dnsNames: [Zone.hostname]}
				}

				// The zone's listener on the ingress Gateway, which allows
				// ListenerSets from its own namespace on a cluster with a
				// binding (IngressGateway.listenerSets). Its routes are the
				// bound products', in the claim's namespace (Zone.parentRef).
				ListenerSet: (Zone.resource): {
					metadata: {
						namespace: IG.namespace
						labels:    Labels
					}
					spec: {
						parentRef: {
							group: "gateway.networking.k8s.io"
							kind:  "Gateway"
							name:  IG.name
						}
						listeners: [Zone.listener]
					}
				}
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

	// The project's own directory, which its Application syncs. It holds
	// the one ConfigMap project, describing the claim, so the Application has
	// something to be Synced and Healthy with, beside what the products bound
	// to the claim leave to its owner (#ProductComponent). A project's own
	// manifests are future work: they would have to be rendered from CUE here,
	// or live outside deploy/clusters, since this directory is rewritten by
	// every render.
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
				owners: strings.Join([for O in Members.owner {O.email}], "\n")
				ownerAccess: P.ownerAccess
				ownerGroup:  Groups.owner.claim
				if len(Members.editor) > 0 {
					editors: strings.Join([for O in Members.editor {O.email}], "\n")
				}
				if len(Members.viewer) > 0 {
					viewers: strings.Join([for O in Members.viewer {O.email}], "\n")
				}
			}
		}
	}).artifact,
]}
