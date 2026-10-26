package holos

// The admission webhook registry. ADR 0001 takes the control plane off the
// pod network, so the API server reaches a webhook through a URL on HAProxy,
// a layer 4 load balancer on the control plane, which passes TLS through to
// a host-network Gateway that routes on SNI to the webhook's Service:
//
//	API server
//	  -> https://<service>.<namespace>.webhooks.<cluster>.<privateDomain>:9443/<path>
//	     (resolved by Talos extraHostEntries to the control plane's address)
//	  -> HAProxy on the control plane, TCP, TLS passed through
//	  -> Gateway on the workers' host network, TLSRoute in passthrough mode,
//	     matched on the SNI hostname
//	  -> the webhook Service's port, then the webhook's Pods
//
// #Cluster.webhooks (clusters.cue) holds the per-cluster half: the
// enforcement flag, the timeout, the HAProxy port and the hostnames. This
// file holds the platform half: every Service that serves an admission
// webhook. A component that registers a webhook adds its Service here and
// renders its webhook configurations with #WebhookPatch
// (components/webhooks.cue), so the load balancer item can render
// extraHostEntries, the HAProxy frontend and one TLSRoute per entry from this
// one list.

// #WebhookService is a Service that serves admission webhooks.
#WebhookService: {
	// name and namespace are the Service's.
	name:      string
	namespace: string
	// port is the Service port the Gateway's TLSRoute forwards to.
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
