package bindings

bindings: "splunk-planboard": {
	project: "splunk"
	productRefs: [{name: "planboard"}]
	values: planboard: access: viewers: projects: ["Splunk_BYOC"]
}
