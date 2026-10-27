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
	ReferenceGrant?: [_]:     rgv1.#ReferenceGrant
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
	// validation.
	ExternalSecret?: [_]: {apiVersion: "external-secrets.io/v1", ...}
	SecretStore?: [_]: {apiVersion: "external-secrets.io/v1", ...}
	Password?: [_]: {apiVersion: "generators.external-secrets.io/v1alpha1", ...}

	// trust-manager's Bundle has no generated CUE schema here either.
	Bundle?: [_]: {apiVersion: "trust.cert-manager.io/v1alpha1", ...}

	Gateway?: [_]: gwv1.#Gateway & {
		spec: gatewayClassName: string | *"istio"
	}
}
