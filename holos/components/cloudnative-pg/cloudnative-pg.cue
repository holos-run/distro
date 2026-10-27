package holos

import "encoding/yaml"

// cloudnative-pg is the CloudNativePG operator, its CRDs and its webhooks. It
// runs no PostgreSQL itself: every consumer writes its own Cluster in its
// own namespace, on the default StorageClass, ceph-rbd.
//
// The operator 1.30.1 from chart 0.29.1, the latest release of the
// cloudnative-pg chart at https://cloudnative-pg.github.io/charts, with the
// image the chart names on ghcr.io. The operator is a Deployment that
// tolerates no taint, so the control plane's NoSchedule taint keeps it, and
// every PostgreSQL pod it creates, on the workers. Its pods meet the
// restricted Pod Security standard, so cnpg-system needs no label. The
// chart's PodMonitor and Grafana dashboard are off by default: the cluster
// has no Prometheus Operator.
CNPGVersion: "0.29.1"

let Webhook = webhookServices["cnpg-webhook-service"]

// webhookCertDir is the chart's mount of the webhook-certificates volume.
let webhookCertDir = "/run/secrets/cnpg.io/webhook"

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: Webhook.namespace
	chart: {
		name:    "cloudnative-pg"
		version: CNPGVersion
		release: "cloudnative-pg"
		repository: {
			name: "cnpg"
			url:  "https://cloudnative-pg.github.io/charts"
		}
	}
	values: {
		// The CRDs are part of the chart's output and of this component
		// (the chart's default, stated). The chart marks them
		// helm.sh/resource-policy: keep, which only Helm reads; the patch
		// below keeps them for Argo CD.
		crds: create: true

		// By default the operator makes its own CA and webhook certificate,
		// for the Service's cluster names only, and writes the CA into both
		// configurations' caBundle every hour. With WEBHOOK_CERT_DIR set it
		// does neither: it serves the certificate it finds in the directory,
		// as apiserver.crt and apiserver.key, and leaves the configurations
		// alone. The certificate is the cnpg-webhook Certificate below, and
		// cainjector fills the caBundle. The operator reads the variable
		// before its ConfigMap, so it is an environment variable, not
		// config.data.
		additionalEnv: [{name: "WEBHOOK_CERT_DIR", value: webhookCertDir}]
	}

	resources: {
		Namespace: (Webhook.namespace): _

		// The webhook's serving certificate, from the private CA, with the
		// Service's cluster name and the hostname the API server dials
		// through the Gateway (webhooks.cue). The CA's root, which
		// cainjector writes into the caBundle, does not change when the
		// certificate is renewed.
		Certificate: "cnpg-webhook": {
			metadata: namespace: Webhook.namespace
			spec: {
				secretName: "cnpg-webhook-tls"
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

	let InjectCA = {
		target: {
			group:   "admissionregistration.k8s.io"
			version: "v1"
			kind:    string
			name:    string
		}
		patch: yaml.Marshal({
			apiVersion: "admissionregistration.k8s.io/v1"
			kind:       target.kind
			metadata: {
				name: target.name
				annotations: "cert-manager.io/inject-ca-from": "\(Webhook.namespace)/cnpg-webhook"
			}
		})
	}

	// Both webhook configurations are served by the one webhook Service, and
	// cainjector fills their caBundle from the cnpg-webhook Certificate.
	patches: [
		(#WebhookPatch & {
			kind:    "MutatingWebhookConfiguration"
			name:    "cnpg-mutating-webhook-configuration"
			service: Webhook.name
			webhooks: {
				"mbackup.cnpg.io": path:          "/mutate-postgresql-cnpg-io-v1-backup"
				"mcluster.cnpg.io": path:         "/mutate-postgresql-cnpg-io-v1-cluster"
				"mdatabase.cnpg.io": path:        "/mutate-postgresql-cnpg-io-v1-database"
				"mscheduledbackup.cnpg.io": path: "/mutate-postgresql-cnpg-io-v1-scheduledbackup"
			}
		}).patch,
		(#WebhookPatch & {
			kind:    "ValidatingWebhookConfiguration"
			name:    "cnpg-validating-webhook-configuration"
			service: Webhook.name
			webhooks: {
				"vbackup.cnpg.io": path:          "/validate-postgresql-cnpg-io-v1-backup"
				"vcluster.cnpg.io": path:         "/validate-postgresql-cnpg-io-v1-cluster"
				"vscheduledbackup.cnpg.io": path: "/validate-postgresql-cnpg-io-v1-scheduledbackup"
				"vdatabase.cnpg.io": path:        "/validate-postgresql-cnpg-io-v1-database"
				"vpooler.cnpg.io": path:          "/validate-postgresql-cnpg-io-v1-pooler"
			}
		}).patch,
		InjectCA & {target: {kind: "MutatingWebhookConfiguration", name: "cnpg-mutating-webhook-configuration"}},
		InjectCA & {target: {kind: "ValidatingWebhookConfiguration", name: "cnpg-validating-webhook-configuration"}},
		// Argo CD neither prunes nor deletes the CRDs. Deleting one deletes
		// every resource of its kind, and a Cluster owns its volumes, which
		// ceph-rbd reclaims with Delete, so removing or renaming this
		// component would otherwise drop every consumer's database.
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
		// The chart's webhook-certificates volume mounts the operator's own
		// Secret, cnpg-webhook-cert, optionally. It mounts the Certificate's
		// Secret instead, under the names WEBHOOK_CERT_DIR is read with, and
		// is required, so the operator does not start without it.
		{
			target: {kind: "Deployment", name: "cloudnative-pg"}
			patch: yaml.Marshal({
				apiVersion: "apps/v1"
				kind:       "Deployment"
				metadata: {
					name:      "cloudnative-pg"
					namespace: Webhook.namespace
				}
				spec: template: spec: volumes: [{
					name: "webhook-certificates"
					secret: {
						secretName: "cnpg-webhook-tls"
						optional:   false
						items: [
							{key: "tls.crt", path: "apiserver.crt"},
							{key: "tls.key", path: "apiserver.key"},
						]
					}
				}]
			})
		},
	]
}).artifact]
