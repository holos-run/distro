package holos

import (
	corev1 "k8s.io/api/core/v1"
	appsv1 "k8s.io/api/apps/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	batchv1 "k8s.io/api/batch/v1"

	ci "cert-manager.io/clusterissuer/v1"
	rgv1 "gateway.networking.k8s.io/referencegrant/v1beta1"
	certv1 "cert-manager.io/certificate/v1"
	issuer "cert-manager.io/issuer/v1"
	hrv1 "gateway.networking.k8s.io/httproute/v1"
	tlsv1 "gateway.networking.k8s.io/tlsroute/v1"
	gwv1 "gateway.networking.k8s.io/gateway/v1"
	app "argoproj.io/application/v1alpha1"
	ap "argoproj.io/appproject/v1alpha1"
)

#Resources: {
	[Kind=string]: [InternalLabel=string]: {
		kind: Kind
		metadata: name: string | *InternalLabel
	}

	Application?: [_]:        app.#Application
	AppProject?: [_]:         ap.#AppProject
	Certificate?: [_]:        certv1.#Certificate
	ClusterIssuer?: [_]:      ci.#ClusterIssuer
	ClusterRole?: [_]:        rbacv1.#ClusterRole
	ClusterRoleBinding?: [_]: rbacv1.#ClusterRoleBinding
	ConfigMap?: [_]:          corev1.#ConfigMap
	CronJob?: [_]:            batchv1.#CronJob
	Deployment?: [_]:         appsv1.#Deployment
	HTTPRoute?: [_]:          hrv1.#HTTPRoute
	Job?: [_]:                batchv1.#Job
	Namespace?: [_]:          corev1.#Namespace
	Role?: [_]:               rbacv1.#Role
	RoleBinding?: [_]:        rbacv1.#RoleBinding
	Issuer?: [_]:             issuer.#Issuer
	Secret?: [_]:             corev1.#Secret
	Service?: [_]:            corev1.#Service
	ServiceAccount?: [_]:     corev1.#ServiceAccount
	StatefulSet?: [_]:        appsv1.#StatefulSet
	TLSRoute?: [_]:           tlsv1.#TLSRoute

	// Cilium's CRDs have no generated CUE schema here; these entries pin
	// the API version and leave the rest to the API server's validation.
	CiliumClusterwideNetworkPolicy?: [_]: {apiVersion: "cilium.io/v2", ...}
	CiliumL2AnnouncementPolicy?: [_]: {apiVersion: "cilium.io/v2alpha1", ...}
	CiliumLoadBalancerIPPool?: [_]: {apiVersion: "cilium.io/v2", ...}

	// External Secrets' generated schemas here are from 0.10, which served
	// v1beta1; 2.x serves only v1, and generators v1alpha1. These entries
	// pin the served API versions and leave the rest to the API server's
	// validation. metadata is opened too: the pattern above closes it to
	// name alone, and these kinds are namespaced, so without it a
	// #GeneratedSecret's resources fail to unify with a component's own
	// #Resources and #HelmArtifact silently drops them all. Every generator
	// kind #GeneratedSecret accepts gets the same entry.
	ExternalSecret?: [_]: {apiVersion: "external-secrets.io/v1", metadata: {...}, ...}
	SecretStore?: [_]: {apiVersion: "external-secrets.io/v1", metadata: {...}, ...}
	for K in #GeneratorKinds {
		(K)?: [_]: {apiVersion: "generators.external-secrets.io/v1alpha1", metadata: {...}, ...}
	}

	// trust-manager's Bundle has no generated CUE schema here either, nor
	// approver-policy's CertificateRequestPolicy, v1alpha1, the one version
	// its v0.29.0 CRD serves (components/approver-policy). Both are
	// cluster-scoped.
	Bundle?: [_]: {apiVersion: "trust.cert-manager.io/v1alpha1", ...}
	CertificateRequestPolicy?: [_]: {apiVersion: "policy.cert-manager.io/v1alpha1", ...}

	// Nor do NetworkPolicy, CloudNativePG's Cluster or the Keycloak
	// Operator's Keycloak and KeycloakRealmImport. All are namespaced, so
	// metadata is opened as it is for External Secrets' kinds above. The
	// Keycloak kinds' version is the storage version of the 26.8.1 CRDs;
	// v2alpha1 is deprecated.
	NetworkPolicy?: [_]: {apiVersion: "networking.k8s.io/v1", metadata: {...}, ...}
	Cluster?: [_]: {apiVersion: "postgresql.cnpg.io/v1", metadata: {...}, ...}
	Keycloak?: [_]: {apiVersion: "k8s.keycloak.org/v2beta1", metadata: {...}, ...}
	KeycloakRealmImport?: [_]: {apiVersion: "k8s.keycloak.org/v2beta1", metadata: {...}, ...}

	// holos-controller's keycloak.holos.run and quay.holos.run kinds,
	// v1alpha1, the one version its 0.22.0 CRDs serve
	// (components/holos-controller). Namespaced too.
	Instance?: [_]: {apiVersion: "keycloak.holos.run/v1alpha1", metadata: {...}, ...}
	Group?: [_]: {apiVersion: "keycloak.holos.run/v1alpha1", metadata: {...}, ...}
	GroupMembership?: [_]: {apiVersion: "keycloak.holos.run/v1alpha1", metadata: {...}, ...}
	User?: [_]: {apiVersion: "keycloak.holos.run/v1alpha1", metadata: {...}, ...}
	Client?: [_]: {apiVersion: "keycloak.holos.run/v1alpha1", metadata: {...}, ...}
	Organization?: [_]: {apiVersion: "quay.holos.run/v1alpha1", metadata: {...}, ...}
	Repository?: [_]: {apiVersion: "quay.holos.run/v1alpha1", metadata: {...}, ...}

	// Istio's AuthorizationPolicy, which ztunnel enforces at L4 for a
	// policy that selects ambient pods. Namespaced too.
	AuthorizationPolicy?: [_]: {apiVersion: "security.istio.io/v1", metadata: {...}, ...}

	// The rest of the Substrate shim's Istio policy (components/substrate-shim):
	// the RequestAuthentication and the DestinationRule at the versions
	// Istio 1.31 stores, and the TrafficExtension, which is served only as
	// v1alpha1. Namespaced too.
	RequestAuthentication?: [_]: {apiVersion: "security.istio.io/v1", metadata: {...}, ...}
	DestinationRule?: [_]: {apiVersion: "networking.istio.io/v1", metadata: {...}, ...}
	TrafficExtension?: [_]: {apiVersion: "extensions.istio.io/v1alpha1", metadata: {...}, ...}

	// holos-authenticator's Backend, authenticator.holos.run/v1alpha1, the
	// one version its 0.21.0 CRD serves (components/holos-authenticator).
	// Namespaced too.
	Backend?: [_]: {apiVersion: "authenticator.holos.run/v1alpha1", metadata: {...}, ...}

	// Substrate's WorkerPool, ate.dev/v1, the one version its CRD serves
	// (components/substrate). Namespaced too.
	WorkerPool?: [_]: {apiVersion: "ate.dev/v1", metadata: {...}, ...}

	// ReferenceGrant is two kinds of one name: the Gateway API's, the
	// default, and holos-controller's security.holos.run one, which
	// authorizes a reference from another namespace to an Instance or a
	// Group and is chosen by its apiVersion. Resources are keyed by kind
	// alone, so both share this entry.
	ReferenceGrant?: [_]: *rgv1.#ReferenceGrant | {apiVersion: "security.holos.run/v1alpha1", metadata: {...}, ...}

	Gateway?: [_]: gwv1.#Gateway & {
		spec: gatewayClassName: string | *"istio"
	}
}

// #GeneratorKinds are the namespaced generator kinds of
// generators.external-secrets.io that ESO 2.14 serves, the kinds
// #GeneratedSecret (components/generated-secret.cue) accepts.
#GeneratorKinds: ["ACRAccessToken", "BeyondtrustWorkloadCredentialsDynamicSecret", "CloudsmithAccessToken", "ECRAuthorizationToken", "Fake", "GCRAccessToken", "GithubAccessToken", "GitlabDeployToken", "Grafana", "MFA", "Password", "QuayAccessToken", "SSHKey", "STSSessionToken", "UUID", "VaultDynamicSecret", "Webhook"]
