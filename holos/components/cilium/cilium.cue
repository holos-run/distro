package holos

// Cilium is the cluster's CNI and its kube-proxy replacement.
//
// 1.20 is the latest stable minor. Its tested Kubernetes versions stop at
// 1.36; 1.37 is first tested by 1.21, still a pre-release (1.21.0-pre.3).
// Cilium's policy is that newer Kubernetes versions depend on Kubernetes'
// own backward compatibility, and 1.20 is reported working on 1.37
// (cilium/cilium#48694). Move to 1.21 once it is released.
CiliumVersion: "1.20.4"

// Cilium runs in kube-system, the one namespace Talos exempts from its
// baseline Pod Security enforcement, so the agent's privileges need no
// namespace label.
CiliumNamespace: "kube-system"

// offControlPlane keeps a pod off nodes labeled
// node-role.kubernetes.io/control-plane, which Talos sets on every control
// plane. Only the operator carries it: the agent and envoy run on the
// control plane, as upstream Talos runs its CNI there, so it turns Ready and
// the API server reaches Services (ADR 0003). Talos's default NoSchedule
// taint keeps everything else off.
let offControlPlane = {
	key:      "node-role.kubernetes.io/control-plane"
	operator: "DoesNotExist"
}

holos: spec: artifacts: [(#HelmArtifact & {
	namespace: CiliumNamespace
	chart: {
		name:    "cilium"
		version: CiliumVersion
		release: "cilium"
		repository: {
			name: "cilium"
			url:  "https://helm.cilium.io"
		}
	}
	values: {
		// Talos: https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium
		ipam: mode: "kubernetes"
		kubeProxyReplacement: true
		// KubePrism, the node-local API server load balancer, so the agent
		// reaches the API server without kube-proxy or a Service.
		k8sServiceHost: "localhost"
		k8sServicePort: 7445
		securityContext: capabilities: {
			ciliumAgent: ["CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN", "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"]
			cleanCiliumState: ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
		}
		// Talos mounts cgroup2 itself.
		cgroup: {
			autoMount: enabled: false
			hostRoot: "/sys/fs/cgroup"
		}

		// A VXLAN overlay, as ADR 0001 decided. The control plane is a member
		// of it: its agent gives the API server, a host-network static pod,
		// the routes and Service translation every other node has.
		routingMode:    "tunnel"
		tunnelProtocol: "vxlan"

		// Istio ambient chaining:
		// https://istio.io/latest/docs/ambient/install/platform-prerequisites/#cilium
		// istio-cni adds itself to the CNI config, so Cilium must not own
		// /etc/cni/net.d.
		cni: exclusive: false
		// Socket load balancing in pod namespaces would resolve a Service to
		// a backend before ztunnel sees the connection. Host-network
		// processes, the API server among them, keep it: the kube-proxy
		// replacement turns it on although the rendered bpf-lb-sock reads
		// false (cilium-dbg status --verbose: Socket LB Enabled, coverage
		// Hostns-only).
		socketLB: hostNamespaceOnly: true
		// BPF masquerading is unsupported under ambient; Cilium's iptables
		// masquerading (the default) stays on.
		bpf: masquerade: false

		// LoadBalancer addresses from the cluster's CiliumLoadBalancerIPPools
		// (the cilium-resources component), announced on the node network
		// with ARP.
		// The kube-proxy replacement handles externalIPs itself, so the
		// separate externalIPs switch is not set.
		l2announcements: enabled: true
		// Each announced Service holds a lease the agents renew through the
		// API server; the default 10/20 is too low for that. Cilium's L2
		// announcement docs size it at about leases / renew deadline plus
		// the agent's base load.
		k8sClientRateLimit: {
			qps:   20
			burst: 40
		}

		// CIDR rules match node addresses too, so a NetworkPolicy's ipBlock
		// on the control plane's address, which carries a node identity once
		// its agent runs, still admits egress to the API server
		// (Cluster.apiServer, toolhive's proxy runner).
		policyCIDRMatchMode: ["nodes"]

		// Hubble's certificates come from the in-cluster certgen Job rather
		// than helm template, which would put a fresh key in deploy/ on every
		// render.
		hubble: tls: auto: method: "cronJob"

		// The agent and envoy DaemonSets tolerate every taint and run on
		// every node, the control plane included. Envoy keeps the chart's
		// cilium.io/no-schedule term, stated since the list replaces the
		// chart's. The operator, a Deployment whose chart tolerations
		// include the control plane's taint, keeps off it.
		envoy: affinity: nodeAffinity: requiredDuringSchedulingIgnoredDuringExecution: nodeSelectorTerms: [{
			matchExpressions: [
				{key: "cilium.io/no-schedule", operator: "NotIn", values: ["true"]},
			]
		}]
		operator: affinity: nodeAffinity: requiredDuringSchedulingIgnoredDuringExecution: nodeSelectorTerms: [{
			matchExpressions: [offControlPlane]
		}]
	}
}).artifact]
