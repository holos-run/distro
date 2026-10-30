package talos

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"go.holos.run/distro/providers/infra"
)

// fakeCompute is an infra.Compute held in memory, so the Talos layer's tests
// run without a Proxmox server, and show the layer needs nothing of one. It
// keeps one group's VMs. It plans a new VM the way any provider must: the
// address its spec asks for, a MAC and a zone of its own choosing, and no
// ID until Create. It records every change in log.
type fakeCompute struct {
	mu     sync.Mutex
	group  string
	vms    []infra.VM
	nextID int
	log    []string
	// specs and configs are what the last Plan and Create were given.
	specs   []infra.VMSpec
	configs map[string]string
	// checkErr is what Check fails with.
	checkErr error
	// hook, when set, sees each half of a power cycle, "shutdown" or
	// "start", before it happens.
	hook func(half string, vm infra.VM)
	// failHalf, when set, fails that half of every power cycle, after the
	// hook has seen it.
	failHalf string
	// dryRun makes Resize log what it would do and do nothing, as a
	// provider made for a dry run does.
	dryRun bool
}

var _ infra.Compute = (*fakeCompute)(nil)

var fakeSubnet = netip.MustParsePrefix("10.20.0.0/24")

func newFakeCompute(group string) *fakeCompute {
	return &fakeCompute{group: group, nextID: 104}
}

// fakeNIC is the NIC the fake gives every VM on its one network.
func fakeNIC(network, mac string, addr netip.Addr) infra.NIC {
	n := infra.NIC{
		Network: network, MAC: mac, Subnet: fakeSubnet, Gateway: netip.MustParseAddr("10.20.0.1"), MTU: 9000,
		Nameservers: []netip.Addr{netip.MustParseAddr("10.20.0.2"), netip.MustParseAddr("10.20.0.3")}, SearchDomains: []string{"example"},
	}
	if addr.IsValid() {
		n.Address = netip.PrefixFrom(addr, 32)
	}
	return n
}

// add puts a running VM of the group in the fake, as if made earlier.
func (f *fakeCompute) add(name, zone string, addr string, size infra.Size, labels ...infra.Label) *infra.VM {
	var a netip.Addr
	if addr != "" {
		a = netip.MustParseAddr(addr)
	}
	vm := infra.VM{
		Name: name, ID: infra.ID{Kind: "id", Value: strconv.Itoa(f.nextID)}, Labels: labels, Region: "region-1", Zone: zone,
		Status: "running", NIC: fakeNIC("k8s", fmt.Sprintf("02:00:00:00:00:%02X", f.nextID), a),
		Size: size, Sizing: infra.Sizing{Now: size, Next: size},
	}
	f.nextID++
	f.vms = append(f.vms, vm)
	slices.SortFunc(f.vms, func(a, b infra.VM) int { return strings.Compare(a.Name, b.Name) })
	return f.find(name)
}

func (f *fakeCompute) find(name string) *infra.VM {
	for i := range f.vms {
		if f.vms[i].Name == name {
			return &f.vms[i]
		}
	}
	return nil
}

func (f *fakeCompute) String() string { return "the fake" }

func (f *fakeCompute) Check(context.Context) error { return f.checkErr }

func (f *fakeCompute) CheckAddress(a netip.Addr) error {
	switch {
	case !fakeSubnet.Contains(a):
		return fmt.Errorf("address %s is outside %s", a, fakeSubnet)
	case a.As4()[3] >= 30 && a.As4()[3] < 50:
		return fmt.Errorf("address %s is reserved", a)
	}
	return nil
}

type fakePlan struct {
	specs []infra.VMSpec
	vms   []infra.VM
}

func (p *fakePlan) VMs() []infra.VM { return slices.Clone(p.vms) }

func (f *fakeCompute) Plan(ctx context.Context, group string, specs []infra.VMSpec) (infra.Plan, error) {
	if err := f.Check(ctx); err != nil {
		return nil, err
	}
	if group != f.group {
		return nil, fmt.Errorf("fake holds group %s, not %s", f.group, group)
	}
	f.specs = specs
	zones := []string{"r620a", "r620b", "r620c"}
	p := &fakePlan{specs: specs}
	for i, s := range specs {
		if err := f.CheckAddress(s.Address); err != nil {
			return nil, err
		}
		if vm := f.find(s.Name); vm != nil {
			if vm.NIC.Address.Addr() != s.Address {
				return nil, fmt.Errorf("VM %s has address %s, its spec asks for %s", s.Name, vm.NIC.Address.Addr(), s.Address)
			}
			p.vms = append(p.vms, *vm)
			continue
		}
		zone := zones[i%len(zones)]
		if len(s.Zones) > 0 {
			zone = s.Zones[0]
		}
		p.vms = append(p.vms, infra.VM{
			Name: s.Name, Labels: s.Labels, Region: "region-1", Zone: zone,
			NIC: fakeNIC(s.Network, fmt.Sprintf("02:00:00:00:01:%02X", i), s.Address),
		})
	}
	return p, nil
}

func (f *fakeCompute) Create(_ context.Context, plan infra.Plan, configs map[string]string) error {
	p := plan.(*fakePlan)
	f.configs = configs
	for i, vm := range p.vms {
		if vm.ID.Value != "" {
			if v := f.find(vm.Name); v.Status == "stopped" {
				v.Status = "running"
				f.log = append(f.log, "start "+vm.Name)
			}
			continue
		}
		s := p.specs[i]
		f.log = append(f.log, fmt.Sprintf("create %s with %s on %s", vm.Name, s.Image.Name, vm.Zone))
		v := f.add(vm.Name, vm.Zone, s.Address.String(), s.Size, vm.Labels...)
		v.NIC.MAC = vm.NIC.MAC
	}
	return nil
}

func (f *fakeCompute) List(_ context.Context, group string) ([]infra.VM, error) {
	if group != f.group {
		return []infra.VM{}, nil
	}
	return slices.Clone(f.vms), nil
}

// own refuses a VM that is not one of the group's, as a provider must.
func (f *fakeCompute) own(group string, vm infra.VM) (*infra.VM, error) {
	v := f.find(vm.Name)
	if group != f.group || v == nil || v.ID != vm.ID {
		return nil, fmt.Errorf("VM %s (%s) is not a VM of group %s", vm.Name, vm.ID, group)
	}
	return v, nil
}

func (f *fakeCompute) Resize(_ context.Context, group string, resizes []infra.Resize) error {
	for _, z := range resizes {
		if _, err := f.own(group, z.VM); err != nil {
			return err
		}
	}
	for _, z := range resizes {
		vm := f.find(z.VM.Name)
		if f.dryRun {
			f.log = append(f.log, fmt.Sprintf("would resize %s to %d cores and %d MiB", vm.Name, z.Size.Cores, z.Size.MemoryMiB))
			continue
		}
		f.log = append(f.log, fmt.Sprintf("resize %s to %d cores and %d MiB", vm.Name, z.Size.Cores, z.Size.MemoryMiB))
		vm.Sizing.Next = z.Size
		if vm.Status != "running" {
			vm.Sizing.Now, vm.Size = z.Size, z.Size
		}
	}
	return nil
}

func (f *fakeCompute) PowerCycle(_ context.Context, group string, vm infra.VM, timeout time.Duration) error {
	if _, err := f.own(group, vm); err != nil {
		return err
	}
	f.mu.Lock()
	f.log = append(f.log, fmt.Sprintf("power-cycle %s within %s", vm.Name, timeout))
	f.mu.Unlock()
	for _, half := range []string{"shutdown", "start"} {
		if f.hook != nil {
			f.hook(half, vm)
		}
		if half == f.failHalf {
			return errors.New("the fake's " + half + " failed")
		}
	}
	if v := f.find(vm.Name); v != nil {
		v.Sizing.Now, v.Size = v.Sizing.Next, v.Sizing.Next
	}
	return nil
}

func (f *fakeCompute) PowerCycleCalls(vm infra.VM, timeout time.Duration) []string {
	return []string{
		fmt.Sprintf("shut down %s on %s within %s", vm.ID, vm.Zone, timeout),
		fmt.Sprintf("start %s on %s", vm.ID, vm.Zone),
	}
}

func (f *fakeCompute) Destroy(_ context.Context, group string) error {
	if group == f.group {
		f.vms = nil
		f.log = append(f.log, "destroy "+group)
	}
	return nil
}
