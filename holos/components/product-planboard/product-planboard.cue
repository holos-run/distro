package holos

// product-planboard renders one binding of the Planboard product
// (products/planboard.cue), as the component product-planboard-<project>: the
// registry adds one per binding (#BindingRegistrations), a cluster takes the
// ones whose claim lands on it and whose components it names (clusterBindings),
// and argocd-apps gives each an Application in the platform AppProject. Both
// buckets are empty, so it renders nothing yet (#ProductComponent,
// components/product.cue).

// ProjectName and ProductName are the binding this instance renders, the
// parameters its registry entry passes. Without them, as `cue vet ./...`
// evaluates this directory, each is empty and the instance renders nothing.
ProjectName: string | *"" @tag(project)
ProductName: string | *"" @tag(product)

if ProjectName != "" {holos: spec: artifacts: (#ProductComponent & {
	projectName: ProjectName
	productName: ProductName
	platform: {}
	project: {}
}).artifacts
}
