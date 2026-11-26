package bindings

bindings: "choria-planboard": {
	project: "choria"
	productRefs: [{name: "planboard"}]
	// No access: the viewer is granted no project until the owner adds one.
	values: planboard: model: "claude-haiku-5-5"
}
