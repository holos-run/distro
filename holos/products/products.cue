// Package products is the product collection: one small file per product, the
// vendor's or the platform's, which says what binding a project to the product
// asks of a cluster and of the project's owner. A product is
//
//	// holos/products/my-product.cue
//	package products
//
//	products: "my-product": {
//		components: ["substrate", "substrate-shim"]
//		#Values: {
//			#project: _
//			repo: *"https://github.com/my-org/\(#project)-config" | =~"^https://"
//		}
//	}
//
// and renders nothing by itself. A binding (holos/bindings) binds it to a
// claim, each binding of a product is a component of the platform, and the
// product's component, components/product-<name>, renders once per binding, on
// the clusters that binding lands on. So a product is the one thing that
// renders the same for every project on a cluster: the owner's file says only what the
// product leaves to them, and neither side copies what the claim already knows.
//
// components are the optional entries of the registry a cluster must name for
// the product to land there (#Product.components). #Values is what a binding
// may set, and it is closed: that a binding's atespace comes from its project
// and its images from its cluster's pins is enforced by the schema, not by a
// convention (#Product.#Values).
//
// A product's images are not here. Each cluster pins them by digest under the
// product's name, as it does every version (pins/<cluster>.cue), so one commit
// renders the images a cluster pins for every binding on that cluster, a bump
// moves the cluster it names, and two clusters may run different ones. The
// registry and the organization they are pulled from are the cluster's and the
// claim's, so a digest is all a pin holds.
//
// It is a package of its own, beside projects/, for the reason that one is: CUE
// loads only the root-level holos/*.cue files of package holos as ancestors of
// a component, so holos/collections.cue imports this package and binds products
// into the root, where the registry and the product's component read it. This
// package can see no cluster and no claim, so a product does not name either,
// and what depends on both is evaluated there (bindingValues, collections.cue).
// It imports projects for the shape of a name, so a product's and a claim's
// cannot drift.
package products

import proj "go.holos.run/distro/holos/projects"

// #Product is one product.
#Product: {
	// name is the products key, a project's #Name because it is half of the
	// component product-<name>-<claim>, and its directory is
	// components/product-<name>.
	name: proj.#Name

	// components are the optional entries of the registry a cluster must name
	// for a binding of this product to land on it, each one a name in
	// #Cluster.components. A name that is not an optional entry fails cue vet
	// (productComponents, collections.cue), since this package cannot see the
	// registry. The product's component is synced after them: the registry puts
	// every product after the entries one can name. It is required, as #Values
	// is: a list forgotten and left empty would land the product on every
	// cluster its claim selects.
	components!: [...string]

	// #Values is the schema of the product's entry in a binding's values, with
	// its defaults by convention, for the root to resolve against the binding
	// (bindingValues, collections.cue). It is a definition, so a struct written
	// in a product's file is closed: a binding can set the regular fields it
	// has and no others, which is how a binding is kept from setting an atespace
	// or an image. Keeping it closed is the product file's part: a #Values of _,
	// or one with ... in it, would take anything, and nothing here can tell. It
	// is required, and has no shape here, because a shape here would be open to
	// a product's fields and so open to a binding's; a product that takes no
	// values writes #Values: {}.
	//
	// It is parameterised on #project, the name of the binding's claim, which
	// the root sets, so a default can read it, as repo does in the example
	// above. A #Values that reads it declares it, because the reference resolves
	// within the product's file, where this definition is not in scope. A
	// binding that sets #project itself conflicts with the root.
	#Values!: _
}

// products is the collection, keyed by name. The key is unified into name,
// where #Name refuses a malformed one, as projects' is.
products: [NAME=string]: #Product & {name: NAME}
