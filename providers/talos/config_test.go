package talos

import (
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"go.holos.run/distro/providers/infra"
)

// treasury is the default config for the cluster treasury, on a network the
// fake compute knows, with node addresses from 10.20.0.50.
func treasury() Config {
	c := Default()
	c.Cluster = "treasury"
	c.Network = "k8s"
	c.FirstAddress = "10.20.0.50"
	return c
}

// check is the fake compute's address rule.
var check = newFakeCompute("treasury").CheckAddress

func TestDefaultNeedsOnlyACluster(t *testing.T) {
	c := treasury()
	c.Cluster = ""
	if err := c.Validate(check); err == nil || !strings.Contains(err.Error(), "cluster is required") {
		t.Errorf("Validate() = %v, want cluster is required", err)
	}
	if err := treasury().Validate(check); err != nil {
		t.Fatal(err)
	}
}

func TestValidateReportsEverything(t *testing.T) {
	c := treasury()
	c.Cluster = "Treasury"
	c.TalosVersion = "1.14.4"
	c.ControlPlane.Count = 2
	c.ControlPlane.MemoryMiB = 1024
	c.Network = "k8s,mtu=1500"
	c.Pools = append(c.Pools, Pool{Name: "cp", Count: 1, Size: c.Pools[0].Size}, c.Pools[0])
	err := c.Validate(check)
	if err == nil {
		t.Fatal("Validate accepted a bad config")
	}
	for _, want := range []string{"cluster", "talosVersion", "controlPlane.count", "controlPlane.memoryMiB", "bridge", "reserved", "used twice"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error does not mention %s:\n%v", want, err)
		}
	}
}

func TestAddressAssignment(t *testing.T) {
	c := treasury()
	c.Pools = append(c.Pools, Pool{Name: "microvm", Count: 2, Size: c.Pools[0].Size, Addresses: []string{"10.20.0.120", "10.20.0.121"}})
	got, err := c.addresses(check)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"10.20.0.50", "10.20.0.51", "10.20.0.52", "10.20.0.53", "10.20.0.120", "10.20.0.121"}
	var s []string
	for _, a := range got {
		s = append(s, a.String())
	}
	if !slices.Equal(s, want) {
		t.Errorf("addresses = %v, want %v", s, want)
	}
}

// The config's own address rules, and compute's, each name the VM by where
// the config gives it its address.
func TestAddressRefusals(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func(*Config)
		want string
	}{
		// Four VMs from .27 run into .30.
		{"runs into reserved", func(c *Config) { c.FirstAddress = "10.20.0.27" }, "pools[0] VM 3: address 10.20.0.30 is reserved"},
		{"explicit reserved", func(c *Config) { c.ControlPlane.Addresses = []string{"10.20.0.35"} }, "controlPlane VM 1: address 10.20.0.35 is reserved"},
		{"wrong count", func(c *Config) { c.Pools[0].Addresses = []string{"10.20.0.60"} }, "1 given for 3 VMs"},
		{"duplicate", func(c *Config) { c.ControlPlane.Addresses = []string{"10.20.0.51"} }, "also given to"},
		{"off subnet", func(c *Config) { c.FirstAddress = "10.21.0.50" }, "outside 10.20.0.0/24"},
		{"not an address", func(c *Config) { c.FirstAddress = "fifty" }, "firstAddress"},
		{"not an explicit address", func(c *Config) { c.ControlPlane.Addresses = []string{"x"} }, `controlPlane.addresses[0] "x"`},
	} {
		c := treasury()
		tc.edit(&c)
		if err := c.Validate(check); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: %v, want %q", tc.name, err, tc.want)
		}
	}
	// Without compute's rule only the config's own are checked.
	c := treasury()
	c.FirstAddress = "10.20.0.27"
	if err := c.Validate(nil); err != nil {
		t.Errorf("Validate(nil) = %v", err)
	}
}

// Specs is the VMs in order, each with what compute needs and nothing of
// Talos but its role and pool labels.
func TestSpecs(t *testing.T) {
	c := treasury()
	c.Pools = append(c.Pools, Pool{Name: "microvm", Count: 1, Size: Size{Cores: 8, MemoryMiB: 16384, DiskGiB: 100}, Zones: []string{"r620c"}, Addresses: []string{"10.20.0.120"}})
	specs, err := c.Specs()
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, s := range specs {
		got = append(got, fmt.Sprintf("%s %v %d/%d/%v %s %s %v", s.Name, s.Labels, s.Cores, s.MemoryMiB, s.Disks, s.Network, s.Address, s.Zones))
	}
	want := []string{
		"treasury-cp-1 [{role controlplane}] 2/8192/[{32}] k8s 10.20.0.50 []",
		"treasury-general-1 [{role worker} {pool general}] 4/16384/[{64}] k8s 10.20.0.51 []",
		"treasury-general-2 [{role worker} {pool general}] 4/16384/[{64}] k8s 10.20.0.52 []",
		"treasury-general-3 [{role worker} {pool general}] 4/16384/[{64}] k8s 10.20.0.53 []",
		"treasury-microvm-1 [{role worker} {pool microvm}] 8/16384/[{100}] k8s 10.20.0.120 [r620c]",
	}
	if !slices.Equal(got, want) {
		t.Errorf("Specs =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

// The network config is the shape the garage's maintenance-mode Talos VMs
// already boot with: a /32 and an on-link default route to the gateway,
// byte for byte what talosvm wrote before the split for the same NIC.
func TestNetworkConfig(t *testing.T) {
	nic := infra.NIC{
		MAC: "BC:24:11:D1:BA:A5", Address: netip.MustParsePrefix("10.20.0.50/32"), Gateway: netip.MustParseAddr("10.20.0.1"), MTU: 8950,
		Nameservers: []netip.Addr{netip.MustParseAddr("192.168.2.1")}, SearchDomains: []string{"lan"},
	}
	got := NetworkConfig(nic)
	want := `version: 2
ethernets:
  net0:
    match:
      macaddress: "BC:24:11:D1:BA:A5"
    addresses:
      - 10.20.0.50/32
    mtu: 8950
    routes:
      - to: 0.0.0.0/0
        via: 10.20.0.1
        on-link: true
    nameservers:
      addresses: [192.168.2.1]
      search: [lan]
`
	if got != want {
		t.Errorf("NetworkConfig =\n%s\nwant\n%s", got, want)
	}
	nic.Nameservers = append(nic.Nameservers, netip.MustParseAddr("192.168.2.2"))
	if got := NetworkConfig(nic); !strings.Contains(got, "      addresses: [192.168.2.1, 192.168.2.2]\n") {
		t.Errorf("two nameservers:\n%s", got)
	}
}

func TestDecode(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good.json")
	os.WriteFile(good, []byte(`{"cluster":"lab","firstAddress":"10.20.0.60","bridge":"lab","pools":[{"name":"microvm","count":2,"cores":8,"memoryMiB":16384,"diskGiB":100,"nodes":["r620c"]}]}`), 0o600)
	c := treasury()
	if err := Decode(good, &c); err != nil {
		t.Fatal(err)
	}
	if c.Cluster != "lab" || c.Network != "lab" || len(c.Pools) != 1 || c.Pools[0].Name != "microvm" || !slices.Equal(c.Pools[0].Zones, []string{"r620c"}) || c.ControlPlane.MemoryMiB != 8192 {
		t.Errorf("Decode did not merge over defaults: %+v", c)
	}
	bad := filepath.Join(dir, "bad.json")
	os.WriteFile(bad, []byte(`{"clsuter":"lab"}`), 0o600)
	if err := Decode(bad, &c); err == nil {
		t.Error("Decode accepted an unknown field")
	}
}
