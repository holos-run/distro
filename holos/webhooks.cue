package holos

// The admission webhook registry. ADR 0001 takes the control plane off the
// pod network, so the API server reaches a webhook the way a client outside
// the cluster does: through a URL on the ingress Gateway's address, where a
// listener passes TLS through to the webhook's Service, routed on SNI:
//
//	API server
//	  -> https://<service>.<namespace>.webhooks.<cluster>.<privateDomain>:9443/<path>
//	     (resolved by Talos static host entries, talos.cue, to the
//	     Gateway's address, Cluster.loadBalancer.gateway)
//	  -> the Gateway's LoadBalancer Service, which a worker announces with ARP
//	  -> the Gateway's webhooks listener, TLS passthrough, and the entry's
//	     TLSRoute, matched on the SNI hostname
//	  -> the webhook Service's port, then the webhook's Pods, which terminate
//	     TLS with a serving certificate carrying the hostname
//
// #Cluster.webhooks (clusters.cue) holds the per-cluster half: the
// enforcement flag, the timeout, the port and the hostnames. This file holds
// the platform half: every Service that serves an admission webhook. A
// component that registers a webhook adds its Service here and renders its
// webhook configurations with #WebhookPatch (components/webhooks.cue); the
// listener and one TLSRoute per entry (components/ingress-gateway) and the
// control plane's host entries (talos.cue) are rendered from this one list.
// The webhook's serving certificate must also carry its hostname, and a new
// entry's host entry reaches a running control plane only by talosctl
// (providers/talos/README.md), not through Argo CD.
//
// A webhook whose certificate cannot carry a name under the webhooks domain
// sets hostname to the name it does carry; the path is the same, through a
// listener of its own on the same port.

// #WebhookService is a Service that serves admission webhooks.
#WebhookService: {
	// name and namespace are the Service's.
	name:      string
	namespace: string
	// port is the Service port the entry's TLSRoute forwards to.
	port: int | *443
	// component is the platform component that deploys the Service.
	component: string
	// hostname, if set, replaces the entry's hostname under
	// Cluster.webhooks.domain (clusters.cue), for a webhook whose serving
	// certificate carries only a name of its own choosing and that cannot be
	// given another. The ingress Gateway gets a listener of its own for each
	// such name (components/ingress.cue), since the webhooks listener's
	// wildcard does not cover it, and the control plane's host entry points
	// it at the Gateway like any other.
	hostname?: string
}

webhookServices: [NAME=string]: #WebhookService & {name: NAME}

webhookServices: {
	// approver-policy's webhook validates CertificateRequestPolicies. Its
	// serving certificate is its own, signed by a CA it keeps in Secret
	// cert-manager/cert-manager-approver-policy-tls, and its only DNS name is
	// the Service's cluster name, with no flag for another
	// (pkg/internal/cmd/cmd.go at v0.29.0). So the API server dials that name
	// itself through the Gateway, and the control plane resolves it to the
	// Gateway's address like the names under the webhooks domain (interview
	// Q68). cainjector fills the caBundle from the CA Secret.
	"cert-manager-approver-policy": {
		namespace: "cert-manager"
		component: "approver-policy"
		hostname:  "cert-manager-approver-policy.cert-manager.svc"
	}
	// cert-manager's webhook validates and mutates cert-manager resources. Its
	// serving certificate is its own dynamic one, signed by the CA in Secret
	// cert-manager/cert-manager-webhook-ca, and carries the hostname through
	// --dynamic-serving-dns-names.
	"cert-manager-webhook": {
		namespace: "cert-manager"
		component: "cert-manager"
	}
	// CloudNativePG's webhooks validate and mutate its own resources:
	// Clusters, Backups, ScheduledBackups, Databases and Poolers. Its serving
	// certificate is Secret cnpg-system/cnpg-webhook-tls, issued by the
	// cloudnative-pg component's Certificate from the private-ca
	// ClusterIssuer with the hostname in its dnsNames. WEBHOOK_CERT_DIR
	// turns off the operator's own certificate and caBundle handling, so
	// cainjector alone fills the caBundle.
	"cnpg-webhook-service": {
		namespace: "cnpg-system"
		component: "cloudnative-pg"
	}
	// External Secrets' webhook validates its ExternalSecrets, SecretStores
	// and ClusterSecretStores. Its serving certificate is Secret
	// external-secrets/external-secrets-webhook, issued by the
	// external-secrets component's Certificate from the private-ca
	// ClusterIssuer with the hostname in its dnsNames. The chart's
	// cert-controller, which would mint a certificate of its own and write
	// the caBundle, is not deployed, so cainjector alone fills the caBundle.
	"external-secrets-webhook": {
		namespace: "external-secrets"
		component: "external-secrets"
	}
	// istiod's webhooks: the validator of Istio's own resources (the istiod
	// component's istio-validator-istio-system and istio-base's
	// istiod-default-validator) and the sidecar injector, which ambient leaves
	// idle. The Service's port 443 is istiod's 15017. Its serving certificate
	// is istiod's own, signed by istiod's self-signed mesh CA, and carries the
	// hostname through ISTIOD_CUSTOM_HOST. istiod patches the caBundle of all
	// three configurations itself.
	istiod: {
		namespace: Istio.namespace
		component: "istiod"
	}
	// trust-manager's webhook validates Bundles. Its serving certificate is
	// Secret cert-manager/trust-manager-tls, issued by the chart's
	// Certificate from its self-signed Issuer, with the hostname added to the
	// Certificate's dnsNames.
	"trust-manager": {
		namespace: "cert-manager"
		component: "trust-manager"
	}
}
