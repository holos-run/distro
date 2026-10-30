package proxmox

import (
	"net/netip"
	"slices"
	"strings"
	"testing"
)

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

func TestMACFor(t *testing.T) {
	a, b := MACFor("treasury", "treasury-cp-1", 0), MACFor("treasury", "treasury-general-1", 0)
	if a != MACFor("treasury", "treasury-cp-1", 0) || a == b || a == MACFor("lab", "treasury-cp-1", 0) {
		t.Errorf("MACFor not deterministic per cluster and VM: %s %s", a, b)
	}
	if a1 := MACFor("treasury", "treasury-cp-1", 1); a1 == a || a1 != MACFor("treasury", "treasury-cp-1", 1) {
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

// The nameserver and search domain go into every VM's network config, and
// the storages into Proxmox property strings.
func TestConfigValidate(t *testing.T) {
	if err := Default().Validate(); err != nil {
		t.Fatal(err)
	}
	c := Default()
	c.DiskStorage = "local-zfs,ssd=0"
	c.Nameserver = "dns.lan"
	c.SearchDomain = "lan]\n  evil: [x"
	c.Nodes = []string{""}
	err := c.Validate()
	for _, want := range []string{"diskStorage", "nameserver", "searchDomain", "empty node name"} {
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("error does not mention %s:\n%v", want, err)
		}
	}
}
