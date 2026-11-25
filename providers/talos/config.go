package talos

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"regexp"
	"strings"

	"go.holos.run/distro/providers/infra"
)

// DefaultTalosVersion is the Talos release the distro targets.
const DefaultTalosVersion = "v1.14.4"

// Size is the shape of one VM.
type Size struct {
	Cores     int `json:"cores"`
	MemoryMiB int `json:"memoryMiB"`
	DiskGiB   int `json:"diskGiB"`
}

// ControlPlane is the control plane group. The plan is one control plane VM,
// but etcd needs an odd count, so the count is kept and checked for that.
type ControlPlane struct {
	Count int `json:"count"`
	Size
	// Zones, when set, are the zones this group's VMs are placed in instead
	// of every zone compute spreads VMs across. On Proxmox a zone is a node,
	// which is why the key is nodes.
	Zones []string `json:"nodes,omitempty"`
	// Addresses, when set, gives each VM of the group its address, in
	// order, instead of taking the next ones after Config.FirstAddress.
	Addresses []string `json:"addresses,omitempty"`
}

// Pool is a group of identical workers. Each worker carries a pool label,
// which a Talos patch turns into a node label. A dedicated pool, such as one
// for the microVM sandbox class, is one more entry here, kept to its purpose
// by Taints and AdminLabels.
type Pool struct {
	Name  string `json:"name"`
	Count int    `json:"count"`
	Size
	// Zones works as it does for the control plane, for example to keep a
	// microVM pool on chosen hosts.
	Zones []string `json:"nodes,omitempty"`
	// Addresses works as it does for the control plane.
	Addresses []string `json:"addresses,omitempty"`
	// Taints, Labels and AdminLabels are for the pool's nodes, in the form
	// kubectl takes: key=value:Effect and key=value. Nothing here uses them:
	// cluster.sh reads all three from the file, so Validate and the script
	// accept the same strings. The kubelet registers with the taints. Talos
	// sets the labels as the node, so a node can change its own. cluster.sh
	// sets the admin labels with the admin kubeconfig, and NodeRestriction
	// keeps a node from changing them.
	Taints      []string `json:"taints,omitempty"`
	Labels      []string `json:"labels,omitempty"`
	AdminLabels []string `json:"adminLabels,omitempty"`
}

// Config is the cluster's shape: its name, versions, endpoint, node network and
// addresses, and the control plane and pools. It is read from a JSON file,
// since YAML would need a dependency, which also holds the compute
// provider's own settings; every field but the cluster name has a default,
// so a file need only say what differs from the garage. Nothing in it is
// secret.
type Config struct {
	// Cluster names the Talos cluster. It prefixes every VM name and is the
	// group compute keeps the cluster's VMs in. Clusters share the garage,
	// so it has no default.
	Cluster string `json:"cluster"`
	// TalosVersion picks the Image Factory ISO, with the leading v.
	TalosVersion string `json:"talosVersion"`
	// Endpoint, when set, is the DNS name of the cluster's Kubernetes
	// endpoint, and so of its service account issuer, in place of the control
	// plane's address. Nothing here uses it or KubernetesVersion: cluster.sh
	// reads both from the file, so Validate and the script accept the same
	// strings. They are pointers so that an empty string is refused, not
	// taken for a field left out: a cluster keeps the endpoint it is
	// generated with.
	Endpoint *string `json:"endpoint,omitempty"`
	// KubernetesVersion, when set, is the Kubernetes release the cluster is
	// generated with, without a leading v, in place of cluster.sh's default.
	KubernetesVersion *string `json:"kubernetesVersion,omitempty"`
	// Network names the network the nodes attach to. On Proxmox it is the
	// bridge of the SDN vnet the node subnet lives on, which is why the key
	// is bridge. Its default is the compute provider's.
	Network string `json:"bridge"`
	// FirstAddress is where the cluster's node addresses start. VMs take
	// consecutive addresses in the order cp-1, cp-2, ..., then each pool's
	// workers, skipping the groups that list their own Addresses. Its
	// default is the compute provider's.
	FirstAddress string `json:"firstAddress"`

	ControlPlane ControlPlane `json:"controlPlane"`
	Pools        []Pool       `json:"pools"`
}

// Default returns one control plane VM and three general workers. The sizes
// follow the Talos Proxmox guide's minimums with room for the platform: 2
// cores and 8 GiB for a control plane, 4 cores and 16 GiB for a worker.
// Workers were 8 GiB until Quay, at 3.6 to 3.8 GiB on its own, left its node
// at 98% of its memory requests before Substrate and kagent; 16 GiB also
// leaves two workers room for a third's pods while it restarts. A control
// plane runs etcd and the API server, controller manager and scheduler.
// Measured on a running cluster, the node's working set peaked at about 2.5
// GiB, mostly the API server's heap, and the rest of the 6 GiB it had then
// was reclaimable page cache. The rule in docs/control-plane-memory.md gives
// 6 GiB for that peak; the default is 8 GiB for the watches Substrate and
// kagent add. That page has the measurements, why Proxmox shows 99% used,
// and the sizing rule to apply when the workload grows. The cluster name is
// left empty on purpose, and the network and first address are left to the
// compute provider.
func Default() Config {
	return Config{
		TalosVersion: DefaultTalosVersion,
		ControlPlane: ControlPlane{Count: 1, Size: Size{Cores: 2, MemoryMiB: 8192, DiskGiB: 32}},
		Pools: []Pool{
			{Name: "general", Count: 3, Size: Size{Cores: 4, MemoryMiB: 16384, DiskGiB: 64}},
		},
	}
}

// Decode reads a JSON config file over v, which holds the defaults. Unknown
// fields are an error, so a misspelled key fails instead of being silently
// ignored. A pools list in the file replaces the default pools as a whole.
// v is usually a struct that embeds Config beside the compute provider's
// settings, which share the file.
func Decode(path string, v any) error {
	if path == "" {
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	dec := json.NewDecoder(f)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	return nil
}

// label is a lowercase DNS label. VM names and labels are both built from the
// cluster and pool names, and VM names must be DNS names.
var label = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`)

// version is a Talos release tag such as v1.14.4.
var version = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$`)

// endpointName is a lowercase DNS name of at least two labels, with no trailing
// dot. Its last label starts with a letter, so an IPv4 address is not one.
// cluster.sh holds the same pattern.
var endpointName = regexp.MustCompile(`\A([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?\z`)

// kubernetesVersion is a Kubernetes release such as 1.37.1, as talosctl takes
// it. cluster.sh holds the same pattern.
var kubernetesVersion = regexp.MustCompile(`\A[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?\z`)

// poolTaint is a taint as kubectl takes it, whose value may be empty or left
// out. cluster.sh holds the same pattern.
var poolTaint = regexp.MustCompile(`\A([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*/)?[A-Za-z0-9]([A-Za-z0-9_.-]{0,61}[A-Za-z0-9])?(=([A-Za-z0-9]([A-Za-z0-9_.-]{0,61}[A-Za-z0-9])?)?)?:(NoSchedule|PreferNoSchedule|NoExecute)\z`)

// poolLabel is a label as kubectl takes it, whose value may be empty or left
// out. cluster.sh holds the same pattern.
var poolLabel = regexp.MustCompile(`\A([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*/)?[A-Za-z0-9]([A-Za-z0-9_.-]{0,61}[A-Za-z0-9])?(=([A-Za-z0-9]([A-Za-z0-9_.-]{0,61}[A-Za-z0-9])?)?)?\z`)

// What a pool's labels may not be is nodePoolLabel, which cluster.sh sets, and
// any of Kubernetes's own, reservedLabel, but those kubeletLabel matches. Most
// of them NodeRestriction refuses from a node, and with each every other label
// Talos sets in the same request. The rest, region and zone among them, are set
// by cluster.sh or the kubelet. No node may set an adminLabel. cluster.sh holds
// all four.
const nodePoolLabel = "holos.run/nodepool"

var (
	reservedLabel = regexp.MustCompile(`\A([a-z0-9.-]+\.)?(kubernetes|k8s)\.io/`)
	kubeletLabel  = regexp.MustCompile(`\A([a-z0-9.-]+\.)?(node|kubelet)\.kubernetes\.io/`)
	adminLabel    = regexp.MustCompile(`\A([a-z0-9.-]+\.)?node-restriction\.kubernetes\.io/`)
)

// maxName is the length of the longest DNS name, and cluster.sh's limit on
// every string it checks.
const maxName = 253

// ValidClusterName reports whether name can name a cluster. It decides what
// Validate accepts, and it keeps a name from reaching a path as anything but
// one path element, since a valid name holds no dot or slash.
func ValidClusterName(name string) bool {
	return label.MatchString(name) && len(name) <= 30
}

// Validate reports every problem in the config at once, so one run shows
// everything to fix. It includes the address rules, with checkAddress the
// compute provider's rule for a node address, so a bad address is refused
// before the program talks to the provider at all. A nil checkAddress checks
// only what the config itself says.
func (c Config) Validate(checkAddress func(netip.Addr) error) error {
	var errs []error
	add := func(format string, a ...any) { errs = append(errs, fmt.Errorf(format, a...)) }

	switch {
	case c.Cluster == "":
		add("cluster is required: name the cluster with -cluster or in the config")
	case !ValidClusterName(c.Cluster):
		add("cluster %q: want a lowercase DNS label of at most 30 characters", c.Cluster)
	}
	if !version.MatchString(c.TalosVersion) {
		add("talosVersion %q: want a release tag such as %s", c.TalosVersion, DefaultTalosVersion)
	}
	if e := c.Endpoint; e != nil && (len(*e) > maxName || !endpointName.MatchString(*e)) {
		add("endpoint %q: want a lowercase DNS name alone, such as api.example.internal, with no scheme, port or trailing dot", *e)
	}
	if v := c.KubernetesVersion; v != nil && (len(*v) > maxName || !kubernetesVersion.MatchString(*v)) {
		add("kubernetesVersion %q: want a release such as 1.37.1, without a leading v", *v)
	}
	if c.Network == "" || strings.ContainsAny(c.Network, ",=; ") {
		add("bridge %q: want a plain name", c.Network)
	}

	cp := c.ControlPlane
	if cp.Count < 1 || cp.Count%2 == 0 {
		add("controlPlane.count %d: want an odd number, at least 1, for etcd quorum", cp.Count)
	}
	errs = append(errs, cp.Size.validate("controlPlane")...)

	seen := map[string]bool{}
	for i, p := range c.Pools {
		where := fmt.Sprintf("pools[%d]", i)
		switch {
		case !label.MatchString(p.Name) || len(p.Name) > 20:
			// With a 30 character cluster name and a counter, 20 keeps
			// VM names inside the 63 characters of a DNS label.
			add("%s.name %q: want a lowercase DNS label of at most 20 characters", where, p.Name)
		case p.Name == controlPlaneName:
			add("%s.name %q is reserved for the control plane", where, p.Name)
		case seen[p.Name]:
			add("%s.name %q is used twice", where, p.Name)
		}
		seen[p.Name] = true
		if p.Count < 0 {
			add("%s.count %d: want zero or more", where, p.Count)
		}
		errs = append(errs, p.Size.validate(where)...)
		errs = append(errs, p.validateNodes(where)...)
	}
	if len(errs) == 0 {
		// Addresses depend on the counts, so they are only checked once
		// the counts are known to be sane.
		if _, err := c.addresses(checkAddress); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

// validateNodes checks the pool's taints and labels. cluster.sh checks the same
// when it reads them. A node may have one taint of a key and effect, and one
// label of a key.
func (p Pool) validateNodes(where string) []error {
	var errs []error
	list := func(field string, entries []string, pattern *regexp.Regexp, want string, refuse func(key string) string) {
		seen := map[string]bool{}
		for i, e := range entries {
			why := want
			if len(e) <= maxName && pattern.MatchString(e) {
				key, effect := e, ""
				if c := strings.LastIndexByte(e, ':'); c >= 0 {
					key, effect = e[:c], e[c:]
				}
				key, _, _ = strings.Cut(key, "=")
				if why = refuse(key); why == "" && seen[key+effect] {
					why = "given twice"
				}
				seen[key+effect] = true
			}
			if why != "" {
				errs = append(errs, fmt.Errorf("%s.%s[%d] %q: %s", where, field, i, e, why))
			}
		}
	}
	list("taints", p.Taints, poolTaint, "want a taint such as example.com/key=value:NoSchedule", func(string) string { return "" })
	list("labels", p.Labels, poolLabel, "want a label such as example.com/key=value", func(key string) string {
		switch {
		case key == nodePoolLabel:
			return "cluster.sh sets this label"
		case adminLabel.MatchString(key):
			return "a node may not set this label on itself; put it in adminLabels"
		case reservedLabel.MatchString(key) && !kubeletLabel.MatchString(key):
			return "Kubernetes keeps this label for itself"
		}
		return ""
	})
	list("adminLabels", p.AdminLabels, poolLabel, "want a label such as node-restriction.kubernetes.io/key=value", func(key string) string {
		if !adminLabel.MatchString(key) {
			return "want a node-restriction.kubernetes.io/ label, since a node can set any other on itself"
		}
		return ""
	})
	return errs
}

func (s Size) validate(where string) []error {
	var errs []error
	// The Talos Proxmox guide: minimum 2 cores and 2 GiB.
	if s.Cores < 2 {
		errs = append(errs, fmt.Errorf("%s.cores %d: Talos needs at least 2", where, s.Cores))
	}
	if s.MemoryMiB < 2048 {
		errs = append(errs, fmt.Errorf("%s.memoryMiB %d: Talos needs at least 2048", where, s.MemoryMiB))
	}
	// Talos's own partitions need about 10 GiB before any workload.
	if s.DiskGiB < 10 {
		errs = append(errs, fmt.Errorf("%s.diskGiB %d: Talos needs at least 10", where, s.DiskGiB))
	}
	return errs
}

// addresses assigns every VM its address, in Specs order: the control plane
// first, then each pool. A group with Addresses uses those; every other group
// takes the next consecutive addresses from FirstAddress. Every address must
// pass check, when it is given, and be used once.
func (c Config) addresses(check func(netip.Addr) error) ([]netip.Addr, error) {
	var errs []error
	var out []netip.Addr
	next, err := netip.ParseAddr(c.FirstAddress)
	if err != nil {
		errs = append(errs, fmt.Errorf("firstAddress %q: want an IPv4 address", c.FirstAddress))
	}
	seen := map[netip.Addr]string{}
	group := func(where string, count int, explicit []string) {
		if len(explicit) > 0 && len(explicit) != count {
			errs = append(errs, fmt.Errorf("%s.addresses: %d given for %d VMs", where, len(explicit), count))
			return
		}
		for i := range count {
			var a netip.Addr
			if len(explicit) > 0 {
				p, err := netip.ParseAddr(explicit[i])
				if err != nil {
					errs = append(errs, fmt.Errorf("%s.addresses[%d] %q: want an IPv4 address", where, i, explicit[i]))
					continue
				}
				a = p
			} else {
				if !next.IsValid() {
					return
				}
				a = next
				next = next.Next()
			}
			name := fmt.Sprintf("%s VM %d", where, i+1)
			if check != nil {
				if err := check(a); err != nil {
					errs = append(errs, fmt.Errorf("%s: %w", name, err))
				}
			}
			if prev, dup := seen[a]; dup {
				errs = append(errs, fmt.Errorf("%s: address %s is also given to %s", name, a, prev))
			}
			seen[a] = name
			out = append(out, a)
		}
	}
	group("controlPlane", c.ControlPlane.Count, c.ControlPlane.Addresses)
	for i, p := range c.Pools {
		group(fmt.Sprintf("pools[%d]", i), p.Count, p.Addresses)
	}
	return out, errors.Join(errs...)
}

// Labels. Compute records them on each VM and reports them back; the Talos
// patches turn the pool into a node label.
const (
	// LabelRole is RoleControlPlane or RoleWorker.
	LabelRole = "role"
	// LabelPool is a worker's pool.
	LabelPool = "pool"

	RoleControlPlane = "controlplane"
	RoleWorker       = "worker"

	controlPlaneName = "cp"
)

// Specs expands the config into the VMs it asks for, named <cluster>-cp-<n>
// and <cluster>-<pool>-<n> from 1, with their role and pool labels, sizes,
// network, address and zones. The image and description are the caller's to
// fill in. The config must be valid.
func (c Config) Specs() ([]infra.VMSpec, error) {
	addrs, err := c.addresses(nil)
	if err != nil {
		return nil, err
	}
	var specs []infra.VMSpec
	add := func(name string, labels []infra.Label, s Size, zones []string) {
		specs = append(specs, infra.VMSpec{
			Name:    name,
			Labels:  labels,
			Size:    infra.Size{Cores: s.Cores, MemoryMiB: s.MemoryMiB},
			Disks:   []infra.Disk{{SizeGiB: s.DiskGiB}},
			Network: c.Network,
			Address: addrs[len(specs)],
			Zones:   zones,
		})
	}
	for i := range c.ControlPlane.Count {
		add(vmName(c.Cluster, controlPlaneName, i), []infra.Label{{Key: LabelRole, Value: RoleControlPlane}},
			c.ControlPlane.Size, c.ControlPlane.Zones)
	}
	for _, p := range c.Pools {
		for i := range p.Count {
			add(vmName(c.Cluster, p.Name, i), []infra.Label{{Key: LabelRole, Value: RoleWorker}, {Key: LabelPool, Value: p.Name}},
				p.Size, p.Zones)
		}
	}
	return specs, nil
}

// vmName is the name of the i-th VM, from 0, of a group: the control plane
// or a pool.
func vmName(cluster, group string, i int) string {
	return fmt.Sprintf("%s-%s-%d", cluster, group, i+1)
}
