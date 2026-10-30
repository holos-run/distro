package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/netip"
	"strings"
	"testing"

	"go.holos.run/distro/providers/infra"
)

// list prints what compute reports in the columns and keys talosvm always
// has: the VMID as a number, the role and pool labels, the address without
// its prefix length, the pending size, and ? with a warning for a VM whose
// pending size could not be read, without failing the rest.
func TestList(t *testing.T) {
	size := infra.Size{Cores: 4, MemoryMiB: 8192}
	vm := func(name, id, zone, addr string, labels ...infra.Label) infra.VM {
		v := infra.VM{
			Name: name, ID: infra.ID{Kind: "vmid", Value: id}, Labels: labels, Region: "garage", Zone: zone, Status: "running",
			Size: size, Sizing: infra.Sizing{Now: size, Next: size},
		}
		if addr != "" {
			v.NIC.Address = netip.MustParsePrefix(addr + "/32")
		}
		return v
	}
	worker := []infra.Label{{Key: "role", Value: "worker"}, {Key: "pool", Value: "general"}}
	vms := []infra.VM{
		vm("treasury-cp-1", "104", "r620a", "10.20.0.50", infra.Label{Key: "role", Value: "controlplane"}),
		vm("treasury-general-1", "105", "r620b", "10.20.0.51", worker...),
		vm("treasury-general-2", "106", "r620c", "", worker...),
	}
	vms[1].Sizing.Next = infra.Size{Cores: 8, MemoryMiB: 16384}
	vms[2].Sizing, vms[2].SizingErr = infra.Sizing{}, errors.New("VM treasury-general-2 vmid 106: its config has no memory")

	var out, warn bytes.Buffer
	if err := list(vms, false, &out, &warn); err != nil {
		t.Fatal(err)
	}
	want := `NAME                VMID  REGION  NODE   ROLE          POOL     ADDRESS     STATUS   CORES  MEMORY   PENDING
treasury-cp-1       104   garage  r620a  controlplane  -        10.20.0.50  running  4      8192MiB  -
treasury-general-1  105   garage  r620b  worker        general  10.20.0.51  running  4      8192MiB  8 cores, 16384MiB
treasury-general-2  106   garage  r620c  worker        general              running  4      8192MiB  ?
`
	if out.String() != want {
		t.Errorf("table =\n%s\nwant\n%s", out.String(), want)
	}
	if want := "talosvm: warning: reading the pending size of treasury-general-2: VM treasury-general-2 vmid 106: its config has no memory\n"; warn.String() != want {
		t.Errorf("warning = %q", warn.String())
	}

	out.Reset()
	if err := list(vms, true, &out, &warn); err != nil {
		t.Fatal(err)
	}
	var rows []map[string]any
	if err := json.Unmarshal(out.Bytes(), &rows); err != nil {
		t.Fatal(err)
	}
	if rows[0]["vmid"] != 104.0 || rows[0]["address"] != "10.20.0.50" || rows[0]["role"] != "controlplane" || rows[0]["pool"] != nil ||
		rows[1]["pendingCores"] != 8.0 || rows[1]["pendingMemoryMiB"] != 16384.0 || rows[2]["address"] != "" || rows[2]["pendingMemoryMiB"] != nil {
		t.Errorf("json = %s", out.String())
	}
	out.Reset()
	if err := list(nil, true, &out, &warn); err != nil || strings.TrimSpace(out.String()) != "[]" {
		t.Errorf("empty json = %q, %v", out.String(), err)
	}
}
