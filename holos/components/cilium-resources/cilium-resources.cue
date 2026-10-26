package holos

import "net"

// The Cilium custom resources. Their CRDs are registered by the Cilium
// operator when it starts, not shipped in the chart, so this component
// applies after the cilium component is running.

let LB = Cluster.loadBalancer
let IG = IngressGateway

// rest is the block less the gateway's address: the addresses before it and
// the addresses after it, either empty when the gateway is at that end.
let rest = [
	if LB._n.start < LB._n.gateway {
		{start: LB.start, stop: net.AddIP(LB.gateway, -1)}
	},
	if LB._n.gateway < LB._n.stop {
		{start: net.AddIP(LB.gateway, 1), stop: LB.stop}
	},
]

holos: spec: artifacts: [(#ResourcesArtifact & {
	resources: {
		// The cluster's block of the site's ingress range, as two pools that
		// do not overlap (LB IPAM disables the newer of two pools that do),
		// so the ingress Gateway's address is reserved, not merely requested.
		//
		// The pool named for the cluster holds only the gateway's address and
		// serves only the gateway's Service, which istiod labels with its
		// Gateway's name; io.kubernetes.service.namespace is a label LB IPAM
		// adds to every Service for selectors. No other Service can take the
		// address, whatever order things start in, and the gateway's Service
		// can take no other address. It keeps the pool's original name so
		// that narrowing the pool in place carries the gateway's allocation
		// over; a pool removed or renamed releases its addresses first.
		CiliumLoadBalancerIPPool: (Cluster.name): spec: {
			blocks: [{start: LB.gateway, stop: LB.gateway}]
			serviceSelector: matchLabels: {
				"gateway.networking.k8s.io/gateway-name": IG.name
				"io.kubernetes.service.namespace":        IG.namespace
			}
		}

		// The rest of the block, for every other LoadBalancer Service. The
		// gateway's namespace, which holds nothing else, is left out, so the
		// gateway's Service matches the one pool above and could not be
		// handed one of these even if its Gateway stopped requesting the
		// address.
		// The selector excludes the gateway's whole namespace, since a label
		// selector cannot exclude one Service by name and namespace; a second
		// LoadBalancer Service there would find no pool.
		if len(rest) > 0 {
			CiliumLoadBalancerIPPool: "\(Cluster.name)-general": spec: {
				blocks: rest
				serviceSelector: matchExpressions: [{
					key:      "io.kubernetes.service.namespace"
					operator: "NotIn"
					values: [IG.namespace]
				}]
			}
		}

		// Answer ARP for LoadBalancer addresses on the node uplink, from
		// one elected node per Service. Nodes off the pod network run no
		// Cilium agent and could not announce anyway; the selector says so.
		CiliumL2AnnouncementPolicy: "load-balancer-ips": spec: {
			nodeSelector: matchExpressions: [{
				key:      "holos.run/pod-network"
				operator: "NotIn"
				values: ["none"]
			}]
			interfaces: ["^\(Cluster.network.nodeInterface)$"]
			loadBalancerIPs: true
			externalIPs:     false
		}

		// Istio ambient SNATs kubelet probes to 169.254.7.127, an address
		// Cilium does not know as the host, so a default-deny policy would
		// drop them. This allows them to every endpoint. enableDefaultDeny
		// false on both directions keeps this policy from putting every
		// endpoint into default-deny, which selecting an endpoint with an
		// ingress rule otherwise does. From Istio's ambient platform
		// prerequisites for Cilium.
		CiliumClusterwideNetworkPolicy: "allow-ambient-hostprobes": spec: {
			description: "Allows SNAT-ed kubelet health check probes into ambient pods"
			enableDefaultDeny: {
				egress:  false
				ingress: false
			}
			endpointSelector: {}
			ingress: [{fromCIDR: ["169.254.7.127/32"]}]
		}
	}
}).artifact]
