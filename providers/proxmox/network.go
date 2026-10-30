package proxmox

import (
	"crypto/sha256"
	"fmt"
	"net/netip"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// The garage's node network. These are facts about the garage rather than
// settings, so they are constants: a config file cannot move a cluster into
// a reserved range or off the vnet by mistake.
//
// The k8s vnet is an SDN EVPN vnet with an anycast gateway on every Proxmox
// node and no DHCP. Every node address is a /32 and every packet goes to the
// gateway on the node's own hypervisor, so each VM needs a static address and
// an on-link default route, which come from a cloud-init network snippet the
// Kubernetes layer renders from what the VM's NIC reports.
var (
	// NodeSubnet is the k8s vnet's subnet.
	NodeSubnet = netip.MustParsePrefix("10.20.0.0/24")
	// Gateway is the vnet's anycast gateway.
	Gateway = netip.MustParseAddr("10.20.0.1")
)

// VnetMTU is the k8s vnet's MTU, which each VM's NIC reports for its guest
// to set.
const VnetMTU = 8950

// NodeNetwork is the network the Kubernetes layer's nodes attach to by
// default: the k8s vnet, whose name is also its bridge's.
const NodeNetwork = "k8s"

// FirstNodeAddress is where a cluster's node addresses start by default: the
// first address after the reservations, cluster slot 1 in the README's
// allocation table.
var FirstNodeAddress = netip.MustParseAddr("10.20.0.50")

// Reservation is a range of the node subnet no node may take.
type Reservation struct {
	Name        string
	First, Last netip.Addr
	Purpose     string
}

// Contains reports whether a is inside the reservation.
func (r Reservation) Contains(a netip.Addr) bool {
	return a.Compare(r.First) >= 0 && a.Compare(r.Last) <= 0
}

// Reservations is the one table of reserved ranges. Validation refuses node
// addresses inside any of them, and the README's allocation table lists the
// same ranges.
var Reservations = []Reservation{
	{"manual", netip.MustParseAddr("10.20.0.20"), netip.MustParseAddr("10.20.0.29"), "hand-made VMs for manual testing"},
	{"ingress", netip.MustParseAddr("10.20.0.30"), netip.MustParseAddr("10.20.0.49"), "ingress Gateway LoadBalancer addresses, about six clusters with three or four gateways each"},
}

// CheckNodeAddress refuses an address a node may not have: outside the
// subnet, the subnet's network or broadcast address, the gateway, or inside a
// reservation. Whether another VM already uses it is a question for Proxmox,
// which create asks before it changes anything.
func CheckNodeAddress(a netip.Addr) error {
	last := lastAddr(NodeSubnet)
	switch {
	case !a.Is4() || !NodeSubnet.Contains(a):
		return fmt.Errorf("address %s is outside the node subnet %s", a, NodeSubnet)
	case a == NodeSubnet.Addr() || a == last:
		return fmt.Errorf("address %s is the network or broadcast address of %s", a, NodeSubnet)
	case a == Gateway:
		return fmt.Errorf("address %s is the gateway", a)
	}
	for _, r := range Reservations {
		if r.Contains(a) {
			return fmt.Errorf("address %s is inside %s-%s, reserved (%s) for %s", a, r.First, r.Last, r.Name, r.Purpose)
		}
	}
	return nil
}

func lastAddr(p netip.Prefix) netip.Addr {
	b := p.Masked().Addr().As4()
	host := 32 - p.Bits()
	for i := 3; i >= 0 && host > 0; i-- {
		n := min(host, 8)
		b[i] |= byte(1<<n - 1)
		host -= n
	}
	return netip.AddrFrom4(b)
}

// MACFor is a candidate MAC address for a VM's net0: the Proxmox OUI
// BC:24:11 and three bytes of a hash of the cluster, the VM name and, after
// the first, the attempt number. Knowing the MAC before the VM exists is
// what lets the network snippet, which matches the NIC by MAC, be written
// before the VM is created. Three bytes can collide, so create takes the
// first attempt no other guest, and no other VM of the same run, already has;
// the choice is deterministic for a given garage. A VM keeps its MAC for its
// lifetime: create never changes an existing VM's net0.
func MACFor(cluster, vm string, attempt int) string {
	seed := "talosvm/" + cluster + "/" + vm
	if attempt > 0 {
		seed += "/" + strconv.Itoa(attempt)
	}
	h := sha256.Sum256([]byte(seed))
	return fmt.Sprintf("BC:24:11:%02X:%02X:%02X", h[0], h[1], h[2])
}

// guestNetKey matches the config keys that can carry a guest's address:
// ipconfigN on a QEMU VM and netN on an LXC container. A QEMU netN has no
// ip= property, so reading both on every guest is safe.
var guestNetKey = regexp.MustCompile(`^(ipconfig|net)[0-9]+$`)

// GuestAddresses returns the static IPv4 addresses a guest's Proxmox config
// assigns it, from ip=ADDR/LEN properties. dhcp, manual and IPv6 entries are
// skipped. Only addresses Proxmox knows about are found: a guest that sets
// its address inside the guest is invisible here.
func GuestAddresses(conf map[string]string) []netip.Addr {
	var out []netip.Addr
	for k, v := range conf {
		if !guestNetKey.MatchString(k) {
			continue
		}
		for _, prop := range strings.Split(v, ",") {
			val, ok := strings.CutPrefix(strings.TrimSpace(prop), "ip=")
			if !ok {
				continue
			}
			if p, err := netip.ParsePrefix(val); err == nil && p.Addr().Is4() {
				out = append(out, p.Addr())
			} else if a, err := netip.ParseAddr(val); err == nil && a.Is4() {
				out = append(out, a)
			}
		}
	}
	slices.SortFunc(out, netip.Addr.Compare)
	return out
}

// macProp matches a MAC address in a QEMU netN (virtio=MAC) or LXC netN
// (hwaddr=MAC) value.
var macProp = regexp.MustCompile(`(?i)^(?:[a-z0-9]+|hwaddr)=([0-9a-f]{2}(?::[0-9a-f]{2}){5})$`)

// GuestMACs returns the MAC addresses of a guest's NICs, upper case.
func GuestMACs(conf map[string]string) []string {
	var out []string
	for k, v := range conf {
		if !strings.HasPrefix(k, "net") || !guestNetKey.MatchString(k) {
			continue
		}
		for _, prop := range strings.Split(v, ",") {
			if m := macProp.FindStringSubmatch(strings.TrimSpace(prop)); m != nil {
				out = append(out, strings.ToUpper(m[1]))
			}
		}
	}
	slices.Sort(out)
	return out
}

// CustomNetworkVolume returns the volume a cicustom setting names for the
// network config, such as garage:snippets/x.yaml, or "".
func CustomNetworkVolume(conf map[string]string) string {
	for _, prop := range strings.Split(conf["cicustom"], ",") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(prop), "network="); ok {
			return v
		}
	}
	return ""
}

// snippetAddr is any dotted-quad IPv4 address.
var snippetAddr = regexp.MustCompile(`\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b`)

// SnippetAddresses returns every IPv4 address a network snippet mentions,
// whatever its version or layout. It is a scan, not a YAML parse, and it
// over-collects on purpose: besides the addresses a guest takes it finds its
// gateway, nameservers and route destinations, and each of those is either
// in use too or never a node address, so treating them all as taken is safe.
func SnippetAddresses(text string) []netip.Addr {
	var out []netip.Addr
	for _, m := range snippetAddr.FindAllString(text, -1) {
		if a, err := netip.ParseAddr(m); err == nil && a.Is4() {
			out = append(out, a)
		}
	}
	slices.SortFunc(out, netip.Addr.Compare)
	return slices.Compact(out)
}

// SnippetNodeAddress returns the node address in one of talosvm's own
// snippets: the one address it mentions inside the node subnet other than
// the gateway.
func SnippetNodeAddress(text string) (netip.Addr, bool) {
	var found []netip.Addr
	for _, a := range SnippetAddresses(text) {
		if NodeSubnet.Contains(a) && a != Gateway {
			found = append(found, a)
		}
	}
	if len(found) != 1 {
		return netip.Addr{}, false
	}
	return found[0], true
}

// netProp returns the value of one property of a guest's netN, or "".
func netProp(v, key string) string {
	for _, prop := range strings.Split(v, ",") {
		if val, ok := strings.CutPrefix(strings.TrimSpace(prop), key+"="); ok {
			return val
		}
	}
	return ""
}

// Net0MAC returns the MAC address on a guest's net0, upper case, or "".
func Net0MAC(conf map[string]string) string {
	for _, prop := range strings.Split(conf["net0"], ",") {
		if m := macProp.FindStringSubmatch(strings.TrimSpace(prop)); m != nil {
			return strings.ToUpper(m[1])
		}
	}
	return ""
}
