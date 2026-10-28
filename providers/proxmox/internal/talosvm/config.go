// Package talosvm creates, lists and destroys the Talos VMs of one cluster on
// Proxmox VE. It is the library behind providers/proxmox/cmd/talosvm.
//
// The VMs boot the Talos nocloud ISO into maintenance mode with a static /32
// address from a cloud-init network snippet the program writes. Talos machine configuration is
// applied afterwards with talosctl, so nothing here knows about certificates,
// endpoints or patches.
//
// Every VM this package creates carries Proxmox tags that say so: TagManaged,
// a talosvm-cluster-<name> tag, a role tag and, for workers, a pool tag.
// Destroy and list only ever look at VMs carrying both the managed tag and
// the cluster's tag, so the garage can be rebuilt without touching anything
// else that lives on the same hosts.
package talosvm

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"regexp"
	"strings"
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
	// Nodes, when set, overrides Config.Nodes for this group.
	Nodes []string `json:"nodes,omitempty"`
	// Addresses, when set, gives each VM of the group its address, in
	// order, instead of taking the next ones after Config.FirstAddress.
	Addresses []string `json:"addresses,omitempty"`
}

// Pool is a group of identical workers. Each worker carries a pool tag, so a
// later Talos patch can turn the tag into a node label and a dedicated pool,
// such as one for the microVM sandbox class, is one more entry here rather
// than a change to the program.
type Pool struct {
	Name  string `json:"name"`
	Count int    `json:"count"`
	Size
	// Nodes, when set, overrides Config.Nodes for this pool, for example to
	// keep a microVM pool on chosen hosts.
	Nodes []string `json:"nodes,omitempty"`
	// Addresses works as it does for the control plane.
	Addresses []string `json:"addresses,omitempty"`
}

// Config is everything create needs. It is read from a JSON file, since YAML
// would need a dependency, and every field but the cluster name has a
// default, so the file only says what differs from the garage. Nothing in it
// is secret: the endpoint and token come from the environment.
type Config struct {
	// Cluster names the Talos cluster. It prefixes every VM name and becomes
	// the cluster tag that scopes list and destroy. Up to about six clusters
	// share the garage, so it has no default.
	Cluster string `json:"cluster"`
	// TalosVersion picks the Image Factory ISO, with the leading v.
	TalosVersion string `json:"talosVersion"`
	// Nodes is the Proxmox nodes VMs are spread across, round robin. Empty
	// means every node that is online, sorted by name.
	Nodes []string `json:"nodes,omitempty"`
	// DiskStorage holds the VM disks, EFI vars and cloud-init drive; it must
	// exist on every node VMs are placed on. ISOStorage holds the Talos ISO
	// and must allow the iso content type; when it is shared, the ISO is
	// downloaded once for every node.
	DiskStorage string `json:"diskStorage"`
	ISOStorage  string `json:"isoStorage"`
	// SnippetStorage holds each VM's cloud-init network snippet. It must
	// allow snippets content and be the storage whose snippets directory
	// talosvm's -snippets-dir is a mount of.
	SnippetStorage string `json:"snippetStorage"`
	// DiskSSD sets ssd=1 on the system disk, which the Talos guide suggests
	// for SSD-backed storage. discard=on is always set.
	DiskSSD bool `json:"diskSSD"`
	// Bridge is the bridge net0 attaches to: the SDN vnet the node subnet
	// lives on.
	Bridge string `json:"bridge"`
	// Nameserver and SearchDomain go into the network snippet with the
	// address.
	Nameserver   string `json:"nameserver"`
	SearchDomain string `json:"searchDomain"`
	// FirstAddress is where the cluster's node addresses start. VMs take
	// consecutive addresses in the order cp-1, cp-2, ..., then each pool's
	// workers, skipping the groups that list their own Addresses.
	FirstAddress string `json:"firstAddress"`

	ControlPlane ControlPlane `json:"controlPlane"`
	Pools        []Pool       `json:"pools"`
}

// Default returns the garage defaults: one control plane VM and three general
// workers, disks on local-zfs, the ISO and snippets on the shared garage NFS
// storage, and
// the k8s vnet. The sizes follow the Talos Proxmox guide's minimums with room
// for the platform: 2 cores and 6 GiB for a control plane, 4 cores and 16 GiB
// for a worker. Workers were 8 GiB until Quay, at 3.6 to 3.8 GiB on its own,
// left its node at 98% of its memory requests before Substrate and kagent;
// 16 GiB also leaves two workers room for a third's pods while it restarts.
// A control plane runs etcd and the API server, controller
// manager and scheduler. Measured on a running cluster, the node's working set
// peaked at about 2.5 GiB, mostly the API server's heap, and the rest of the 6
// GiB was reclaimable page cache; docs/control-plane-memory.md has the
// measurements, why Proxmox shows 99% used, and the sizing rule to apply when
// the workload grows. The cluster name is left empty on purpose.
func Default() Config {
	return Config{
		TalosVersion:   DefaultTalosVersion,
		DiskStorage:    "local-zfs",
		ISOStorage:     "garage",
		SnippetStorage: "garage",
		DiskSSD:        true,
		Bridge:         "k8s",
		Nameserver:     "192.168.2.1",
		SearchDomain:   "lan",
		FirstAddress:   "10.20.0.50",
		ControlPlane:   ControlPlane{Count: 1, Size: Size{Cores: 2, MemoryMiB: 6144, DiskGiB: 32}},
		Pools: []Pool{
			{Name: "general", Count: 3, Size: Size{Cores: 4, MemoryMiB: 16384, DiskGiB: 64}},
		},
	}
}

// Load reads a JSON config file over the defaults. Unknown fields are an
// error, so a misspelled key fails instead of being silently ignored. A
// pools list in the file replaces the default pools as a whole.
func Load(path string) (Config, error) {
	cfg := Default()
	if path == "" {
		return cfg, nil
	}
	f, err := os.Open(path)
	if err != nil {
		return cfg, err
	}
	defer f.Close()
	dec := json.NewDecoder(f)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cfg); err != nil {
		return cfg, fmt.Errorf("%s: %w", path, err)
	}
	return cfg, nil
}

// label is a lowercase DNS label. VM names and tags are both built from the
// cluster and pool names, Proxmox requires VM names to be DNS names, and
// Proxmox tags allow a superset of these characters, so one rule serves both.
// Lowercase matters because Proxmox compares tags case-insensitively.
// It has no underscore, which SnippetName relies on as its separator.
var label = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`)

// dnsName is a lowercase DNS name: labels separated by dots.
var dnsName = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$`)

// version is a Talos release tag such as v1.14.4.
var version = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$`)

// Validate reports every problem in the config at once, so one run shows
// everything to fix. It includes the address rules, so a bad address is
// refused before the program talks to Proxmox at all.
func (c Config) Validate() error {
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
	for _, f := range []struct{ name, value string }{
		{"diskStorage", c.DiskStorage}, {"isoStorage", c.ISOStorage}, {"snippetStorage", c.SnippetStorage},
		{"bridge", c.Bridge},
	} {
		// These end up inside Proxmox property strings, where a comma or
		// an equals sign would start another property.
		if f.value == "" || strings.ContainsAny(f.value, ",=; ") {
			add("%s %q: want a plain name", f.name, f.value)
		}
	}
	// The search domain goes into the network snippet's YAML unquoted.
	if !dnsName.MatchString(c.SearchDomain) || len(c.SearchDomain) > 253 {
		add("searchDomain %q: want a lowercase DNS name such as lan", c.SearchDomain)
	}
	if a, err := netip.ParseAddr(c.Nameserver); err != nil || !a.Is4() {
		add("nameserver %q: want an IP address", c.Nameserver)
	}
	for _, n := range c.Nodes {
		if n == "" {
			add("nodes: empty node name")
		}
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
		if _, err := c.addresses(); err != nil {
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
// pass CheckNodeAddress and be used once.
func (c Config) addresses() ([]netip.Addr, error) {
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
			if err := CheckNodeAddress(a); err != nil {
				errs = append(errs, fmt.Errorf("%s: %w", name, err))
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
