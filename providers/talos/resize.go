package talos

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"

	"go.holos.run/distro/providers/infra"
)

// sized is one VM the config asks for, with its role, pool and size.
type sized struct {
	role, pool string
	Size
}

// sizes is every VM the config asks for, by name, with its role, pool and
// size, and the names in Specs order.
func (c Config) sizes() (names []string, vms map[string]sized) {
	vms = map[string]sized{}
	add := func(name string, s sized) {
		names = append(names, name)
		vms[name] = s
	}
	for i := range c.ControlPlane.Count {
		add(vmName(c.Cluster, controlPlaneName, i), sized{role: RoleControlPlane, Size: c.ControlPlane.Size})
	}
	for _, p := range c.Pools {
		for i := range p.Count {
			add(vmName(c.Cluster, p.Name, i), sized{role: RoleWorker, pool: p.Name, Size: p.Size})
		}
	}
	return names, vms
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

// ResizePlan is what resize found and what it has compute change.
type ResizePlan struct {
	// Notes say, a line per VM, what resize found.
	Notes []string
	// Resizes are the VMs whose cores or memory after their next start
	// differ from the config's, with the config's size.
	Resizes []infra.Resize
	// PowerCycle names, in name order, the running VMs whose new size
	// waits for their next start: those in Resizes and those that already
	// had a resize pending.
	PowerCycle []string
}

// PlanResize compares the cluster's VMs, as compute lists them, with the
// sizes the config gives their names, and plans a resize of each VM whose
// cores or memory after its next start differ from the config's. It never
// touches the disk, which the config's diskGiB does not change once a VM
// exists.
//
// A VM of the cluster that the config does not ask for, or that o.Nodes
// leaves out, is left as it is. These refuse the whole plan, before any
// change: two of the cluster's VMs with one name; a VM whose role or pool
// label is not the one the config gives its name, such as a worker renamed
// by hand to the control plane's name; a name in o.Nodes that is not a VM of
// the cluster; and, without o.Shrink, fewer cores or less memory than a VM
// runs with.
func PlanResize(c Config, vms []infra.VM, o ResizeOptions) (ResizePlan, error) {
	var p ResizePlan
	var errs, shrinks []error
	names, want := c.sizes()
	count := map[string]int{}
	for _, v := range vms {
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
	for i, v := range vms {
		if count[v.Name] > 1 {
			if i == 0 || vms[i-1].Name != v.Name {
				errs = append(errs, fmt.Errorf("%d VMs of cluster %s are named %s; resize changes none of them", count[v.Name], c.Cluster, v.Name))
			}
			continue
		}
		if len(o.Nodes) > 0 && !slices.Contains(o.Nodes, v.Name) {
			p.Notes = append(p.Notes, fmt.Sprintf("skip     %-24s %s, not in -nodes", v.Name, v.ID))
			continue
		}
		spec, ok := want[v.Name]
		if !ok {
			p.Notes = append(p.Notes, fmt.Sprintf("skip     %-24s %s, not in the config; left as it is", v.Name, v.ID))
			continue
		}
		if role, pool := v.Label(LabelRole), v.Label(LabelPool); role != spec.role || pool != spec.pool {
			errs = append(errs, fmt.Errorf("VM %s %s is tagged role %q pool %q, but the config's %s is role %q pool %q",
				v.Name, v.ID, role, pool, v.Name, spec.role, spec.pool))
			continue
		}
		size := infra.Size{Cores: spec.Cores, MemoryMiB: spec.MemoryMiB}
		if v.SizingErr != nil {
			errs = append(errs, fmt.Errorf("VM %s %s: its size was not read", v.Name, v.ID))
			continue
		}
		g := v.Sizing
		if !o.Shrink && (size.Cores < g.Now.Cores || size.MemoryMiB < g.Now.MemoryMiB) {
			shrinks = append(shrinks, fmt.Errorf("%s %s from %d cores and %d MiB to %d cores and %d MiB",
				v.Name, v.ID, g.Now.Cores, g.Now.MemoryMiB, size.Cores, size.MemoryMiB))
			continue
		}
		// Only what differs from the size after the next start changes.
		changes := g.Next != size
		if !changes && !g.Pending() {
			p.Notes = append(p.Notes, fmt.Sprintf("at size  %-24s %s, %d cores, %d MiB", v.Name, v.ID, g.Now.Cores, g.Now.MemoryMiB))
			continue
		}
		if changes {
			p.Resizes = append(p.Resizes, infra.Resize{VM: v, Size: size})
		}
		// From what it runs with now to what it will run with.
		change := describeChange(g.Now.Cores, g.Now.MemoryMiB, size.Cores, size.MemoryMiB)
		switch {
		case change == "":
			// The config asks for what it runs with, and compute drops a
			// pending value equal to the current one, so nothing waits.
			p.Notes = append(p.Notes, fmt.Sprintf("resize   %-24s %s, back to %d cores and %d MiB, which drops its pending change", v.Name, v.ID, g.Now.Cores, g.Now.MemoryMiB))
		case v.Status == "running":
			verb := "resize  "
			if !changes {
				verb = "pending "
			}
			p.Notes = append(p.Notes, fmt.Sprintf("%s %-24s %s, %s at its next start", verb, v.Name, v.ID, change))
			p.PowerCycle = append(p.PowerCycle, v.Name)
		case changes:
			// A VM that is not running takes the change at once.
			p.Notes = append(p.Notes, fmt.Sprintf("resize   %-24s %s, %s now, since it is %s", v.Name, v.ID, change, v.Status))
		default:
			p.Notes = append(p.Notes, fmt.Sprintf("pending  %-24s %s, %s when it starts, since it is %s", v.Name, v.ID, change, v.Status))
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
// checks the config and compute's credentials, lists the cluster's VMs with
// their current and pending size, prints what it found, and has compute
// print and, unless this is a dry run, make the changes.
//
// A running VM keeps its old size until it is stopped and started, which
// restart -mode power-cycle does one node at a time; Resize ends by printing
// that command for every running VM whose new size is waiting, including
// ones an earlier resize changed and nothing has restarted since.
func (r *Runner) Resize(ctx context.Context, o ResizeOptions) error {
	if err := r.Config.Validate(r.Compute.CheckAddress); err != nil {
		return err
	}
	if err := o.Validate(); err != nil {
		return err
	}
	if err := r.Compute.Check(ctx); err != nil {
		return err
	}
	vms, err := r.Compute.List(ctx, r.Config.Cluster)
	if err != nil {
		return err
	}
	for _, v := range vms {
		if v.SizingErr != nil {
			return v.SizingErr
		}
	}
	plan, err := PlanResize(r.Config, vms, o)
	if err != nil {
		return err
	}
	for _, n := range plan.Notes {
		r.logf("%s", n)
	}
	if len(plan.Resizes) > 0 {
		if err := r.Compute.Resize(ctx, r.Config.Cluster, plan.Resizes); err != nil {
			return err
		}
	}
	if len(plan.PowerCycle) == 0 {
		if len(plan.Resizes) == 0 {
			r.logf("nothing to do")
		}
		return nil
	}
	lead := "The new size"
	if r.DryRun && len(plan.Resizes) > 0 {
		lead = "Once resize has run, the new size"
	}
	r.logf("%s of a running VM waits in %s as a pending change: these VMs have no CPU or memory hotplug,", lead, r.Compute)
	r.logf("so it takes effect only when the VM is stopped and started, which a reboot inside the guest does not do.")
	r.logf("Power-cycle them one at a time with:")
	r.logf("  talosvm restart -cluster %s -mode power-cycle -nodes %s", r.Config.Cluster, strings.Join(plan.PowerCycle, ","))
	return nil
}
