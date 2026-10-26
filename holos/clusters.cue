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
	// ceph is the Ceph cluster the site's hosts run, which ceph-csi-rbd
	// provisions volumes from. The driver creates nothing on the Ceph side.
	ceph: {
		// fsid names the Ceph cluster; ceph-csi calls it the clusterID.
		fsid: =~"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
		// monitors are the monitors' v1 addresses, port 6789. The kernel
		// RBD client maps an image with the msgr1 protocol unless told
		// otherwise, so these work for the provisioner and the node plugin.
		monitors: [...string] & [_, ...]
	}
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
		// the block's first unless set. It is reserved, not left to LB IPAM:
		// cilium-resources gives it a pool of its own that only the gateway's
		// Service draws from, so the private zone's *.<privateDomain> record
		// and the control plane's webhook host entries (talos.cue) stay right
		// across a recreate of the Gateway or the cluster.
		gateway: net.IPv4 & string | *start

		// The block runs from start to stop and gateway lies in it, so a bad
		// value fails cue vet rather than leaving the gateway's Service
		// Pending. The addresses are compared as numbers.
		_n: {
			start: (#IPv4Number & {ip: loadBalancer.start}).n
			stop: (#IPv4Number & {ip: loadBalancer.stop}).n
			gateway: (#IPv4Number & {ip: loadBalancer.gateway}).n
		}
		_stopNotBeforeStart: true & _n.start <= _n.stop
		_gatewayInBlock:     true & _n.start <= _n.gateway && _n.gateway <= _n.stop
	}

	// ceph is the cluster's share of the site's Ceph cluster: the RBD pool
	// its volumes are images in and the Ceph client it authenticates as,
	// whose caps are profile rbd on that pool. The client's key is never in
	// git; it is put in Secret <namespace>/<secret> by hand (README.md,
	// "Storage"). A second cluster on the site takes a pool of its own.
	ceph: {
		pool:   string
		user:   string
		secret: string | *"ceph-client-\(user)"
	}

	// webhooks is how the API server reaches this cluster's admission
	// webhooks. The control plane is off the pod network (ADR 0001), so every
	// webhook's clientConfig is a URL on the ingress Gateway's address
	// (loadBalancer.gateway), whose webhooks listener passes TLS through to
	// the webhook's Pods, routed on SNI. webhooks.cue has the hostname scheme
	// and the registry of webhook Services.
	webhooks: {
		// enforcing is ADR 0001's provisioning flag, one value for every
		// webhook in the cluster. false while the cluster bootstraps: every
		// webhook fails open (Ignore), so the API server admits a request it
		// cannot get a webhook's answer for. Set true once every webhook
		// answers through the Gateway; every webhook then renders Fail. A
		// cluster built from scratch starts false: with Fail, cert-manager's
		// webhook would refuse the private CA's resources, which the Gateway
		// it is reached through depends on (README.md, "Admission webhooks").
		enforcing:     bool | *false
		failurePolicy: "Ignore" | "Fail"
		if enforcing {failurePolicy: "Fail"}
		if !enforcing {failurePolicy: "Ignore"}

		// timeoutSeconds bounds how long the API server waits for a webhook,
		// in place of the default ten seconds, so a request waits briefly
		// rather than stalling when the webhook is unreachable.
		timeoutSeconds: int & >=1 & <=30 | *3

		// port is the Gateway's webhooks listener, on the Gateway's address
		// beside its 443 and 80. Not 443, which the HTTPS listener terminates.
		port: 9443

		// domain is the suffix of every webhook hostname in the cluster. The
		// API server resolves the names through Talos static host entries on
		// the control plane (talos.cue), which point them at the Gateway's
		// address, so it does not depend on the site's resolver. The private
		// zone's *.<privateDomain> wildcard gives the same answer elsewhere.
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

// #IPv4Number is an IPv4 address as a number, to compare addresses by: as
// strings, 10.20.0.4 sorts after 10.20.0.30. (net.CompareIP is newer than
// the CUE that holos v0.106.0 evaluates with.)
#IPv4Number: {
	ip: net.IPv4 & string
	let B = net.ToIP4(ip)
	n: ((B[0]*256+B[1])*256+B[2])*256 + B[3]
}

sites: [NAME=string]: #Site & {name: NAME}
clusters: [NAME=string]: #Cluster & {name: NAME}

sites: garage: {
	privateDomain: "bank.internal"
	resolvers: ["192.168.2.1"]
	// The Proxmox hosts' Ceph: r620a to c, monitors on the hosts'
	// 10.15.15.0/24 mesh, which the k8s vnet routes to through the hosts.
	ceph: {
		fsid: "c9eeedfd-1b9d-4796-aff3-1e6a0e994ff1"
		monitors: ["10.15.15.1:6789", "10.15.15.2:6789", "10.15.15.3:6789"]
	}
}

// treasury is the first garage cluster: treasury-cp-1 at 10.20.0.50 and
// treasury-general-1 to -3 at .51 to .53 on the k8s vnet. It takes the first
// four addresses of the ingress range.
clusters: treasury: {
	site: sites.garage
	loadBalancer: {
		start: "10.20.0.30"
		stop:  "10.20.0.33"
	}
	// Every webhook answers through the gateway's webhooks listener, so the
	// cluster enforces. A rebuild starts with this false (README.md,
	// "Admission webhooks").
	webhooks: enforcing: true
	// Volumes are images in k8s-rbd, as client.k8s.
	ceph: {
		pool: "k8s-rbd"
		user: "k8s"
	}
}
