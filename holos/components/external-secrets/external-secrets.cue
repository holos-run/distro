package holos

// external-secrets is the External Secrets operator, its CRDs and its
// webhook. It renders no SecretStore and no ExternalSecret of its own: a
// component that needs a secret generated in the cluster renders one with
// #GeneratedSecret (components/generated-secret.cue), and the stores that
// read from outside the cluster come with the Secrets Manager.
//
// The operator v2.14.0 from chart 2.14.0, the latest release of the
// external-secrets chart at https://charts.external-secrets.io, with the
// image the chart names on ghcr.io. The controller and the webhook are one
// replica each, Deployments that tolerate no taint, so the control plane's
// NoSchedule taint keeps them on the workers. Their pods meet the restricted
// Pod Security standard, so external-secrets needs no label. The
// ServiceMonitor, the Grafana dashboard and the Bitwarden SDK server are off
// by default: the cluster has no Prometheus Operator and no Bitwarden.
ESOVersion: "2.14.0"

let Webhook = webhookServices["external-secrets-webhook"]

// WebhookCertificate is the name the chart gives the webhook's Secret, which
// its Deployment mounts, and the Certificate its inject-ca-from annotation
// names: the release name, then -webhook.
let WebhookCertificate = "external-secrets-webhook"

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: Webhook.namespace
	chart: {
		name:    "external-secrets"
		version: ESOVersion
		release: "external-secrets"
		repository: {
			name: "external-secrets"
			url:  "https://charts.external-secrets.io"
		}
	}
	values: {
		// The CRDs are part of the chart's output and of this component
		// (the chart's default, stated). Argo CD neither prunes nor deletes
		// them: deleting one deletes every resource of its kind, so removing
		// or renaming this component would otherwise drop every
		// ExternalSecret and generator, and a re-created ExternalSecret
		// regenerates nothing only while its Secret survives. The chart puts
		// these annotations on every CRD it renders.
		installCRDs: true
		crds: annotations: "argocd.argoproj.io/sync-options": "Prune=false,Delete=false"

		// No CRD has a conversion webhook: since 2.0 every CRD serves one
		// version (v1beta1 is not served), and the chart renders no
		// spec.conversion. The chart's default, stated: enabled only adds an
		// inject-ca-from annotation to the CRDs.
		crds: conversion: enabled: false

		// By default the chart's cert-controller makes the webhook's CA and
		// certificate, for the Service's cluster names only, into Secret
		// external-secrets-webhook, and writes the CA into the
		// configurations' caBundle and the CRDs'. certManager.enabled drops
		// the cert-controller and that Secret from the output and adds
		// cert-manager.io/inject-ca-from: external-secrets/
		// external-secrets-webhook to both configurations, so cainjector
		// fills the caBundle and nothing else writes it. cert.create is off:
		// the chart's Certificate has no setting for another DNS name, so
		// the component renders its own, below, under the same name.
		certController: create: false
		webhook: certManager: {
			enabled:                true
			addInjectorAnnotations: true
			cert: create: false
		}

		// The webhook neither mints nor rotates certificates; it serves
		// tls.crt and tls.key from the mounted Secret, reloads them when the
		// kubelet updates the files, and checks every five minutes that they
		// chain to ca.crt and are valid for its .svc name at now plus this
		// interval, shutting down if not. The default, 90 days, is longer
		// than a cert-manager certificate's whole 90-day life, so the webhook
		// would stop five minutes after it started. One hour matches its
		// readiness check: it serves for as long as the certificate is
		// valid, and cert-manager, which renews 30 days ahead, is the only
		// thing that rotates it.
		webhook: lookaheadInterval: "1h"
	}

	resources: {
		Namespace: (Webhook.namespace): _

		// The webhook's serving certificate, from the private CA, with the
		// Service's cluster name and the hostname the API server dials
		// through the Gateway (webhooks.cue). The webhook validates the
		// .svc name and the chain to ca.crt, which a private-ca Secret
		// carries. The CA's root, which cainjector writes into the caBundle,
		// does not change when the certificate is renewed.
		Certificate: (WebhookCertificate): {
			metadata: namespace: Webhook.namespace
			spec: {
				secretName: WebhookCertificate
				dnsNames: [
					"\(Webhook.name).\(Webhook.namespace).svc",
					Cluster.webhooks.hosts[Webhook.name],
				]
				privateKey: {
					algorithm:      "ECDSA"
					size:           256
					rotationPolicy: "Always"
				}
				issuerRef: {
					group: "cert-manager.io"
					kind:  "ClusterIssuer"
					name:  PrivateCA.issuer
				}
			}
		}
	}

	// Both webhook configurations are served by the one webhook Service, and
	// cainjector fills their caBundle from the Certificate above.
	patches: [
		(#WebhookPatch & {
			kind:    "ValidatingWebhookConfiguration"
			name:    "externalsecret-validate"
			service: Webhook.name
			webhooks: {
				"validate.externalsecret.external-secrets.io": path: "/validate-external-secrets-io-v1-externalsecret"
			}
		}).patch,
		(#WebhookPatch & {
			kind:    "ValidatingWebhookConfiguration"
			name:    "secretstore-validate"
			service: Webhook.name
			webhooks: {
				"validate.secretstore.external-secrets.io": path:        "/validate-external-secrets-io-v1-secretstore"
				"validate.clustersecretstore.external-secrets.io": path: "/validate-external-secrets-io-v1-clustersecretstore"
			}
		}).patch,
	]
}).artifact]
