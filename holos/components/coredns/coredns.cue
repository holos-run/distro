package holos

import "strings"

// CoreDNS is the cluster DNS server. Talos deploys CoreDNS itself unless
// told not to, but its KubeCoreDNSConfig sets only enabled and image, and
// talosctl upgrade-k8s re-applies Talos's own Corefile. The Corefile is
// platform policy, so the platform owns CoreDNS: the control plane patch
// (providers/talos/patches/controlplane.yaml) disables Talos's, and
// this component deploys it from the CoreDNS project's chart, as the same
// kube-dns Service at the address every kubelet was given.
//
// Chart 1.49.0 ships CoreDNS 1.14.7, the version Talos 1.14.4 deploys.
CoreDNSChartVersion: "1.49.0"

// CoreDNS stays in kube-system, where Talos put it and where clients and
// network policies expect the kube-dns Service.
CoreDNSNamespace: "kube-system"

let Net = Cluster.network
let Site = Cluster.site

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: CoreDNSNamespace
	chart: {
		name:    "coredns"
		version: CoreDNSChartVersion
		release: "coredns"
		repository: {
			name: "coredns"
			url:  "https://coredns.github.io/helm"
		}
	}
	values: {
		fullnameOverride:    "coredns"
		k8sAppLabelOverride: "kube-dns"
		service: {
			name:      "kube-dns"
			clusterIP: Net.dnsServiceIP
		}
		replicaCount:      2
		priorityClassName: "system-cluster-critical"
		podDisruptionBudget: maxUnavailable: 1
		// One replica per worker where there are enough workers.
		topologySpreadConstraints: [{
			maxSkew:           1
			topologyKey:       "kubernetes.io/hostname"
			whenUnsatisfiable: "ScheduleAnyway"
			labelSelector: matchLabels: "app.kubernetes.io/instance": "coredns"
		}]
		// Talos's image, from registry.k8s.io rather than the chart's
		// default of Docker Hub, whose anonymous pull limit the garage's one
		// address shares.
		image: {
			repository: "registry.k8s.io/coredns/coredns"
			tag:        "v1.14.7"
		}
		// Talos's resources: a memory limit and no CPU limit, so DNS is not
		// throttled under load. Helm merges values with the chart's
		// defaults, so the chart's 100m CPU limit is removed with null.
		resources: {
			requests: {cpu: "100m", memory: "70Mi"}
			limits: {cpu: null, memory: "170Mi"}
		}

		servers: [
			{
				zones: [{zone: ".", use_tcp: true}]
				port: 53
				plugins: [
					{name: "errors"},
					{name: "health", configBlock: "lameduck 5s"},
					{name: "ready"},
					{name: "log", parameters: ".", configBlock: "class error"},
					{name: "prometheus", parameters: "0.0.0.0:9153"},
					{
						name:       "kubernetes"
						parameters: "\(Net.dnsDomain) in-addr.arpa ip6.arpa"
						configBlock: """
							pods insecure
							fallthrough in-addr.arpa ip6.arpa
							ttl 30
							"""
					},
					// Everything else goes to the node's resolver. On Talos
					// that is host DNS (forwardKubeDNSToHost), which forwards
					// to the site's resolvers.
					{name: "forward", parameters: ". /etc/resolv.conf", configBlock: "max_concurrent 1000"},
					{
						name:        "cache"
						parameters:  "30"
						configBlock: """
							disable success \(Net.dnsDomain)
							disable denial \(Net.dnsDomain)
							"""
					},
					{name: "loop"},
					{name: "reload"},
					{name: "loadbalance"},
				]
			},
			// The site's private zone goes straight to the site's resolvers,
			// which hold the records for the ingress Gateway's hostnames.
			// Explicit rather than left to host DNS, so it does not depend on
			// how the nodes' resolvers are set.
			{
				zones: [{zone: "\(Site.privateDomain).", use_tcp: true}]
				port: 53
				plugins: [
					{name: "errors"},
					{name: "log", parameters: ".", configBlock: "class error"},
					{name: "prometheus", parameters: "0.0.0.0:9153"},
					{name: "forward", parameters: ". \(strings.Join(Site.resolvers, " "))"},
					{name: "cache", parameters: "30"},
					{name: "loop"},
					{name: "reload"},
				]
			},
		]
	}
}).artifact]
