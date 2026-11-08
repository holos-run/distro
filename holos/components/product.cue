package holos

// #ProductComponent is what the component of a product,
// components/product-<product>, renders a binding with: one instance per entry
// of the registry (#BindingRegistrations), which gives it the tags project and
// product. It is here, not in that component's directory, because this
// directory is an ancestor of every component, so the next product has the same
// rules without repeating them.
//
// The component fills the two buckets, platform and project, and takes its
// BuildPlan's artifacts from artifacts, below, and from nowhere else. That is
// the rule the buckets exist for (overview §3), because what a product renders
// decides who may change it. Nothing makes a component use this definition, so
// a component that writes its own artifacts is a mistake for review to catch;
// within it, the buckets are schema:
//
//   - platform is everything outside the claim's namespace, and what the owner
//     may not change in it: the objects of the platform's Application
//     product-<product>-<claim>, in AppProject platform, rendered to the
//     component's OutputDir.
//   - project is what the owner may change live: the objects of the claim's own
//     Application, in AppProject <claim>, whose one destination is the claim's
//     namespace, rendered into the claim's directory (#ProjectDirectory) and
//     constrained to that namespace, so a product cannot hand an owner another
//     one. The kinds that AppProject refuses are refused here too, at the
//     render, rather than failing the claim's whole Application at its sync:
//     cluster-scoped kinds, which a namespace would only be stamped on, and
//     the kinds its namespaceResourceBlacklist names (components/project), so
//     a product cannot put in the owner's hands what lets them grant themselves
//     more than their claim does. The ConfigMap project is the claim's own, and
//     a second one would overwrite it in the directory.
//
// An empty bucket renders no artifact, so a product that renders nothing leaves
// no directory. The platform's Application still points at the OutputDir,
// though, and reports a ComparisonError for a path that does not exist, so a
// product with a binding renders something into platform, as the project
// component renders its ConfigMap for the same reason.
//
// The component's tags default to "", which is how `cue vet ./...` evaluates
// its directory, so its artifacts belong under `if ProjectName != ""`, as the
// project component's are. That is also why cue vet cannot see what is in a
// bucket: a refused object fails holos render platform, with exit 1. A component
// that reads claim or values holds the instance in a let, since a literal
// unified with this definition cannot refer to its fields:
//
//	let Read = #ProductComponent & {projectName: ProjectName, productName: ProductName}
//	if ProjectName != "" {holos: spec: artifacts: (Read & {
//		platform: ConfigMap: x: data: repo: Read.values.repo.url
//		project: {}
//	}).artifacts}
#ProductComponent: {
	// projectName and productName are the component's tags.
	projectName: string
	productName: string

	// claim, product, binding and values are what the component reads, beside
	// Cluster: the whole claim and product from their collections, and the
	// binding and its values for this product, resolved against the product's
	// schema, by the registry entry (productBindings and bindingValues,
	// collections.cue). cue vet has refused a reference to something that does
	// not exist, so nothing is copied or checked here.
	let ENTRY = "product-\(productName)-\(projectName)"
	claim:   projects[projectName]
	product: products[productName]
	binding: bindings[productBindings[ENTRY].binding]
	values:  bindingValues[ENTRY]

	platform: #Resources
	project: #Resources & {
		[_]: [_]: metadata: namespace: projectName

		// What the claim's AppProject would refuse (above).
		Application?:                    _|_
		AppProject?:                     _|_
		Bundle?:                         _|_
		CertificateRequestPolicy?:       _|_
		CiliumClusterwideNetworkPolicy?: _|_
		CiliumL2AnnouncementPolicy?:     _|_
		CiliumLoadBalancerIPPool?:       _|_
		Client?:                         _|_
		ClusterIssuer?:                  _|_
		ClusterRole?:                    _|_
		ClusterRoleBinding?:             _|_
		Group?:                          _|_
		GroupMembership?:                _|_
		Instance?:                       _|_
		Namespace?:                      _|_
		Organization?:                   _|_
		Repository?:                     _|_
		Role?:                           _|_
		RoleBinding?:                    _|_
		User?:                           _|_

		// A product has a binding, so the claim is bound, and its AppProject
		// also refuses six API groups whole (BoundBlacklist,
		// components/project): the Gateway API, Istio's networking,
		// extensions and telemetry groups, ate.dev and argoproj.io, whose
		// Application and AppProject are above. Resources are keyed by kind
		// alone, so these are every kind the platform's CRDs define in those
		// groups but ate.dev's two cluster-scoped ones, which no namespace can
		// hold, and a kind a later release adds is to be added here. What a
		// product needs of them, such as a waypoint's Gateway or a route, goes
		// in the platform bucket (components/product-planboard). security.istio.io
		// stays the owner's. Gateway is a kind in both the Gateway API and
		// Istio, and ReferenceGrant in both the Gateway API and
		// holos-controller's security.holos.run, which the AppProject refuses
		// too, so neither has a group left that the owner may sync.
		BackendTLSPolicy?: _|_
		GatewayClass?:     _|_
		Gateway?:          _|_
		GRPCRoute?:        _|_
		HTTPRoute?:        _|_
		ListenerSet?:      _|_
		ReferenceGrant?:   _|_
		TCPRoute?:         _|_
		TLSRoute?:         _|_
		UDPRoute?:         _|_
		DestinationRule?:  _|_
		EnvoyFilter?:      _|_
		ProxyConfig?:      _|_
		ServiceEntry?:     _|_
		Sidecar?:          _|_
		VirtualService?:   _|_
		WorkloadEntry?:    _|_
		WorkloadGroup?:    _|_
		TrafficExtension?: _|_
		WasmPlugin?:       _|_
		Telemetry?:        _|_
		WorkerPool?:       _|_
		ApplicationSet?:   _|_

		ConfigMap?: [_]: metadata: name: !="project"
	}

	// The buckets' artifacts. Each artifact of a BuildPlan writes its
	// intermediate files into one temporary directory (#ResourcesArtifact), so
	// the second names its own file.
	artifacts: [
		if len([for KIND in platform for O in KIND {O}]) > 0 {
			(#ResourcesArtifact & {resources: platform}).artifact
		},
		if len([for KIND in project for O in KIND {O}]) > 0 {
			(#ResourcesArtifact & {
				directory: (#ProjectDirectory & {project: projectName}).path
				generated: "project-resources.yaml"
				resources: project
			}).artifact
		},
	]
}
