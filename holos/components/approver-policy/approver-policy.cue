package holos

import "encoding/yaml"

// approver-policy approves or denies every CertificateRequest in the cluster
// in place of cert-manager's own approver, which the cert-manager component
// turns off once the cluster enforces its webhooks. It decides by the
// CertificateRequestPolicies the private-ca component renders, beside the
// issuers they guard (README.md, "The private CA").
//
// v0.29.0, the latest stable, from Jetstack's OCI chart, with the image the
// chart names on quay.io, pinned by digest. It runs in cert-manager's
// namespace, as the chart expects: its RBAC and its webhook's CA Secret are
// there.
ApproverPolicyVersion: "v0.29.0"

let Webhook = webhookServices["cert-manager-approver-policy"]

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: Webhook.namespace
	chart: {
		name:    "oci://quay.io/jetstack/charts/cert-manager-approver-policy"
		version: ApproverPolicyVersion
		release: "cert-manager-approver-policy"
	}
	values: {
		// The CertificateRequestPolicy CRD is part of the chart's output and
		// of this component (the chart's default, stated). The chart's
		// crds.keep marks it helm.sh/resource-policy: keep, which only Helm
		// reads; the patch below keeps it for Argo CD.
		crds: enabled: true

		image: {
			tag:    ApproverPolicyVersion
			digest: "sha256:b516dba9e41d8e29957fa8f16479fb109741f7d3f418ef6aa2b47221dfdd5ef3"
		}
	}

	// The webhook serves a certificate it signs itself, from a CA it
	// keeps in Secret cert-manager/cert-manager-approver-policy-tls, for
	// cert-manager-approver-policy.cert-manager.svc only. The chart
	// renders that Secret empty, with the annotation that lets
	// cainjector read it, and approver-policy writes its data with an
	// update; Argo CD's server-side apply owns only the metadata, so the
	// two do not fight over it. cainjector copies the CA into the
	// configuration's caBundle, through the chart's
	// inject-ca-from-secret annotation, whether the configuration names
	// a Service or a URL. The API server dials the .svc name itself
	// through the Gateway (webhooks.cue).
	patches: [
		(#WebhookPatch & {
			kind:    "ValidatingWebhookConfiguration"
			name:    "cert-manager-approver-policy"
			service: Webhook.name
			webhooks: "policy.cert-manager.io": path: "/validate-policy-cert-manager-io-v1alpha1-certificaterequestpolicy"
		}).patch,
		// Argo CD neither prunes nor deletes the CRD. Deleting it deletes
		// every CertificateRequestPolicy, and with cert-manager's own
		// approver off every new request would then wait unapproved, so
		// removing or renaming this component would otherwise stop the
		// cluster's certificates renewing.
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
	]
}).artifact]
