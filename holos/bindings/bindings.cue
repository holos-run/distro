// Package bindings is the collection of bindings: one small file per binding,
// the claim owner's, named <claim>-<product>.cue, which binds products to a
// claim as a RoleBinding binds a role to subjects. A binding is
//
//	// holos/bindings/my-project-planboard.cue
//	package bindings
//
//	bindings: "my-project-planboard": {
//		project: "my-project"
//		productRefs: [{name: "planboard"}]
//		values: planboard: access: viewers: projects: ["roadmap"]
//	}
//
// and adds, for each product it refers to, a component
// product-<product>-<project> and an Argo CD Application of its own, on each
// cluster that takes the claim and the product's components (clusterBindings,
// collections.cue). That component reads the claim, the product, this binding
// and the cluster from the module, so nothing here repeats what the claim or
// the product knows: values holds only what they do not.
//
// project is the binding's namespace, as metadata.namespace is a RoleBinding's,
// and everything a binding renders comes from it: an atespace, a namespace, a
// Quay organization. productRefs is explicit as a RoleBinding's roleRef is, so
// reading the file says what it grants. A productSelector could stand beside
// it, to bind what a label selects; that door is left open, and nothing is
// built behind it.
//
// It is a package of its own, beside projects/, for the reason that one is: CUE
// loads only the root-level holos/*.cue files of package holos as ancestors of
// a component, so holos/collections.cue imports this package and binds bindings
// into the root. This package can see no cluster, claim or product, so it
// shapes a binding and no more: the root refuses a reference to something that
// does not exist and resolves values against the product's schema (bindingRefs
// and bindingValues, collections.cue). It imports projects for the shape of a
// name.
package bindings

import proj "go.holos.run/distro/holos/projects"

// #Binding is one binding.
#Binding: {
	// name is the bindings key, <claim>-<product> by convention. It is the
	// file's, and appears nowhere in a cluster: a binding's components are
	// named for the claim and the product, not for the binding.
	name: proj.#Name

	// project is the claim the binding belongs to, by name. It is required, as
	// a claim's clusterSelector is: a binding has no default project. A name
	// that is no claim's fails cue vet (bindingRefs, collections.cue).
	project!: proj.#Name

	// productRefs are the products the binding binds to the claim, at least
	// one, each once. A name that is no product's fails cue vet (bindingRefs).
	productRefs: [#ProductRef, ...#ProductRef]

	// values holds what each product leaves to the binding, keyed by product
	// name, one of productRefs. The body's shape is the product's #Values,
	// which is closed, and which the root applies with the claim's name
	// (bindingValues), since a default can depend on the claim and this package
	// cannot see the product. A product with nothing to set needs no key here.
	values: [string]: {...}
}

// #ProductRef refers to one product, by name.
#ProductRef: {
	name: proj.#Name
}

// bindings is the collection, keyed by name. The key is unified into name,
// where #Name refuses a malformed one, as projects' is.
bindings: [NAME=string]: #Binding & {name: NAME}
