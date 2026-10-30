package proxmox

import (
	"errors"
	"fmt"
	"net/netip"
	"regexp"
	"strings"
)

// Config is what the provider needs to know about the Proxmox cluster it
// puts VMs on. It is read from the same JSON file as the cluster's own
// config, whose other fields are the Kubernetes layer's, and every field has
// the garage's value as its default. Nothing in it is secret: the endpoint
// and token come from the environment.
type Config struct {
	// Nodes is the Proxmox nodes VMs are spread across, round robin. Empty
	// means every node that is online, sorted by name.
	Nodes []string `json:"nodes,omitempty"`
	// DiskStorage holds the VM disks, EFI vars and cloud-init drive; it must
	// exist on every node VMs are placed on. ISOStorage holds the boot ISO
	// and must allow the iso content type; when it is shared, the ISO is
	// downloaded once for every node.
	DiskStorage string `json:"diskStorage"`
	ISOStorage  string `json:"isoStorage"`
	// SnippetStorage holds each VM's cloud-init network snippet. It must
	// allow snippets content and be the storage whose snippets directory
	// Compute.SnippetsDir is a mount of.
	SnippetStorage string `json:"snippetStorage"`
	// DiskSSD sets ssd=1 on the system disk, which the Talos guide suggests
	// for SSD-backed storage. discard=on is always set.
	DiskSSD bool `json:"diskSSD"`
	// Nameserver and SearchDomain are the node network's resolver and
	// search domain, which every VM's NIC reports for its guest to set.
	Nameserver   string `json:"nameserver"`
	SearchDomain string `json:"searchDomain"`
}

// Default returns the garage: disks on local-zfs, the ISO and snippets on
// the shared garage NFS storage, and the LAN's resolver.
func Default() Config {
	return Config{
		DiskStorage:    "local-zfs",
		ISOStorage:     "garage",
		SnippetStorage: "garage",
		DiskSSD:        true,
		Nameserver:     "192.168.2.1",
		SearchDomain:   "lan",
	}
}

// label is a lowercase DNS label. VM names and tags are both built from the
// cluster and label values, Proxmox requires VM names to be DNS names, and
// Proxmox tags allow a superset of these characters, so one rule serves both.
// Lowercase matters because Proxmox compares tags case-insensitively.
// It has no underscore, which SnippetName relies on as its separator.
var label = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`)

// dnsName is a lowercase DNS name: labels separated by dots.
var dnsName = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$`)

// plainName refuses a value that would start another property inside a
// Proxmox property string, where a comma or an equals sign would.
func plainName(v string) bool { return v != "" && !strings.ContainsAny(v, ",=; ") }

// Validate reports every problem in the config at once, so one run shows
// everything to fix.
func (c Config) Validate() error {
	var errs []error
	add := func(format string, a ...any) { errs = append(errs, fmt.Errorf(format, a...)) }
	for _, f := range []struct{ name, value string }{
		{"diskStorage", c.DiskStorage}, {"isoStorage", c.ISOStorage}, {"snippetStorage", c.SnippetStorage},
	} {
		if !plainName(f.value) {
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
	return errors.Join(errs...)
}
