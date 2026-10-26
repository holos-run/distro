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
// (providers/proxmox/talos/README.md), not through Argo CD.

// #WebhookService is a Service that serves admission webhooks.
#WebhookService: {
	// name and namespace are the Service's.
	name:      string
	namespace: string
	// port is the Service port the entry's TLSRoute forwards to.
	port: int | *443
	// component is the platform component that deploys the Service.
	component: string
}

webhookServices: [NAME=string]: #WebhookService & {name: NAME}

webhookServices: {
	// cert-manager's webhook validates and mutates cert-manager resources. Its
	// serving certificate is its own dynamic one, signed by the CA in Secret
	// cert-manager/cert-manager-webhook-ca, and carries the hostname through
	// --dynamic-serving-dns-names.
	"cert-manager-webhook": {
		namespace: "cert-manager"
		component: "cert-manager"
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
