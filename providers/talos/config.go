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

// Pool is a group of identical workers. Each worker carries a pool label, so
// a Talos patch turns it into a node label, and a dedicated pool, such as one
// for the microVM sandbox class, is one more entry here rather than a change
// to the program.
type Pool struct {
	Name  string `json:"name"`
	Count int    `json:"count"`
	Size
	// Zones works as it does for the control plane, for example to keep a
	// microVM pool on chosen hosts.
	Zones []string `json:"nodes,omitempty"`
	// Addresses works as it does for the control plane.
	Addresses []string `json:"addresses,omitempty"`
}

// Config is the cluster's shape: its name, Talos version, node network and
// addresses, and the control plane and pools. It is read from a JSON file,
// since YAML would need a dependency, which also holds the compute
// provider's own settings; every field but the cluster name has a default,
// so the file only says what differs from the garage. Nothing in it is
// secret.
type Config struct {
	// Cluster names the Talos cluster. It prefixes every VM name and is the
	// group compute keeps the cluster's VMs in. Up to about six clusters
	// share the garage, so it has no default.
	Cluster string `json:"cluster"`
	// TalosVersion picks the Image Factory ISO, with the leading v.
	TalosVersion string `json:"talosVersion"`
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
	case !label.MatchString(c.Cluster) || len(c.Cluster) > 30:
		add("cluster %q: want a lowercase DNS label of at most 30 characters", c.Cluster)
	}
	if !version.MatchString(c.TalosVersion) {
		add("talosVersion %q: want a release tag such as %s", c.TalosVersion, DefaultTalosVersion)
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
