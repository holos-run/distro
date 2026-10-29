package holos

// istiod is Istio's control plane in ambient mode: it configures ztunnel and
// the gateways, issues the mesh's workload certificates from its own
// self-signed CA, and deploys a gateway for every Gateway of class istio
// (ingress-gateway). Istio's names are in Istio (istio.cue).

let Webhook = webhookServices.istiod

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: Istio.namespace
	chart: {
		name:    "\(Istio.charts)/istiod"
		version: Istio.version
		release: "istiod"
	}
	values: {
		profile: "ambient"
		image:   Istio.images.pilot
		// The image istiod renders into every gateway and waypoint Deployment
		// it creates. An image with a / is used as it is, digest included.
		global: proxy: image: Istio.images.proxyv2

		meshConfig: {
			trustDomain: Istio.trustDomain
			// The external authorization servers a CUSTOM
			// AuthorizationPolicy may name. holos-authenticator, over gRPC
			// (HolosAuthenticator.provider): it answers with the headers
			// that make a request to the API server an impersonation. Two
			// seconds, as in aavis-ops. failOpen stays false, so a request
			// the server cannot answer gets 403.
			extensionProviders: [{
				name: HolosAuthenticator.provider.name
				envoyExtAuthzGrpc: {
					service: HolosAuthenticator.provider.service
					port:    HolosAuthenticator.provider.port
					timeout: "2s"
				}
			}]
		}

		// One replica, as the chart's default, without the chart's
		// HorizontalPodAutoscaler: the cluster has no metrics server, and an
		// autoscaler that cannot read metrics reports Degraded in Argo CD.
		autoscaleEnabled: false

		env: {
			// A Gateway sends a request for a Service labeled
			// istio.io/ingress-use-waypoint through the Service's waypoint.
			// On by default in 1.31; stated, so that a Service given a
			// waypoint behind the ingress Gateway gets its policy. Nothing
			// relies on it yet: holos-authenticator, for which it was
			// turned on, runs on a Gateway of its own instead.
			ENABLE_INGRESS_WAYPOINT_ROUTING: "true"
			// Adds the webhook hostname (webhooks.cue) to the DNS names of
			// istiod's serving certificate, which serves the webhooks on 15017,
			// so the API server can verify it when it dials the hostname
			// through the Gateway.
			ISTIOD_CUSTOM_HOST: Cluster.webhooks.hosts[Webhook.name]
		}

		// istiod trusts the private CA's root, besides the system pool, when
		// it fetches the JWKS for a RequestAuthentication: it reads
		// /cacerts/extra.pem, mounted here from trust-manager's ConfigMap.
		// The chart's jwksResolverExtraRootCA stays empty, since it mounts its
		// own ConfigMap at the same path. No cacerts Secret is created: any of
		// its keys would switch istiod to a plugged-in CA. istiod reads the
		// file at start, so a new root needs an istiod restart.
		volumes: [{
			name: "jwks-extra-cacerts"
			configMap: {
				name: PrivateCA.bundle
				items: [{key: PrivateCA.bundleKey, path: "extra.pem"}]
			}
		}]
		volumeMounts: [{
			name:      "jwks-extra-cacerts"
			mountPath: "/cacerts"
			readOnly:  true
		}]
	}

	// istiod patches these configurations' caBundle with its CA's root, a
	// field the render leaves out and Argo CD's server-side diff ignores. It
	// also switches the validators' failurePolicy to Fail once a dry run of an
	// invalid resource is refused by the webhook, that is once the Gateway
	// reaches istiod, and from then on until it restarts, whatever the render
	// says; webhooks.enforcing must agree (README.md, "Istio").
	patches: [
		(#WebhookPatch & {
			kind:    "ValidatingWebhookConfiguration"
			name:    "istio-validator-\(Istio.namespace)"
			service: Webhook.name
			webhooks: "rev.validation.istio.io": path: "/validate"
		}).patch,
		// The sidecar injector. Ambient pods have no sidecar, so it matches
		// only pods or namespaces that ask for one by label; none do.
		(#WebhookPatch & {
			kind:    "MutatingWebhookConfiguration"
			name:    "istio-sidecar-injector"
			service: Webhook.name
			webhooks: {
				"rev.namespace.sidecar-injector.istio.io": path: "/inject"
				"rev.object.sidecar-injector.istio.io": path:    "/inject"
				"namespace.sidecar-injector.istio.io": path:     "/inject"
				"object.sidecar-injector.istio.io": path:        "/inject"
			}
		}).patch,
	]
}).artifact]
