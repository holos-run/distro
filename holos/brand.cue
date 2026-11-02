package holos

// Brand is the distribution's own name, which every name it chooses for
// itself is built from: its controllers' namespaces, Deployments and
// ServiceAccounts, the Secrets Manager's management namespaces, its Keycloak
// client and users and the Secrets they read, and the product text an end
// user or an operator sees, such as the Secrets Manager's title. Holos is
// the software the distribution is built with, not the name of what it
// ships, so all of these are brandable by an adopter.
//
// Both fields are disjunctions with defaults. An unchanged distribution
// renders Bank of Pinky; a vendor overrides them by unifying its own values
// with Brand, in one file of its own in this directory, and the names
// follow:
//
//	Brand: {name: "Example Bank", slug: "example-bank"}
//
// The Keycloak realm is not part of Brand: it is default for every
// distribution, and the issuer's host tells them apart (ADR 0002). Neither
// are the API groups (keycloak.holos.run and the rest) and the holos.run/*
// label and annotation keys, which belong to the software, nor the holos
// CLI and the paths it reads.
Brand: {
	// name is the brand as people read it, in titles and descriptions.
	name: *"Bank of Pinky" | string
	name: !=""
	// slug is the brand in names: lowercase letters, digits and dashes, so
	// valid in a namespace, a Kubernetes object's name, a Keycloak client ID
	// and a Quay organization. Every chosen name is <slug> and a suffix; at
	// 28 characters at most, the longest, the controller's Service
	// <slug>-controller-manager-metrics-service, stays within the 63 a
	// Service name allows.
	slug: *"bank-of-pinky" | string
	slug: =~"^[a-z]([a-z0-9-]{0,26}[a-z0-9])?$"
}
