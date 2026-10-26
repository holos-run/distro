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
		// gateway is the ingress Gateway's address (components/ingress.cue),
		// the block's first unless set. It is pinned, not left to LB IPAM, so
		// the private zone's *.<privateDomain> record stays right across a
		// recreate of the Gateway or the cluster.
		gateway: net.IPv4 & string | *start
	}

	// webhooks is how the API server reaches this cluster's admission
	// webhooks. The control plane is off the pod network (ADR 0001), so every
	// webhook's clientConfig is a URL on the HAProxy layer 4 load balancer on
	// the control plane, which passes TLS through to a host-network Gateway
	// that routes on SNI to the webhook's Pods. webhooks.cue has the hostname
	// scheme and the registry of webhook Services.
	webhooks: {
		// enforcing is ADR 0001's provisioning flag, one value for every
		// webhook in the cluster. false while the cluster bootstraps: every
		// webhook fails open (Ignore), so the API server admits a request it
		// cannot get a webhook's answer for. Set true once every webhook
		// answers through the load balancer; every webhook then renders
		// Fail.
		enforcing:     bool | *false
		failurePolicy: "Ignore" | "Fail"
		if enforcing {failurePolicy: "Fail"}
		if !enforcing {failurePolicy: "Ignore"}

		// timeoutSeconds bounds how long the API server waits for a webhook,
		// in place of the default ten seconds, so a request waits briefly
		// rather than stalling when the webhook is unreachable.
		timeoutSeconds: int & >=1 & <=30 | *3

		// port is HAProxy's listener on the control plane's address: not
		// 443, left free on the control plane, and clear of everything Talos
		// binds there: 6443 (API server), 50000/50001 (apid, trustd),
		// 2379/2380 (etcd), 10250 (kubelet), 10257/10259 (controller
		// manager, scheduler), 7445 (KubePrism, on localhost) and 53 (host
		// DNS, on 169.254.116.108).
		port: 9443

		// domain is the suffix of every webhook hostname in the cluster. The
		// names resolve only on the control plane, through Talos
		// extraHostEntries pointing them at the control plane's address, so
		// the private zone needs no records for them.
		domain: "webhooks.\(name).\(site.privateDomain)"

		// hosts maps each entry of webhookServices (webhooks.cue) to its
		// hostname: the Service's name and namespace under domain, as a
		// Service's cluster DNS name is under svc.cluster.local. The hostname
		// is the SNI the Gateway routes on and a DNS name the webhook's
		// serving certificate carries.
		hosts: {
			for K, S in webhookServices {
				(K): "\(S.name).\(S.namespace).\(domain)"
			}
		}

		// urls maps each entry of webhookServices to the base URL a
		// webhook's clientConfig names; the webhook's path is appended.
		urls: {
			for K, H in hosts {
				(K): "https://\(H):\(port)"
			}
		}
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
