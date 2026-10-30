package holos

import (
	"encoding/json"
	"list"
	"strings"
)

// The private CA (interview Q10): a self-signed bootstrap Issuer signs a
// root, stored as a Secret, and the ClusterIssuer issues from it. cert-manager
// generates the root's key in the cluster, so nothing secret is rendered.
// Names are in PrivateCA (private-ca.cue).
//
// Also the CertificateRequestPolicies that approver-policy approves every
// CertificateRequest in the cluster by, beside the issuers they guard, and
// the RBAC that binds them (README.md, "The private CA"). A policy applies
// to a request when its selector matches the request's issuer and namespace
// and the requester may use it; the request is approved if one policy that
// applies allows everything it asks for, and denied otherwise:
//
//   - private-ca-root: the bootstrap Issuer signs the root, its exact
//     subject and a CA, and nothing else.
//   - trust-manager-webhook: trust-manager's self-signed Issuer signs its
//     webhook's serving certificate, its names and common name.
//   - private-ca-<namespace>: the ClusterIssuer signs, for one namespace in
//     PrivateCA.requesters (components/private-ca.cue), exactly the names,
//     usages and common name its Certificates list, and no CA.
//   - deny-all: applies to every request from anyone, and allows nothing,
//     so a request no other policy applies to is denied rather than left
//     unprocessed.
//
// The platform policies are bound only to cert-manager's controller, which
// creates the request for every Certificate, whatever its namespace. A
// request made by hand, even in a platform namespace, is bound only to
// deny-all and is denied.
//
// Applied once cert-manager's CRDs are established and its controller is
// running, and approver-policy's CRD is.

let Site = Cluster.site

// CertManager is cert-manager's controller's ServiceAccount, the requester
// of every request made from a Certificate (spec.username, which
// cert-manager's webhook stamps). Its namespace is cert-manager's, which is
// PrivateCA.namespace.
let CertManager = {
	name:      "cert-manager"
	namespace: PrivateCA.namespace
}

// RootSubject is the root's common name and subject, which the root's
// Certificate asks for and its policy allows.
let RootSubject = {
	commonName: "Holos \(Cluster.name) root CA"
	subject: {
		organizations: ["Holos"]
		organizationalUnits: ["\(Cluster.name).\(Site.privateDomain)"]
	}
}

// TrustManager is trust-manager's webhook: its Service, and its
// self-signed Issuer and the Certificate the chart issues from it, both
// named after the release (components/trust-manager).
let TrustManager = webhookServices["trust-manager"]

// Exactly is an allowed string list of approver-policy's that permits
// exactly the names given. values are patterns, in which * matches any
// string, so *.bank.internal would also allow keycloak.bank.internal; where
// a name has a *, a CEL rule also requires each value to be one of the
// names as written.
#Exactly: {
	names: [...string]
	out: {
		required: true
		values:   names
		if list.Contains([for N in names {strings.Contains(N, "*")}], true) {
			validations: [{
				rule:    "self in \(json.Marshal(names))"
				message: "must be one of these exactly, * included: \(strings.Join(names, ", "))"
			}]
		}
	}
}

// PrivateCAIssuerRef selects the ClusterIssuer.
let PrivateCAIssuerRef = {
	group: "cert-manager.io"
	kind:  "ClusterIssuer"
	name:  PrivateCA.issuer
}

holos: spec: artifacts: [(#ResourcesArtifact & {
	resources: {
		// Namespaced, not a ClusterIssuer, so nothing outside cert-manager's
		// namespace can mint a self-signed certificate from it.
		Issuer: (PrivateCA.bootstrapIssuer): {
			metadata: namespace: PrivateCA.namespace
			spec: selfSigned: {}
		}

		// The root. Ten years, so it outlives any garage cluster. The key never
		// rotates: with cert-manager's default (Always), any reissue, a spec
		// edit or a manual renew, would make a new root that every certificate
		// already issued stops verifying against.
		Certificate: (PrivateCA.root): {
			metadata: namespace: PrivateCA.namespace
			spec: {
				RootSubject
				isCA:       true
				duration:   "87600h"
				secretName: PrivateCA.root
				privateKey: {
					algorithm:      "ECDSA"
					size:           256
					rotationPolicy: "Never"
				}
				issuerRef: {
					group: "cert-manager.io"
					kind:  "Issuer"
					name:  PrivateCA.bootstrapIssuer
				}
			}
		}

		ClusterIssuer: (PrivateCA.issuer): spec: ca: secretName: PrivateCA.root

		// The root's request, in cert-manager's namespace, from the
		// bootstrap Issuer: the root's common name and subject, and a CA.
		// A request that asks for no subject is denied too, as is one with
		// a DNS name, which this policy does not list.
		CertificateRequestPolicy: (PrivateCA.root): spec: {
			allowed: {
				commonName: {
					required: true
					value:    RootSubject.commonName
				}
				subject: {
					organizations: (#Exactly & {names: RootSubject.subject.organizations}).out
					organizationalUnits: (#Exactly & {names: RootSubject.subject.organizationalUnits}).out
				}
				isCA: true
			}
			selector: {
				issuerRef: {
					group: "cert-manager.io"
					kind:  "Issuer"
					name:  PrivateCA.bootstrapIssuer
				}
				namespace: matchNames: [PrivateCA.namespace]
			}
		}

		// trust-manager's webhook certificate, from its own self-signed
		// Issuer, in cert-manager's namespace: the chart's name and common
		// name, the Service's cluster name, and the hostname the
		// trust-manager component adds for the Gateway (webhooks.cue).
		CertificateRequestPolicy: "trust-manager-webhook": spec: {
			let SVC = "\(TrustManager.name).\(TrustManager.namespace).svc"
			allowed: {
				commonName: {
					required: true
					value:    SVC
				}
				dnsNames: (#Exactly & {names: [SVC, Cluster.webhooks.hosts[TrustManager.name]]}).out
				isCA: false
			}
			selector: {
				issuerRef: {
					group: "cert-manager.io"
					kind:  "Issuer"
					name:  TrustManager.name
				}
				namespace: matchNames: [TrustManager.namespace]
			}
		}

		// One policy per namespace in PrivateCA.requesters, from the
		// ClusterIssuer: every name, usage and common name its Certificates
		// list, and no CA. A field the policy leaves out, such as usages for
		// a namespace whose Certificates set none, is one a request may not
		// carry at all.
		for NS, Certificates in PrivateCA.requesters {
			let DNSNames = list.SortStrings(list.FlattenN([for C in Certificates {C.dnsNames}], 1))
			let Usages = list.SortStrings(list.FlattenN([for C in Certificates if C.usages != _|_ {C.usages}], 1))
			let CommonNames = list.SortStrings([for C in Certificates if C.commonName != _|_ {C.commonName}])

			CertificateRequestPolicy: "\(PrivateCA.issuer)-\(NS)": spec: {
				allowed: {
					dnsNames: (#Exactly & {names: DNSNames}).out
					if len(Usages) > 0 {
						usages: Usages
					}

					// A common name is a string, not a list, so a CEL rule
					// lists the ones allowed, with no wildcard.
					if len(CommonNames) > 0 {
						commonName: validations: [{
							rule:    "self in \(json.Marshal(CommonNames))"
							message: "must be one of \(strings.Join(CommonNames, ", "))"
						}]
					}
					isCA: false
				}
				selector: {
					issuerRef: PrivateCAIssuerRef
					namespace: matchNames: [NS]
				}
			}
		}

		// The policy that applies to every request, by every issuer, in
		// every namespace, from anyone, and allows nothing: it requires a
		// DNS name from an empty list. With no policy that applies,
		// approver-policy leaves a request unprocessed, pending forever with
		// no condition; with this one it is denied, with a message naming
		// every policy that applied and why each refused. A request another
		// policy allows is still approved: one allowing policy is enough.
		CertificateRequestPolicy: "deny-all": spec: {
			allowed: dnsNames: {
				required: true
				values: []
			}
			selector: issuerRef: {}
		}

		// cert-manager's controller may use the platform policies, wherever
		// the request is. A RoleBinding could grant one in a namespace, but
		// RBAC refuses a binding to a permission its author does not hold,
		// so a project owner cannot grant themselves one.
		let Platform = "approver-policy:platform"
		ClusterRole: (Platform): rules: [{
			apiGroups: ["policy.cert-manager.io"]
			resources: ["certificaterequestpolicies"]
			verbs: ["use"]
			resourceNames: list.SortStrings([
				for K, P in CertificateRequestPolicy if K != "deny-all" {P.metadata.name},
			])
		}]
		ClusterRoleBinding: (Platform): {
			roleRef: {
				apiGroup: "rbac.authorization.k8s.io"
				kind:     "ClusterRole"
				name:     Platform
			}
			subjects: [{
				kind:      "ServiceAccount"
				name:      CertManager.name
				namespace: CertManager.namespace
			}]
		}

		// Everyone may use deny-all. A request with no user, made while
		// cert-manager's webhook was unreachable, matches no group and stays
		// unprocessed (components/cert-manager, disableAutoApproval).
		let DenyAll = "approver-policy:deny-all"
		ClusterRole: (DenyAll): rules: [{
			apiGroups: ["policy.cert-manager.io"]
			resources: ["certificaterequestpolicies"]
			verbs: ["use"]
			resourceNames: [CertificateRequestPolicy["deny-all"].metadata.name]
		}]
		ClusterRoleBinding: (DenyAll): {
			roleRef: {
				apiGroup: "rbac.authorization.k8s.io"
				kind:     "ClusterRole"
				name:     DenyAll
			}
			subjects: [{
				apiGroup: "rbac.authorization.k8s.io"
				kind:     "Group"
				name:     "system:authenticated"
			}]
		}
	}
}).artifact]
