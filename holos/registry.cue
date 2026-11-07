package holos

import "list"

// registry lists the platform's components in sync order. Each has a level in
// the stack, its priority (#Registration), and a cluster takes the stack up to
// standard, the optional entries it names (#Cluster.components, clusters.cue),
// the claims that select it and the bindings it takes (collections.cue).
// clusterRegistry, below, is that list for each cluster:
// platform/platform.cue renders it, and every entry in it gets an Argo CD
// Application (components/argocd-apps) whose sync wave is its index there,
// not here. The waves order the root Application's own syncs: when a cluster
// is bootstrapped it creates one Application, waits for it to be Synced and
// Healthy (argocd-cm's health check for Applications, components/argocd), then
// creates the next, and a later sync of the root, such as one adding a
// component, walks the same waves. Once created, each Application polls main
// and syncs on its own, so a later merge syncs the components it touches in
// parallel, and a component whose dependency is not ready yet relies on its
// sync retry. The order is also the order to apply components by hand in.
registry: [...#Registration]

// #Registration is one component in the registry.
#Registration: {
	// name is the component's name in deploy/ and in Argo CD.
	name: string
	// component is its directory under components/: its name, unless one
	// directory renders several components, as components/project renders
	// one per ProjectClaim and components/product-<product> one per binding
	// (collections.cue).
	component: string | *name
	// priority is the component's level in the stack, in Debian's Priority
	// vocabulary: required at the bottom, then important, then standard, and
	// optional at the top. A cluster takes the stack up to standard, plus the
	// optional entries it names (#Cluster.components): the cluster picks its
	// components, as a Debian machine picks its packages, and a component
	// never names clusters; only a claim does, by label. Nothing may depend on
	// a component above it in the stack, further up toward optional: that is
	// a layering violation (docs/glossary.md). Stack order is not sync order:
	// the registry's order is, so hello, standard, syncs before ceph-csi-rbd,
	// important.
	//
	// It has no default (Second_Cluster interview Q19): a forgotten field
	// that defaulted to optional would render nowhere with every check
	// passing. Left out, it fails cue vet, which says only that some
	// instances are incomplete; cue vet -c names the entry.
	priority!: "required" | "important" | "standard" | "optional"
	// parameters are the component's CUE tags, beside clusterName, which
	// every component gets (platform/platform.cue): project, for a
	// ProjectClaim's, and project and product, for a binding's.
	parameters: [string]: string
	// syncOptions are added to the Application's sync options, after the
	// ones every Application has.
	syncOptions: [...string]
	// ignoreDifferences are the Application's: fields Argo CD neither
	// reports out of sync nor heals, such as one a Job writes after the
	// sync.
	ignoreDifferences: [...{...}]
}

// #OptionalComponents are the names a cluster may list in
// #Cluster.components: the optional entries, but for the claims' and the
// bindings', which are the ones with a project parameter. A claim is optional
// too (#ProjectRegistrations), but it selects its clusters by label rather than
// being named by them (#Project.clusterSelector), and a binding follows its
// claim onto the clusters that take its products' components
// (#BindingRegistrations, clusterBindings), so naming either fails cue vet. A
// claim's atespace and route render only on a cluster that names both substrate
// and substrate-shim (AteGateway.servesClaims, components/substrate-shim.cue);
// on any other cluster it selects, the claim renders the rest of what it stands
// for. A product's components are names from this list too (productComponents,
// collections.cue).
#OptionalComponents: [
	for C in registry if C.priority == "optional" && C.parameters.project == _|_ {C.name},
]

// clusterRegistry is the registry as each cluster takes it, by cluster name,
// in the registry's order: every entry up to standard, and of the optional
// ones those the cluster names, the claims that select it and the bindings it
// takes (clusterProjects and clusterBindings, collections.cue). A cluster's sync
// waves are indexes into its own list, so an entry it does not take can never
// move them, and components/argocd-apps is the only place that reads the index.
//
// It is a map in the root, not a filter on Cluster, because the platform reads
// it too: Cluster is defined in components/component.cue, which the platform
// instance does not load, and the platform never gets the clusterName tag
// (tags.cue), so a filter on that would quietly read its default, treasury,
// for every cluster.
clusterRegistry: {
	for NAME, CLUSTER in clusters {
		let Taken = list.Concat([
			CLUSTER.components,
			[for PROJECT, _ in clusterProjects[NAME] {"project-\(PROJECT)"}],
			[for ENTRY, B in productBindings if clusterBindings[NAME][B.binding] != _|_ {ENTRY}],
		])
		(NAME): [
			for C in registry
			if C.priority != "optional" || list.Contains(Taken, C.name) {C},
		]
	}
}

registry: [
	// cilium is the CNI and kube-proxy replacement. Nothing else gets a pod
	// address until it is up.
	{name: "cilium", priority: "required"},
	// cilium-resources holds the Cilium custom resources: the LB IPAM pools,
	// the L2 announcement policy and the ambient kubelet probe policy. The
	// operator registers their CRDs when it starts, after cilium is synced,
	// so the dry run Argo CD makes before applying skips kinds it cannot
	// find yet.
	{
		name:     "cilium-resources"
		priority: "required"
		syncOptions: ["SkipDryRunOnMissingResource=true"]
	},
	// coredns replaces the CoreDNS Talos deploys, to own the Corefile.
	{name: "coredns", priority: "required"},
	// argocd syncs everything from git, itself included. It needs pod
	// networking and DNS to reach GitHub, and nothing else, so it comes
	// straight after them.
	{name: "argocd", priority: "required"},
	// gateway-api is the Gateway API CRDs, standard channel, at the release
	// Istio supports, installed ahead of Istio.
	{name: "gateway-api", priority: "important"},
	// cert-manager, its CRDs and its webhook.
	{name: "cert-manager", priority: "important"},
	// approver-policy approves cert-manager's CertificateRequests by policy,
	// in place of cert-manager's own approver: its CertificateRequestPolicy
	// CRD, its controller and its webhook. It needs only cert-manager's
	// CRDs, whose requests it watches.
	{name: "approver-policy", priority: "important"},
	// private-ca is the bootstrap Issuer, the root, the ClusterIssuer and the
	// CertificateRequestPolicies that let them sign. It needs cert-manager's
	// CRDs established and its controller running, and approver-policy's
	// CRD, so it comes after both.
	{name: "private-ca", priority: "important"},
	// trust-manager, its Bundle CRD and its webhook. Its webhook certificate
	// is a cert-manager Certificate, so it comes after cert-manager.
	{name: "trust-manager", priority: "important"},
	// private-ca-bundle is the Bundle that copies the root into every
	// namespace. It needs trust-manager's CRD and the root's Secret.
	{name: "private-ca-bundle", priority: "important"},
	// istio-base is Istio's CRDs and the istio-system namespace, ahead of
	// everything else of Istio's.
	{name: "istio-base", priority: "important"},
	// istiod is the mesh's control plane. It mounts the private-ca
	// ConfigMap, so it comes after private-ca-bundle.
	{name: "istiod", priority: "important"},
	// istio-cni and ztunnel are the ambient node agents. Both wait on istiod
	// for their configuration and certificates.
	{name: "istio-cni", priority: "important"},
	{name: "ztunnel", priority: "important"},
	// cloudnative-pg is the CloudNativePG operator, its CRDs and its
	// webhooks; each consumer writes its own Cluster. Its webhook
	// certificate is a cert-manager Certificate from the private-ca
	// ClusterIssuer, so it comes after private-ca.
	{name: "cloudnative-pg", priority: "important"},
	// external-secrets is the External Secrets operator, its CRDs and its
	// webhook; components generate their own secrets with it
	// (#GeneratedSecret). Its webhook certificate is a cert-manager
	// Certificate from the private-ca ClusterIssuer, so it comes after
	// private-ca.
	{name: "external-secrets", priority: "important"},
	// management-namespaces is the Secrets Manager's management organization
	// and project, seabank-org-platform and seabank-prj-platform
	// (<slug>-org-platform and <slug>-prj-platform, Brand), and the
	// RoleBinding that grants the server's secrets verbs in the project. A
	// consumer of a platform secret renders its per-namespace store's Role
	// and RoleBinding into the project, so every consumer comes after
	// this component, which needs nothing before it. It comes straight after
	// external-secrets, whose CRDs every store needs, so any component after
	// that can write one; it is not part of external-secrets, a chart whose
	// artifact drops invalid resources silently, nor of secrets-manager,
	// which comes too late.
	{name: "management-namespaces", priority: "important"},
	// ingress-gateway is the ingress Gateway, its wildcard certificate and
	// the routes of components that come before it. It needs the Gateway API
	// CRDs, the private-ca ClusterIssuer and istiod's istio GatewayClass.
	{name: "ingress-gateway", priority: "important"},
	// hello is the ambient echo service behind the gateway. It needs the node
	// agents and the Gateway.
	{name: "hello", priority: "standard"},
	// ceph-csi-rbd is the Ceph RBD driver and the default StorageClass,
	// ceph-rbd. It needs pod networking, the CRDs of external-secrets and the
	// management namespace, where bootstrap writes its key by hand and from
	// which its ExternalSecret copies it; it comes ahead of every component
	// that claims a volume.
	{name: "ceph-csi-rbd", priority: "important"},
	// local-path is the node-local fallback StorageClass, not the default.
	{name: "local-path", priority: "important"},
	// rustfs is the S3 store, RustFS standalone. It claims a ceph-rbd
	// volume and generates its keys with ExternalSecrets, so it comes after
	// ceph-csi-rbd and external-secrets; its Job registers the consumers'
	// buckets and users once RustFS is up.
	{name: "rustfs", priority: "standard"},
	// keycloak-operator is the Keycloak Operator, its CRDs and the keycloak
	// namespace. It needs only the mesh's node agents.
	{name: "keycloak-operator", priority: "standard"},
	// keycloak is the identity provider: its CloudNativePG cluster, its
	// generated Secrets, the Keycloak resource and its route. It needs the
	// CRDs of cloudnative-pg, external-secrets and keycloak-operator, a
	// ceph-rbd volume and the Gateway, so it comes after all of them.
	{name: "keycloak", priority: "standard"},
	// <slug>-controller is the platform controller, the software
	// holos-controller, from the holos-controller component
	// (PlatformController, components/keycloak.cue, which builds the same
	// name). It reconciles the realm's groups, memberships, users and
	// clients from keycloak.holos.run resources: its CRDs, its RBAC and its
	// manager. It needs only the mesh; its credential and resources are
	// keycloak-realm's, after it, so its CRDs are established first.
	{
		name:      "\(Brand.slug)-controller"
		priority:  "standard"
		component: "holos-controller"
	},
	// keycloak-realm is the realm default: the KeycloakRealmImport and its
	// generated Secrets, the platform controller's credential, the Instance, the
	// platform's groups and memberships, the Users of the people collection, and
	// the PostSync Job that writes
	// the private root into the Instance's caBundle (interview Q52). Argo CD
	// ignores the field it writes, which no render carries. The names are
	// PlatformController.instance's (components/keycloak.cue), which the
	// platform, rendering from here, does not load.
	{
		name:     "keycloak-realm"
		priority: "standard"
		ignoreDifferences: [{
			group:     "keycloak.holos.run"
			kind:      "Instance"
			name:      "default"
			namespace: "keycloak"
			jsonPointers: ["/spec/caBundle"]
		}]
	},
	// <slug>-authenticator is the platform authenticator, the software
	// holos-authenticator, from the holos-authenticator component
	// (PlatformAuthenticator, components/holos-authenticator.cue, which
	// builds the same name): the Kubernetes API at k8s.<domain> behind a
	// Keycloak login: its Backend CRD, the manager and its RBAC, the
	// impersonator and its grants, the Backend, and its own Gateway behind
	// the ingress Gateway's k8s listener, with the ext_authz policy, the
	// Lua and the TLS to the API server (components/holos-authenticator).
	// It needs istiod's extension provider, the k8s listener of
	// ingress-gateway, the private-ca ClusterIssuer and ConfigMap, and
	// Keycloak's issuer, so it comes after them. It comes straight after
	// keycloak-realm, whose users and groups it impersonates; its Backend
	// is a kind it installs, so the dry run skips it until the CRD is
	// established.
	{
		name:      "\(Brand.slug)-authenticator"
		priority:  "standard"
		component: "holos-authenticator"
		syncOptions: ["SkipDryRunOnMissingResource=true"]
	},
	// secrets-manager is the Bank of the Salish Sea Secrets Manager
	// (Brand.name): its Deployment, RBAC and route, and the platform
	// controller Client it logs in through, with the ReferenceGrant that
	// lets the Client name the Instance in keycloak. It needs the Client
	// CRD from the platform controller and the Instance from
	// keycloak-realm, so it comes after both. Its HTTPRoute is in its own
	// namespace, on the HTTPS listener, which takes routes from every
	// namespace, so it need not come before ingress-gateway. A consumer of a
	// platform secret need not come after it, only after
	// management-namespaces; but the secret must exist before the
	// consumer's ExternalSecret syncs, and it is made through this
	// component's UI, so on a new cluster a component earlier than this one
	// cannot get a platform secret by itself. The Ceph key is the exception:
	// bootstrap writes it with kubectl, before Argo CD.
	{name: "secrets-manager", priority: "standard"},
	// toolhive-crds is ToolHive's CRDs, from its toolhive-operator-crds
	// chart, which Argo CD neither prunes nor deletes; toolhive-operator is
	// its operator, which watches them, in toolhive-system; and toolhive is
	// the one MCP server, in its own namespace, with its OIDC and Cedar
	// configs, NetworkPolicies and route (components/toolhive.cue). The MCP
	// server needs Keycloak's realm, whose ID tokens it checks, the ingress
	// Gateway and trust-manager's private-ca bundle, and nothing after
	// them needs it. They come straight after secrets-manager, ahead of
	// substrate, quay and kagent, so a bootstrap holding at any of their
	// hand steps has ToolHive up already.
	{name: "toolhive-crds", priority: "optional"},
	{name: "toolhive-operator", priority: "optional"},
	{name: "toolhive", priority: "optional"},
	// substrate is Agent Substrate's control plane, rendered from the fork's
	// install tree in vendor/substrate (substrate.cue): its CRDs, the pod
	// certificate controller, the API server, the IdP, the controller, the
	// router, the egress gateway, the credential provider, atelet, its
	// CloudNativePG cluster and role Job, its generated passwords, the copy
	// of the RustFS keys, and the gVisor WorkerPool. It needs the CRDs of
	// cloudnative-pg, external-secrets and cert-manager, the private-ca
	// ClusterIssuer and the private-ca ConfigMap, a ceph-rbd volume, and the
	// bucket and keys from rustfs, so it comes after all of them; it reads
	// no platform secret, so it needs nothing of management-namespaces or
	// secrets-manager. Its WorkerPool and SandboxConfig are kinds whose CRDs
	// it installs, so the dry run skips them until they are established.
	//
	// It cannot be Healthy on a new cluster by itself: until the key pools
	// are created by hand with ate-setup (README.md, Substrate), the pods
	// that project them wait in ContainerCreating. It comes before quay,
	// which waits on a step by hand too, because its step needs only the
	// namespaces this sync creates and takes a minute, where quay's needs
	// Quay up and Keycloak; neither needs the other, and the demo actor's
	// image, which needs both, is pushed by hand afterwards.
	{
		name:     "substrate"
		priority: "optional"
		syncOptions: ["SkipDryRunOnMissingResource=true"]
	},
	// substrate-shim is the Istio shim in front of Substrate's router: its
	// own Gateway with a listener and certificate per atespace, behind the
	// ingress Gateway's ate listener, the Keycloak token and group policy,
	// the Lua that sets the actor from the host, and the mutual TLS to the
	// router. It needs the Gateway API CRDs, istiod, the private-ca
	// ClusterIssuer, ingress-gateway's ate listener, and substrate: its
	// gateway's pods project a certificate from Substrate's pod identity
	// signer, which waits on substrate's key pools, and its HTTPRoutes are
	// in substrate's namespace. So it comes straight after substrate.
	{name: "substrate-shim", priority: "optional"},
	// quay is the registry: its CloudNativePG cluster, Redis, the Quay
	// Deployment and route, its Keycloak Client, the copies of the RustFS
	// keys and of holos-controller's Quay credential, and on a cluster that
	// names substrate, the demo Organization and Repository holos-controller
	// makes in it. It needs the CRDs of
	// cloudnative-pg, external-secrets and holos-controller, the Instance
	// from keycloak-realm, the bucket and keys from rustfs and the
	// management namespace. It comes after secrets-manager, last of the
	// platform's own components, because it cannot be Healthy on a new
	// cluster by itself: the credential's ExternalSecret reports Degraded
	// until cmd/quay-bootstrap is run against the running Quay and writes
	// the platform secret it copies (README.md, Quay). Anything after it
	// waits on that by hand at a bootstrap: the projects, whose Quay
	// organizations need that credential anyway, and kagent, which waits on
	// a step of its own, and comes after them for that reason.
	{name: "quay", priority: "standard"},
	// The ProjectClaim collection's components, project-<name>, one per
	// claim in projects/ (collections.cue), on the clusters the claim
	// selects, each the project's namespace,
	// Keycloak groups, users and memberships, Quay organization, RBAC,
	// Argo CD AppProject and Application, and on a cluster that names
	// substrate and substrate-shim, Substrate atespace with its route through
	// the shim (components/project). They need
	// holos-controller's CRDs, the Instance from keycloak-realm, Quay's
	// credential from quay, and holos-authenticator, whose allowlist names
	// their owners. Where they render, their atespace Jobs need substrate's
	// API server and the NetworkPolicy that admits them, their ListenerSets
	// the shim's Gateway from substrate-shim, and their wildcards the
	// ClusterIssuer from private-ca and approver-policy to approve their own
	// policies. So they come after all of them.
	for R in #ProjectRegistrations {R},
	// kagent-crds is kagent's CRDs, from the fork's kagent-crds chart, which
	// Argo CD neither prunes nor deletes. It needs nothing, but comes
	// straight before kagent, whose chart writes objects of its kinds.
	{name: "kagent-crds", priority: "optional"},
	// kagent is kagent on Substrate (components/kagent): the fork's chart,
	// with its controller, UI, tool server and oauth2-proxy, and beside it
	// the namespace, the Keycloak Client, the role Job and its passwords in
	// Substrate's namespace, the connection strings, the copy of the
	// Anthropic key, the placeholder WorkerPool, the NetworkPolicies and the
	// route. It needs substrate's database, router, API server and worker
	// pool, which already trust its controller and carry its labels,
	// substrate-shim, which serves the kagent atespace, the Client CRD from
	// holos-controller and the Instance from keycloak-realm, the management
	// namespace, and kagent-crds.
	//
	// It cannot be Healthy on a new cluster by itself: the Anthropic key's
	// ExternalSecret reports Degraded until the key is written by hand,
	// through the Secrets Manager, as the platform secret anthropic-api-key
	// (README.md, kagent). So it comes after everything it needs and after
	// quay and the projects, which need nothing of it: at a bootstrap only
	// the root Application's own sync waits on the key, as it already waits
	// on quay's step.
	{name: "kagent", priority: "optional"},
	// The bindings' components, product-<product>-<claim>, one per binding and
	// product in bindings/ (collections.cue), on the clusters that take the
	// binding, each what the product renders for the claim that is not the
	// owner's to change. They need their claim's own entry, for the namespace,
	// the organization and the atespace, and the components their product
	// names, so they come after both: after every claim, and after kagent,
	// the last entry a product can name. Nothing comes after them but
	// argocd-apps, so none of them moves another component's wave, and each
	// waits on any step by hand that its components wait on.
	for R in #BindingRegistrations {R},
	// argocd-apps is the platform AppProject and the Application of every
	// component the cluster takes, its own included: its Application is the
	// root Application. It is last, so the root syncs every other Application
	// before it waits on itself.
	{name: "argocd-apps", priority: "required"},
]
