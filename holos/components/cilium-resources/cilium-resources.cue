package holos

// The Cilium custom resources. Their CRDs are registered by the Cilium
// operator when it starts, not shipped in the chart, so this component
// applies after the cilium component is running.

holos: spec: artifacts: [(#ResourcesArtifact & {
	resources: {
		// The cluster's block of the site's ingress range. LB IPAM gives
		// every LoadBalancer Service an address from it.
		CiliumLoadBalancerIPPool: (Cluster.name): spec: blocks: [{
			start: Cluster.loadBalancer.start
			stop:  Cluster.loadBalancer.stop
		}]

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
