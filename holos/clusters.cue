package holos

import "net"

// Sites and clusters are the platform's per-site and per-cluster data. A
// component reads its cluster as Cluster (components/component.cue), so
// adding a cluster is a new entry here; platform/platform.cue renders every
// component for every cluster.

// #Site is a place clusters run, with the network services they share.
#Site: {
	name: string
	// privateDomain is the site's private DNS zone. Every platform hostname
	// is under it, and the LAN resolver points *.<privateDomain> at a
	// cluster's ingress Gateway.
	privateDomain: string
	// resolvers serve privateDomain. CoreDNS forwards the zone to them.
	resolvers: [...net.IPv4 & string] & [_, ...]
}

#Cluster: {
	name: =~"^[a-z][a-z0-9-]{0,30}$"
	site: #Site

	// kubernetesVersion is the version Talos runs, pinned in
	// providers/proxmox/talos/cluster.sh. Charts see it as
	// Capabilities.KubeVersion.
	kubernetesVersion: string | *"1.37.1"

	// The Kubernetes networks, as Talos configures them (KubeNetworkConfig
	// in the control plane's machine config). Recorded here, not chosen
	// here: Cilium allocates pod addresses from the node podCIDRs the
	// controller manager assigns (ipam.mode=kubernetes), and CoreDNS must
	// take the address the kubelets were given as clusterDNS.
	network: {
		dnsDomain:     string | *"cluster.local"
		podSubnet:     net.IPCIDR & string | *"10.244.0.0/16"
		serviceSubnet: net.IPCIDR & string | *"10.96.0.0/12"
		// dnsServiceIP is the tenth address of serviceSubnet, the address
		// Talos gives every kubelet as clusterDNS.
		dnsServiceIP: net.IPv4 & string | *"10.96.0.10"
		// nodeInterface is the node's uplink, the interface L2
		// announcements answer ARP on.
		nodeInterface: string | *"eth0"
	}

	// loadBalancer is the cluster's block of the site's ingress range
	// (10.20.0.30 to .49 in the garage, sized for about six clusters of
	// three or four Gateway addresses). Cilium LB IPAM hands these out to
	// LoadBalancer Services and announces them with ARP.
	loadBalancer: {
		start: net.IPv4 & string
		stop:  net.IPv4 & string
	}
}

sites: [NAME=string]: #Site & {name: NAME}
clusters: [NAME=string]: #Cluster & {name: NAME}

sites: garage: {
	privateDomain: "bank.internal"
	resolvers: ["192.168.2.1"]
}

// spike is the first garage cluster: spike-cp-1 at 10.20.0.50 and
// spike-general-1 to -3 at .51 to .53 on the k8s vnet. It takes the first
// four addresses of the ingress range.
clusters: spike: {
	site: sites.garage
	loadBalancer: {
		start: "10.20.0.30"
		stop:  "10.20.0.33"
	}
}
