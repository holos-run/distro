package holos

import (
	"net"

	proj "go.holos.run/distro/holos/projects"
)

// Sites and clusters are the platform's per-site and per-cluster data. A
// component reads its cluster as Cluster (components/component.cue), so
// adding a cluster starts with a new entry here (README.md, "Adding a
// cluster"); platform/platform.cue renders each cluster's own list of
// components, clusterRegistry (registry.cue).

// #Site is a place clusters run, with the network services they share.
#Site: {
	name: string
	// privateDomain is the site's private DNS zone. Every platform hostname
	// is under it, in its cluster's ingressDomain (#Cluster), and the LAN
	// resolver points each *.<ingressDomain> at that cluster's ingress
	// Gateway. Email addresses are identities, not hostnames, and are
	// <user>@<privateDomain> on every cluster of the site.
	privateDomain: string
	// resolvers serve privateDomain. CoreDNS forwards the zone to them.
	resolvers: [...net.IPv4 & string] & [_, ...]
	// ceph is the Ceph cluster the site's hosts run, which ceph-csi-rbd
	// provisions volumes from. The driver creates no pool and no user.
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

	// metadata.labels are what a ProjectClaim's clusterSelector selects on,
	// under Kubernetes' rules for a label. Two are set from the data, as
	// Kubernetes sets kubernetes.io/metadata.name, so any cluster can be named
	// without declaring anything; a cluster adds its own here. name stays a
	// top-level field: it is the label's source, and moving it would rewrite
	// every reader for no gain (Second_Cluster interview Q12).
	metadata: labels: proj.#Labels & {
		"holos.run/cluster-name": name
		"holos.run/site":         site.name
	}

	// components names the optional entries of the registry the cluster
	// takes, beside the stack up to standard, which every cluster takes
	// (#Registration.priority). A name outside #OptionalComponents, whether a
	// typo, an entry further down the stack, a claim or a binding, fails cue
	// vet. The order here does not matter: a cluster syncs them in the registry's
	// order (clusterRegistry, registry.cue).
	components: [...or(#OptionalComponents)]

	// ingressDomain is the zone the cluster's hostnames are in: every
	// service is <service>.<ingressDomain>, by default
	// <service>.<cluster>.<privateDomain> (the Cluster_Qualified_Hostnames
	// planning project), so two clusters on one site never claim the same
	// name. The ingress Gateway's wildcard certificate is *.<ingressDomain>
	// (components/ingress.cue).
	ingressDomain: string | *"\(name).\(site.privateDomain)"

	// kubernetesVersion is the version Talos runs, pinned in
	// providers/talos/cluster.sh. Charts see it as
	// Capabilities.KubeVersion.
	kubernetesVersion: string | *"1.37.1"

	// serviceAccountIssuer is the iss of the cluster's ServiceAccount tokens,
	// as the API server's discovery document (/.well-known/openid-configuration)
	// gives it. Talos sets it to the control plane endpoint, not the in-cluster
	// https://kubernetes.default.svc, so a component that verifies those
	// tokens itself, as Substrate's API server does, is told it here. Recorded,
	// not chosen: it is the endpoint providers/talos/cluster.sh
	// generates the cluster with.
	serviceAccountIssuer: =~"^https://"

	// apiServer is the address and port the API server listens on, the
	// endpoints of the default/kubernetes Service, which a NetworkPolicy
	// admitting a pod's egress to the API server names: the API server is a
	// host-network static pod, so no pod selector reaches it, and Cilium
	// matches its node's address against an ipBlock under
	// policyCIDRMatchMode nodes (components/cilium). Recorded, not chosen,
	// as serviceAccountIssuer is.
	apiServer: {
		address: string
		port:    int | *6443
	}

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
	// (10.20.0.30 to .49 in the garage, five blocks of four addresses).
	// Cilium LB IPAM hands these out to LoadBalancer Services and announces
	// them with ARP.
	loadBalancer: {
		start: net.IPv4 & string
		stop:  net.IPv4 & string
		// gateway is the ingress Gateway's address (components/ingress.cue),
		// the block's first unless set. It is reserved, not left to LB IPAM:
		// cilium-resources gives it a pool of its own that only the gateway's
		// Service draws from, so the private zone's *.<ingressDomain> record
		// stays right across a recreate of the Gateway or the cluster.
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
	// git. It is a platform secret, <secret>, in the management namespace,
	// put there once per cluster at bootstrap from ceph auth get-key, and an
	// ExternalSecret copies it into the driver's namespace under the same
	// name (README.md, "Storage"). Each cluster on the site takes a pool and
	// a user of its own, <cluster>-rbd and <cluster>; treasury's are the
	// exception recorded on its entry.
	ceph: {
		pool:   string
		user:   string
		secret: string | *"ceph-client-\(user)"
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
// four addresses of the ingress range, and every optional component.
clusters: treasury: {
	site: sites.garage
	components: [
		"substrate",
		"substrate-shim",
		"kagent-crds",
		"kagent",
		"toolhive-crds",
		"toolhive-operator",
		"toolhive",
	]
	loadBalancer: {
		start: "10.20.0.30"
		stop:  "10.20.0.33"
	}
	// The control plane endpoint, treasury-cp-1.
	serviceAccountIssuer: "https://10.20.0.50:6443"
	apiServer: address: "10.20.0.50"
	// Volumes are images in k8s-rbd, as client.k8s. These names are a recorded
	// exception to <cluster>-rbd and <cluster>: they came first, and the rename
	// planned in the Talos_Kubernetes_Layer planning project died with it.
	ceph: {
		pool: "k8s-rbd"
		user: "k8s"
	}
}

// cartography is the second garage cluster, in slot 2: cartography-cp-1 at
// 10.20.0.60 and cartography-general-1 to -3 at .61 to .63 on the k8s vnet. It
// takes the second block of the ingress range and every optional component, and
// shares only the site with treasury.
clusters: cartography: {
	site: sites.garage
	components: [
		"substrate",
		"substrate-shim",
		"kagent-crds",
		"kagent",
		"toolhive-crds",
		"toolhive-operator",
		"toolhive",
	]
	loadBalancer: {
		start: "10.20.0.34"
		stop:  "10.20.0.37"
	}
	// The control plane endpoint, cartography-cp-1.
	serviceAccountIssuer: "https://10.20.0.60:6443"
	apiServer: address: "10.20.0.60"
	// Volumes are images in cartography-rbd, as client.cartography.
	ceph: {
		pool: "cartography-rbd"
		user: "cartography"
	}
}
