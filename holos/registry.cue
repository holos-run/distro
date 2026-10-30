package holos

// registry lists the platform's components in sync order. Every cluster in
// clusters (clusters.cue) gets every component (platform/platform.cue), and
// every component gets an Argo CD Application (components/argocd-apps) whose
// sync wave is its index here. The waves order only the root Application
// creating the Applications, when a cluster is bootstrapped: it creates one,
// waits for it to report Healthy, then creates the next. Once created, each
// Application polls main and syncs on its own, so a later merge syncs the
// components it touches in parallel, and a component whose dependency is
// not ready yet relies on its sync retry. The order is also the order to
// apply components by hand in.
registry: [...#Registration]

// #Registration is one component in the registry.
#Registration: {
	// name is the component's name in deploy/ and in Argo CD.
	name: string
	// component is its directory under components/: its name, unless one
	// directory renders several components, as components/project renders
	// one per ProjectClaim (collections.cue).
	component: string | *name
	// parameters are the component's CUE tags, beside clusterName, which
	// every component gets (platform/platform.cue): project, for a
	// ProjectClaim's.
	parameters: [string]: string
	// syncOptions are added to the Application's sync options, after the
	// ones every Application has.
	syncOptions: [...string]
	// ignoreDifferences are the Application's: fields Argo CD neither
	// reports out of sync nor heals, such as one a Job writes after the
	// sync.
	ignoreDifferences: [...{...}]
}

registry: [
	// cilium is the CNI and kube-proxy replacement. Nothing else gets a pod
	// address until it is up.
	{name: "cilium"},
	// cilium-resources holds the Cilium custom resources: the LB IPAM pools,
	// the L2 announcement policy and the ambient kubelet probe policy. The
	// operator registers their CRDs when it starts, after cilium is synced,
	// so the dry run Argo CD makes before applying skips kinds it cannot
	// find yet.
	{
		name: "cilium-resources"
		syncOptions: ["SkipDryRunOnMissingResource=true"]
	},
	// coredns replaces the CoreDNS Talos deploys, to own the Corefile.
	{name: "coredns"},
	// argocd syncs everything from git, itself included. It needs pod
	// networking and DNS to reach GitHub, and nothing else, so it comes
	// straight after them.
	{name: "argocd"},
	// gateway-api is the Gateway API CRDs, standard channel, at the release
	// Istio supports, installed ahead of Istio.
	{name: "gateway-api"},
	// cert-manager, its CRDs and its webhook.
	{name: "cert-manager"},
	// approver-policy approves cert-manager's CertificateRequests by policy,
	// in place of cert-manager's own approver once the cluster enforces its
	// webhooks: its CertificateRequestPolicy CRD, its controller and its
	// webhook. It needs only cert-manager's CRDs, whose requests it watches.
	{name: "approver-policy"},
	// private-ca is the bootstrap Issuer, the root, the ClusterIssuer and the
	// CertificateRequestPolicies that let them sign. It needs cert-manager's
	// CRDs established and its controller running, and approver-policy's
	// CRD, so it comes after both.
	{name: "private-ca"},
	// trust-manager, its Bundle CRD and its webhook. Its webhook certificate
	// is a cert-manager Certificate, so it comes after cert-manager.
	{name: "trust-manager"},
	// private-ca-bundle is the Bundle that copies the root into every
	// namespace. It needs trust-manager's CRD and the root's Secret.
	{name: "private-ca-bundle"},
	// istio-base is Istio's CRDs and the istio-system namespace, ahead of
	// everything else of Istio's.
	{name: "istio-base"},
	// istiod is the mesh's control plane. It mounts the private-ca
	// ConfigMap, so it comes after private-ca-bundle.
	{name: "istiod"},
	// istio-cni and ztunnel are the ambient node agents. Both wait on istiod
	// for their configuration and certificates.
	{name: "istio-cni"},
	{name: "ztunnel"},
	// cloudnative-pg is the CloudNativePG operator, its CRDs and its
	// webhooks; each consumer writes its own Cluster. Its webhook
	// certificate is a cert-manager Certificate from the private-ca
	// ClusterIssuer, and its webhook's TLSRoute is in its namespace, so it
	// comes after private-ca and before ingress-gateway.
	{name: "cloudnative-pg"},
	// external-secrets is the External Secrets operator, its CRDs and its
	// webhook; components generate their own secrets with it
	// (#GeneratedSecret). Its webhook certificate is a cert-manager
	// Certificate from the private-ca ClusterIssuer, and its webhook's
	// TLSRoute is in its namespace, so it comes after private-ca and before
	// ingress-gateway.
	{name: "external-secrets"},
	// management-namespaces is the Secrets Manager's management organization
	// and project, holos-org-platform and holos-prj-platform, and the
	// RoleBinding that grants the server's secrets verbs in the project. A
	// consumer of a platform secret renders its per-namespace store's Role
	// and RoleBinding into holos-prj-platform, so every consumer comes after
	// this component, which needs nothing before it. It comes straight after
	// external-secrets, whose CRDs every store needs, so any component after
	// that can write one; it is not part of external-secrets, a chart whose
	// artifact drops invalid resources silently, nor of secrets-manager,
	// which comes too late.
	{name: "management-namespaces"},
	// ingress-gateway is the ingress Gateway, its wildcard certificate and
	// the routes of components that come before it. It needs the Gateway API
	// CRDs, the private-ca ClusterIssuer and istiod's istio GatewayClass.
	{name: "ingress-gateway"},
	// hello is the ambient echo service behind the gateway. It needs the node
	// agents and the Gateway.
	{name: "hello"},
	// ceph-csi-rbd is the Ceph RBD driver and the default StorageClass,
	// ceph-rbd. It needs pod networking, the CRDs of external-secrets and the
	// management namespace, where bootstrap writes its key by hand and from
	// which its ExternalSecret copies it; it comes ahead of every component
	// that claims a volume.
	{name: "ceph-csi-rbd"},
	// local-path is the node-local fallback StorageClass, not the default.
	{name: "local-path"},
	// rustfs is the S3 store, RustFS standalone. It claims a ceph-rbd
	// volume and generates its keys with ExternalSecrets, so it comes after
	// ceph-csi-rbd and external-secrets; its Job registers the consumers'
	// buckets and users once RustFS is up.
	{name: "rustfs"},
	// keycloak-operator is the Keycloak Operator, its CRDs and the keycloak
	// namespace. It needs only the mesh's node agents.
	{name: "keycloak-operator"},
	// keycloak is the identity provider: its CloudNativePG cluster, its
	// generated Secrets, the Keycloak resource and its route. It needs the
	// CRDs of cloudnative-pg, external-secrets and keycloak-operator, a
	// ceph-rbd volume and the Gateway, so it comes after all of them.
	{name: "keycloak"},
	// holos-controller reconciles the realm's groups, memberships, users and
	// clients from keycloak.holos.run resources: its CRDs, its RBAC and its
	// manager. It needs only the mesh; its credential and resources are
	// keycloak-realm's, after it, so its CRDs are established first.
	{name: "holos-controller"},
	// keycloak-realm is the realm holos: the KeycloakRealmImport and its
	// generated Secrets, holos-controller's credential, the Instance, the
	// platform's groups and memberships, and the PostSync Job that writes
	// the private root into the Instance's caBundle (interview Q52). Argo CD
	// ignores the field it writes, which no render carries. The names are
	// HolosController.instance's (components/keycloak.cue), which the
	// platform, rendering from here, does not load.
	{
		name: "keycloak-realm"
		ignoreDifferences: [{
			group:     "keycloak.holos.run"
			kind:      "Instance"
			name:      "holos"
			namespace: "keycloak"
			jsonPointers: ["/spec/caBundle"]
		}]
	},
	// holos-authenticator is the Kubernetes API at k8s.<domain> behind a
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
		name: "holos-authenticator"
		syncOptions: ["SkipDryRunOnMissingResource=true"]
	},
	// secrets-manager is the Holos Secrets Manager: its Deployment, RBAC and
	// route, and the holos-controller Client it logs in through, with the
	// ReferenceGrant that lets the Client name the Instance in keycloak. It
	// needs the Client CRD from holos-controller and the Instance from
	// keycloak-realm, so it comes after both. Its HTTPRoute is in its own
	// namespace, on the HTTPS listener, which takes routes from every
	// namespace, so it need not come before ingress-gateway. A consumer of a
	// platform secret need not come after it, only after
	// management-namespaces; but the secret must exist before the
	// consumer's ExternalSecret syncs, and it is made through this
	// component's UI, so on a new cluster a component earlier than this one
	// cannot get a platform secret by itself. The Ceph key is the exception:
	// bootstrap writes it with kubectl, before Argo CD.
	{name: "secrets-manager"},
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
		name: "substrate"
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
	{name: "substrate-shim"},
	// quay is the registry: its CloudNativePG cluster, Redis, the Quay
	// Deployment and route, its Keycloak Client, the demo Organization and
	// Repository holos-controller makes in it, and the copies of the RustFS
	// keys and of holos-controller's Quay credential. It needs the CRDs of
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
	{name: "quay"},
	// The ProjectClaim collection's components, project-<name>, one per
	// claim in projects/ (collections.cue), each the project's namespace,
	// Keycloak groups, users and memberships, Quay organization, RBAC and
	// Argo CD AppProject and Application (components/project). They need
	// holos-controller's CRDs, the Instance from keycloak-realm, Quay's
	// credential from quay, and holos-authenticator, whose allowlist names
	// their owners, so they come after all of them. None is in the
	// repository's tree: the collection is empty until a pull request adds
	// a claim (interview Q67).
	for R in #ProjectRegistrations {R},
	// kagent-crds is kagent's CRDs, from the fork's kagent-crds chart, which
	// Argo CD neither prunes nor deletes. It needs nothing, but comes
	// straight before kagent, whose chart writes objects of its kinds.
	{name: "kagent-crds"},
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
	// (README.md, kagent). So it comes last before argocd-apps, after
	// everything it needs and after quay and the projects, which need
	// nothing of it: at a bootstrap only the root Application's own sync
	// waits on the key, as it already waits on quay's step.
	{name: "kagent"},
	// argocd-apps is the platform AppProject and every component's
	// Application, its own included: its Application is the root Application.
	// It is last, so the root syncs every other Application before it waits
	// on itself.
	{name: "argocd-apps"},
]
