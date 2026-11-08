package holos

// istio-base is Istio's CRDs, its reader ServiceAccount, the istio-system
// namespace and the default revision's validating webhook. istiod, istio-cni
// and ztunnel follow it (registry.cue). Istio's names are in Istio
// (istio.cue).
//
// The validating webhook, istiod-default-validator, is served by istiod: the
// API server reaches it by the chart's service: reference to istiod, like
// istiod's own (ADR 0003).

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: Istio.namespace
	chart: {
		name:    "\(Istio.charts)/base"
		version: Istio.version
		release: "istio-base"
	}
	values: {
		// The revision whose istiod validates Istio resources in every
		// namespace. The chart's default, stated: the default revision is the
		// only one.
		defaultRevision: "default"
		// Fail, as istiod's own validator (istiod.cue) and as the chart
		// recommends for a tool that cannot tell an install from an upgrade:
		// helm template renders Ignore, istiod switches it to Fail once the
		// webhook answers, and Argo CD's self-heal would switch it back.
		base: validationFailurePolicy: "Fail"
	}

	// istio-cni and ztunnel run privileged pods on every node, which Talos's
	// baseline Pod Security enforcement refuses.
	resources: Namespace: (Istio.namespace): metadata: labels: "pod-security.kubernetes.io/enforce": "privileged"

	// On a cluster with a binding, the built-in admin ClusterRole also covers
	// Istio's AuthorizationPolicy and RequestAuthentication, and nothing else
	// of Istio's or of the Gateway API's: the API server aggregates every
	// ClusterRole with this label into admin. A bound claim's owner group holds
	// admin in the claim's namespace and nowhere else (components/project, the
	// RoleBinding), so its owners can change the policy a bound product leaves
	// in the claim's own directory with kubectl, as the procedure for editing
	// it live does (README.md, Editing a bound claim's policy live), where
	// before they could change it only through Argo CD. Nothing vendored
	// aggregates an Istio kind into admin, edit or view.
	//
	// The verbs are the set admin and edit hold on every other namespaced kind,
	// such as cert-manager's Certificate (cert-manager-edit). Leaving out
	// create and delete would not keep an owner's change inside what the
	// claim's self-heal undoes: a rule patched into a policy whose render sets
	// no rules, such as planboard-waypoint's, is no difference to Argo CD
	// either. What bounds it is the Substrate shim's rule for the board, which
	// admits only the claim's groups and /platform/owners, so the most an owner
	// can open is their own product to their own claim's members. The
	// networking, extensions and telemetry groups stay out: their objects act
	// beyond the namespace or program the proxies (components/project,
	// BoundBlacklist).
	//
	// Only on a cluster with a binding, so a cluster with no binding renders as
	// it did (Second_Cluster Q6). There every claim's owner group gets these
	// kinds in its own namespace, bound or not, since it is admin itself that
	// grows. Either kind acts only on the workloads and gateways of its own
	// namespace, except in the mesh's root namespace, istio-system, where no
	// owner is admin. A claim whose ownerAccess is edit or view does not get
	// them.
	if len(clusterBindings[Cluster.name]) > 0 {
		resources: ClusterRole: "istio-security-admin": {
			metadata: labels: "rbac.authorization.k8s.io/aggregate-to-admin": "true"
			rules: [{
				apiGroups: ["security.istio.io"]
				resources: ["authorizationpolicies", "requestauthentications"]
				verbs: ["get", "list", "watch", "create", "update", "patch", "delete", "deletecollection"]
			}]
		}
	}
}).artifact]
