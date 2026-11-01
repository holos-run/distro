package holos

import "encoding/yaml"

// #WebhookPatch is the Kustomize patch that points a chart's admission webhook
// configuration at the ingress Gateway's address, as ADR 0001 requires of
// every webhook in the distro (webhooks.cue has the path a request takes).
// For each webhook in the configuration it:
//
//   - replaces clientConfig.service with clientConfig.url, the Service's
//     hostname and the Gateway's webhooks port from Cluster.webhooks plus the
//     webhook's path;
//   - sets failurePolicy from the cluster's enforcement flag, Ignore while it
//     bootstraps and Fail once enforcing;
//   - sets timeoutSeconds to the cluster's short webhook timeout.
//
// caBundle is left alone: cert-manager's cainjector fills it from the
// configuration's inject-ca-from-secret or inject-ca-from annotation whether
// clientConfig names a Service or a URL, and istiod fills its own.
//
// A url: breaks rule 1 of ADR 0003's Service contract, which supersedes this
// path, so the patch also gives the configuration the
// holos.run/contract-exception annotation, and contract-check
// (cmd/contract-check) reports it as an exception rather than failing it.
// Treasury keeps ADR 0001's form until it is rebuilt on the new layer, which
// deletes this patch, its call sites and the annotation with them.
#WebhookPatch: {
	kind: "ValidatingWebhookConfiguration" | "MutatingWebhookConfiguration"
	name: string
	// service is the webhookServices entry (webhooks.cue) that serves the
	// configuration's webhooks.
	service: or([for K, _ in webhookServices {K}])
	// webhooks maps each webhook's name in the configuration to its path on
	// the service.
	webhooks: [string]: path: string

	let Kind = kind
	let Name = name
	let URL = Cluster.webhooks.urls[service]

	patch: #KustomizePatch & {
		target: {
			group:   "admissionregistration.k8s.io"
			version: "v1"
			kind:    Kind
			name:    Name
		}
		patch: yaml.Marshal({
			apiVersion: "admissionregistration.k8s.io/v1"
			kind:       Kind
			metadata: {
				name: Name
				annotations: "holos.run/contract-exception": "ADR 0001's Gateway webhook path, kept on treasury until its rebuild; see ADR 0003 and Talos_Control_Plane_Ready/rebuild-treasury-on-the-new-layer"
			}
			"webhooks": [for N, W in webhooks {
				"name":         N
				failurePolicy:  Cluster.webhooks.failurePolicy
				timeoutSeconds: Cluster.webhooks.timeoutSeconds
				clientConfig: {
					// null deletes the chart's service reference in a strategic
					// merge patch; clientConfig takes a service or a url, not
					// both.
					"service": null
					url:       URL + W.path
				}
			}]
		})
	}
}
