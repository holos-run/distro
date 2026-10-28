package talosvm

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"

	"go.holos.run/distro/providers/proxmox/internal/pve"
)

// GuestSize is a VM's cores and memory as its config holds them: what it
// runs with now, and what it will run with after its next start. The two
// differ while Proxmox holds a change to a running VM as pending, which is
// how every resize of a running talosvm VM ends: the VMs have no CPU or
// memory hotplug, so new cores and memory take effect only when the VM is
// stopped and started.
type GuestSize struct {
	Cores, MemoryMiB         int
	NextCores, NextMemoryMiB int
}

// Pending reports whether a new size waits for the VM's next start.
func (g GuestSize) Pending() bool {
	return g.NextCores != g.Cores || g.NextMemoryMiB != g.MemoryMiB
}

// GuestSizeOf reads cores and memory from a VM's pending list. talosvm sets
// both on every VM it creates, so a VM without one, or with its deletion
// pending, is an error rather than a guess at Proxmox's default.
func GuestSizeOf(items []pve.PendingItem) (GuestSize, error) {
	var g GuestSize
	seen := map[string]bool{}
	for _, it := range items {
		var now, next *int
		parse := strconv.Atoi
		switch it.Key {
		case "cores":
			now, next = &g.Cores, &g.NextCores
		case "memory":
			now, next, parse = &g.MemoryMiB, &g.NextMemoryMiB, parseMemory
		default:
			continue
		}
		if it.Delete != 0 {
			return g, fmt.Errorf("its %s is pending deletion", it.Key)
		}
		v, err := parse(it.Value)
		if err != nil {
			return g, fmt.Errorf("its %s %q: %w", it.Key, it.Value, err)
		}
		*now, *next = v, v
		if it.HasPending {
			if *next, err = parse(it.Pending); err != nil {
				return g, fmt.Errorf("its pending %s %q: %w", it.Key, it.Pending, err)
			}
		}
		seen[it.Key] = true
	}
	for _, k := range []string{"cores", "memory"} {
		if !seen[k] {
			return g, fmt.Errorf("its config has no %s", k)
		}
	}
	return g, nil
}

// parseMemory reads a memory value in MiB. Proxmox 8.1 made memory a
// property string, [current=]<MiB>, which it writes as the bare number when
// nothing else is set; both forms are read.
func parseMemory(s string) (int, error) {
	first, _, _ := strings.Cut(s, ",")
	return strconv.Atoi(strings.TrimPrefix(first, "current="))
}

// guestSize reads one VM's GuestSize.
func (r *Runner) guestSize(ctx context.Context, v pve.Resource) (GuestSize, error) {
	items, err := r.PVE.GuestPending(ctx, v)
	if err != nil {
		return GuestSize{}, err
	}
	g, err := GuestSizeOf(items)
	if err != nil {
		return g, fmt.Errorf("VM %s vmid %d: %w", v.Name, v.VMID, err)
	}
	return g, nil
}

// sizes is every VM the config asks for, by name, with its role, pool and
// size but no placement, and the names in Specs order.
func (c Config) sizes() (names []string, specs map[string]Spec) {
	specs = map[string]Spec{}
	add := func(s Spec) {
		names = append(names, s.Name)
		specs[s.Name] = s
	}
	for i := range c.ControlPlane.Count {
		add(Spec{Name: vmName(c.Cluster, controlPlaneName, i), Role: RoleControlPlane, Size: c.ControlPlane.Size})
	}
	for _, p := range c.Pools {
		for i := range p.Count {
			add(Spec{Name: vmName(c.Cluster, p.Name, i), Role: RoleWorker, Pool: p.Name, Size: p.Size})
		}
	}
	return names, specs
}

// ResizeOptions are resize's settings, which the command line's flags fill.
type ResizeOptions struct {
	// Nodes names the VMs to resize. Empty means every VM of the cluster
	// the config asks for.
	Nodes []string
	// Shrink allows fewer cores or less memory than a VM runs with. Without
	// it a smaller size refuses the run, since resize takes its sizes from
	// the built-in defaults unless it is given the -config the cluster was
	// created with, and a forgotten -config would otherwise shrink it.
	Shrink bool
}

// Validate checks the options that need no cluster to check.
func (o ResizeOptions) Validate() error {
	var errs []error
	seen := map[string]bool{}
	for _, n := range o.Nodes {
		switch {
		case !label.MatchString(n):
			errs = append(errs, fmt.Errorf("node %q is not a VM name", n))
		case seen[n]:
			errs = append(errs, fmt.Errorf("node %s is named twice", n))
		}
		seen[n] = true
	}
	return errors.Join(errs...)
}

// ResizePlan is what resize found and what it sends.
type ResizePlan struct {
	// Notes say, a line per VM, what resize found.
	Notes []string
	Calls []Call
	// PowerCycle names, in name order, the running VMs whose new size
	// waits for their next start: those Calls resize and those that
	// already had a resize pending.
	PowerCycle []string
}

// PlanResize compares the cluster's VMs with the sizes the config gives
// their names, and plans a PUT /nodes/{node}/qemu/{vmid}/config for each VM
// whose cores or memory after its next start differ from the config's. The
// call carries only what differs. It never sends balloon, so ballooning stays
// off as create left it, and never touches the disk, which Proxmox can grow
// but not shrink and which the config's diskGiB does not change once a VM
// exists.
//
// Only Owned VMs are looked at, so another tenant's VM, or another cluster's,
// is never resized, whatever its name. A VM of the cluster that the config
// does not ask for, or that o.Nodes leaves out, is left as it is. These
// refuse the whole plan, before any change: two of the cluster's VMs with
// one name; a VM whose role or pool tag is not the one the config gives its
// name, such as a worker renamed by hand to the control plane's name; a name
// in o.Nodes that is not a VM of the cluster; and, without o.Shrink, fewer
// cores or less memory than a VM runs with. have holds each owned VM's
// GuestSize by VMID.
func PlanResize(c Config, guests []pve.Resource, have map[int]GuestSize, o ResizeOptions) (ResizePlan, error) {
	var p ResizePlan
	var errs, shrinks []error
	names, want := c.sizes()
	owned := OwnedVMs(guests, c.Cluster)
	count := map[string]int{}
	for _, v := range owned {
		count[v.Name]++
	}
	var unknown []string
	for _, n := range o.Nodes {
		if count[n] == 0 {
			unknown = append(unknown, n)
		}
	}
	if len(unknown) > 0 {
		errs = append(errs, fmt.Errorf("not VMs of cluster %s: %s", c.Cluster, strings.Join(unknown, ", ")))
	}
	for i, v := range owned {
		if count[v.Name] > 1 {
			if i == 0 || owned[i-1].Name != v.Name {
				errs = append(errs, fmt.Errorf("%d VMs of cluster %s are named %s; resize changes none of them", count[v.Name], c.Cluster, v.Name))
			}
			continue
		}
		if len(o.Nodes) > 0 && !slices.Contains(o.Nodes, v.Name) {
			p.Notes = append(p.Notes, fmt.Sprintf("skip     %-24s vmid %d, not in -nodes", v.Name, v.VMID))
			continue
		}
		spec, ok := want[v.Name]
		if !ok {
			p.Notes = append(p.Notes, fmt.Sprintf("skip     %-24s vmid %d, not in the config; left as it is", v.Name, v.VMID))
			continue
		}
		if role, pool := RoleOf(v), PoolOf(v); role != spec.Role || pool != spec.Pool {
			errs = append(errs, fmt.Errorf("VM %s vmid %d is tagged role %q pool %q, but the config's %s is role %q pool %q",
				v.Name, v.VMID, role, pool, v.Name, spec.Role, spec.Pool))
			continue
		}
		size := spec.Size
		g, ok := have[v.VMID]
		if !ok {
			errs = append(errs, fmt.Errorf("VM %s vmid %d: its size was not read", v.Name, v.VMID))
			continue
		}
		if !o.Shrink && (size.Cores < g.Cores || size.MemoryMiB < g.MemoryMiB) {
			shrinks = append(shrinks, fmt.Errorf("%s vmid %d from %d cores and %d MiB to %d cores and %d MiB",
				v.Name, v.VMID, g.Cores, g.MemoryMiB, size.Cores, size.MemoryMiB))
			continue
		}
		params := url.Values{}
		if g.NextCores != size.Cores {
			params.Set("cores", strconv.Itoa(size.Cores))
		}
		if g.NextMemoryMiB != size.MemoryMiB {
			params.Set("memory", strconv.Itoa(size.MemoryMiB))
		}
		if len(params) == 0 && !g.Pending() {
			p.Notes = append(p.Notes, fmt.Sprintf("at size  %-24s vmid %d, %d cores, %d MiB", v.Name, v.VMID, g.Cores, g.MemoryMiB))
			continue
		}
		if len(params) > 0 {
			p.Calls = append(p.Calls, Call{
				Method: http.MethodPut,
				Path:   "/nodes/" + url.PathEscape(v.Node) + "/qemu/" + strconv.Itoa(v.VMID) + "/config",
				Params: params,
				What:   fmt.Sprintf("resize %s vmid %d on %s to %d cores and %d MiB", v.Name, v.VMID, v.Node, size.Cores, size.MemoryMiB),
			})
		}
		// From what it runs with now to what it will run with.
		change := describeChange(g.Cores, g.MemoryMiB, size.Cores, size.MemoryMiB)
		switch {
		case change == "":
			// The config asks for what it runs with, and Proxmox drops a
			// pending value equal to the current one, so nothing waits.
			p.Notes = append(p.Notes, fmt.Sprintf("resize   %-24s vmid %d, back to %d cores and %d MiB, which drops its pending change", v.Name, v.VMID, g.Cores, g.MemoryMiB))
		case v.Status == "running":
			verb := "resize  "
			if len(params) == 0 {
				verb = "pending "
			}
			p.Notes = append(p.Notes, fmt.Sprintf("%s %-24s vmid %d, %s at its next start", verb, v.Name, v.VMID, change))
			p.PowerCycle = append(p.PowerCycle, v.Name)
		case len(params) > 0:
			// A VM that is not running takes the change at once.
			p.Notes = append(p.Notes, fmt.Sprintf("resize   %-24s vmid %d, %s now, since it is %s", v.Name, v.VMID, change, v.Status))
		default:
			p.Notes = append(p.Notes, fmt.Sprintf("pending  %-24s vmid %d, %s when it starts, since it is %s", v.Name, v.VMID, change, v.Status))
		}
	}
	if len(shrinks) > 0 {
		errs = append(errs, fmt.Errorf("these would shrink: %w; pass the -config the cluster was created with, or -shrink to shrink them", errors.Join(shrinks...)))
	}
	for _, n := range names {
		if count[n] == 0 && len(o.Nodes) == 0 {
			p.Notes = append(p.Notes, fmt.Sprintf("missing  %-24s not created; talosvm create makes it at the config's size", n))
		}
	}
	if len(errs) > 0 {
		return ResizePlan{}, fmt.Errorf("refusing to resize: %w", errors.Join(errs...))
	}
	return p, nil
}

// describeChange says what changes, as "memory 8192 to 16384 MiB", with the
// cores too when they change.
func describeChange(cores, mem, toCores, toMem int) string {
	var parts []string
	if cores != toCores {
		parts = append(parts, fmt.Sprintf("cores %d to %d", cores, toCores))
	}
	if mem != toMem {
		parts = append(parts, fmt.Sprintf("memory %d to %d MiB", mem, toMem))
	}
	return strings.Join(parts, ", ")
}

// Resize sets the cores and memory of the cluster's existing VMs to the
// sizes the config gives them, which is how a pool's new size reaches VMs
// that create, which never changes an existing VM, made at the old one. It
// checks the config and the token's privileges, reads each of the cluster's
// VMs' current and pending size, prints what it found and the calls, and
// unless this is a dry run sends them.
//
// A running VM keeps its old size until it is stopped and started, which
// restart -mode power-cycle does one node at a time; Resize ends by printing
// that command for every running VM whose new size is waiting, including
// ones an earlier resize changed and nothing has restarted since.
func (r *Runner) Resize(ctx context.Context, o ResizeOptions) error {
	if err := r.Config.Validate(); err != nil {
		return err
	}
	if err := o.Validate(); err != nil {
		return err
	}
	if err := r.Check(ctx); err != nil {
		return err
	}
	guests, err := r.PVE.VMs(ctx)
	if err != nil {
		return err
	}
	have := map[int]GuestSize{}
	for _, v := range OwnedVMs(guests, r.Config.Cluster) {
		if have[v.VMID], err = r.guestSize(ctx, v); err != nil {
			return err
		}
	}
	plan, err := PlanResize(r.Config, guests, have, o)
	if err != nil {
		return err
	}
	for _, n := range plan.Notes {
		r.logf("%s", n)
	}
	if len(plan.Calls) > 0 {
		if err := r.send(ctx, plan.Calls); err != nil {
			return err
		}
	}
	if len(plan.PowerCycle) == 0 {
		if len(plan.Calls) == 0 {
			r.logf("nothing to do")
		}
		return nil
	}
	lead := "The new size"
	if r.DryRun && len(plan.Calls) > 0 {
		lead = "Once resize has run, the new size"
	}
	r.logf("%s of a running VM waits in Proxmox as a pending change: these VMs have no CPU or memory hotplug,", lead)
	r.logf("so it takes effect only when the VM is stopped and started, which a reboot inside the guest does not do.")
	r.logf("Power-cycle them one at a time with:")
	r.logf("  talosvm restart -cluster %s -mode power-cycle -nodes %s", r.Config.Cluster, strings.Join(plan.PowerCycle, ","))
	return nil
}
