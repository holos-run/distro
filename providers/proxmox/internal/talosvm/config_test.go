package talosvm

import (
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func spike() Config {
	c := Default()
	c.Cluster = "spike"
	return c
}

func TestDefaultNeedsOnlyACluster(t *testing.T) {
	if err := Default().Validate(); err == nil || !strings.Contains(err.Error(), "cluster is required") {
		t.Errorf("Default().Validate() = %v, want cluster is required", err)
	}
	if err := spike().Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestValidateReportsEverything(t *testing.T) {
	c := spike()
	c.Cluster = "Spike"
	c.TalosVersion = "1.14.4"
	c.ControlPlane.Count = 2
	c.ControlPlane.MemoryMiB = 1024
	c.Bridge = "k8s,mtu=1500"
	c.Nameserver = "dns.lan"
	c.SearchDomain = "lan]\n  evil: [x"
	c.Pools = append(c.Pools, Pool{Name: "cp", Count: 1, Size: c.Pools[0].Size}, c.Pools[0])
	err := c.Validate()
	if err == nil {
		t.Fatal("Validate accepted a bad config")
	}
	for _, want := range []string{"cluster", "talosVersion", "controlPlane.count", "controlPlane.memoryMiB", "bridge", "nameserver", "searchDomain", "reserved", "used twice"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error does not mention %s:\n%v", want, err)
		}
	}
}

func TestCheckNodeAddress(t *testing.T) {
	for _, tc := range []struct {
		addr, want string
	}{
		{"10.20.0.50", ""},
		{"10.20.0.19", ""},
		{"10.20.0.254", ""},
		{"10.20.0.20", "reserved (manual)"},
		{"10.20.0.25", "reserved (manual)"},
		{"10.20.0.29", "reserved (manual)"},
		{"10.20.0.30", "reserved (ingress)"},
		{"10.20.0.40", "reserved (ingress)"},
		{"10.20.0.49", "reserved (ingress)"},
		{"10.20.0.1", "gateway"},
		{"10.20.0.0", "network or broadcast"},
		{"10.20.0.255", "network or broadcast"},
		{"10.20.1.50", "outside the node subnet"},
		{"192.168.2.50", "outside the node subnet"},
	} {
		err := CheckNodeAddress(netip.MustParseAddr(tc.addr))
		switch {
		case tc.want == "" && err != nil:
			t.Errorf("%s: %v, want accepted", tc.addr, err)
		case tc.want != "" && (err == nil || !strings.Contains(err.Error(), tc.want)):
			t.Errorf("%s: %v, want %q", tc.addr, err, tc.want)
		}
	}
}

func TestAddressAssignment(t *testing.T) {
	c := spike()
	c.Pools = append(c.Pools, Pool{Name: "microvm", Count: 2, Size: c.Pools[0].Size, Addresses: []string{"10.20.0.120", "10.20.0.121"}})
	got, err := c.addresses()
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

func TestAddressRefusals(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func(*Config)
		want string
	}{
		// Four VMs from .17 run into .20.
		{"runs into manual", func(c *Config) { c.FirstAddress = "10.20.0.17" }, "reserved (manual)"},
		{"explicit in manual", func(c *Config) { c.ControlPlane.Addresses = []string{"10.20.0.22"} }, "reserved (manual)"},
		{"explicit in ingress", func(c *Config) { c.ControlPlane.Addresses = []string{"10.20.0.35"} }, "reserved (ingress)"},
		{"wrong count", func(c *Config) { c.Pools[0].Addresses = []string{"10.20.0.60"} }, "1 given for 3 VMs"},
		{"duplicate", func(c *Config) { c.ControlPlane.Addresses = []string{"10.20.0.51"} }, "also given to"},
		{"off subnet", func(c *Config) { c.FirstAddress = "10.21.0.50" }, "outside the node subnet"},
		{"runs off the end", func(c *Config) { c.FirstAddress = "10.20.0.253" }, "broadcast"},
		{"not an address", func(c *Config) { c.FirstAddress = "fifty" }, "firstAddress"},
	} {
		c := spike()
		tc.edit(&c)
		if err := c.Validate(); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: %v, want %q", tc.name, err, tc.want)
		}
	}
}

// The snippet is the shape the garage's maintenance-mode Talos VMs already
// boot with: a /32 and an on-link default route to the anycast gateway.
func TestNetworkConfig(t *testing.T) {
	s := Spec{Name: "spike-cp-1", Address: netip.MustParseAddr("10.20.0.50")}
	got := NetworkConfig(spike(), s, "BC:24:11:D1:BA:A5")
	want := `# Written by talosvm for cluster spike, VM spike-cp-1.
version: 2
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
}

func TestMACFor(t *testing.T) {
	a, b := MACFor("spike", "spike-cp-1", 0), MACFor("spike", "spike-general-1", 0)
	if a != MACFor("spike", "spike-cp-1", 0) || a == b || a == MACFor("lab", "spike-cp-1", 0) {
		t.Errorf("MACFor not deterministic per cluster and VM: %s %s", a, b)
	}
	if a1 := MACFor("spike", "spike-cp-1", 1); a1 == a || a1 != MACFor("spike", "spike-cp-1", 1) {
		t.Errorf("MACFor attempt 1 = %s, want a different, stable candidate", a1)
	}
	if !strings.HasPrefix(a, "BC:24:11:") || len(a) != 17 || strings.ToUpper(a) != a {
		t.Errorf("MACFor = %q, want BC:24:11:XX:XX:XX", a)
	}
}

func TestSnippetAddresses(t *testing.T) {
	// The garage's existing hand-written snippet, and a version 1 one.
	v2 := "version: 2\nethernets:\n  net0:\n    addresses:\n      - 10.20.0.30/32\n    routes:\n      - to: 0.0.0.0/0\n        via: 10.20.0.1\n        on-link: true\n    nameservers:\n      addresses: [192.168.2.1]\n"
	got := SnippetAddresses(v2)
	if !slices.Contains(got, netip.MustParseAddr("10.20.0.30")) {
		t.Errorf("SnippetAddresses(v2) = %v, lacks 10.20.0.30", got)
	}
	v1 := "version: 1\nconfig:\n  - type: physical\n    subnets:\n      - type: static\n        address: '10.20.0.77'\n        netmask: '255.255.255.255'\n"
	if got := SnippetAddresses(v1); !slices.Contains(got, netip.MustParseAddr("10.20.0.77")) {
		t.Errorf("SnippetAddresses(v1) = %v, lacks 10.20.0.77", got)
	}
}

func TestGuestMACsAndCicustom(t *testing.T) {
	conf := map[string]string{
		"net0":     "virtio=bc:24:11:d1:ba:a5,bridge=k8s,mtu=1",
		"net1":     "name=eth0,bridge=k8s,hwaddr=BC:24:11:00:00:02,ip=dhcp",
		"cicustom": "user=garage:snippets/u.yaml,network=garage:snippets/tenant-k8s1-api1-net.yaml",
	}
	if got := GuestMACs(conf); !slices.Equal(got, []string{"BC:24:11:00:00:02", "BC:24:11:D1:BA:A5"}) {
		t.Errorf("GuestMACs = %v", got)
	}
	if got := CustomNetworkVolume(conf); got != "garage:snippets/tenant-k8s1-api1-net.yaml" {
		t.Errorf("CustomNetworkVolume = %q", got)
	}
	if p, ok := SnippetFileForVolume("/mnt/s", "garage", "garage:snippets/a.yaml"); !ok || p != "/mnt/s/a.yaml" {
		t.Errorf("SnippetFileForVolume = %q, %v", p, ok)
	}
	for _, v := range []string{"local:snippets/a.yaml", "garage:snippets/../x", "garage:snippets/", "garage:iso/a.iso"} {
		if _, ok := SnippetFileForVolume("/mnt/s", "garage", v); ok {
			t.Errorf("SnippetFileForVolume accepted %q", v)
		}
	}
}

func TestGuestAddresses(t *testing.T) {
	conf := map[string]string{
		"ipconfig0": "ip=10.20.0.4/32,gw=10.20.0.1",
		"ipconfig1": "ip=dhcp",
		"ipconfig2": "ip6=auto",
		"net0":      "virtio=BC:24:11:00:00:01,bridge=k8s",               // a QEMU NIC
		"net1":      "name=eth0,bridge=k8s,ip=10.20.0.5/24,gw=10.20.0.1", // an LXC NIC
		"name":      "ip=10.20.0.6/24",                                   // not a network key
	}
	got := GuestAddresses(conf)
	want := []netip.Addr{netip.MustParseAddr("10.20.0.4"), netip.MustParseAddr("10.20.0.5")}
	if !slices.Equal(got, want) {
		t.Errorf("GuestAddresses = %v, want %v", got, want)
	}
}

func TestLoad(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good.json")
	os.WriteFile(good, []byte(`{"cluster":"lab","firstAddress":"10.20.0.60","pools":[{"name":"microvm","count":2,"cores":8,"memoryMiB":16384,"diskGiB":100}]}`), 0o600)
	c, err := Load(good)
	if err != nil {
		t.Fatal(err)
	}
	if c.Cluster != "lab" || len(c.Pools) != 1 || c.Pools[0].Name != "microvm" || c.Bridge != "k8s" || c.DiskStorage != "local-zfs" {
		t.Errorf("Load did not merge over defaults: %+v", c)
	}
	bad := filepath.Join(dir, "bad.json")
	os.WriteFile(bad, []byte(`{"clsuter":"lab"}`), 0o600)
	if _, err := Load(bad); err == nil {
		t.Error("Load accepted an unknown field")
	}
}
