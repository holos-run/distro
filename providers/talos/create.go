package talos

import (
	"context"
	"fmt"
	"io"

	"go.holos.run/distro/providers/infra"
)

// Runner carries what the subcommands share. It reaches the VMs only
// through Compute.
type Runner struct {
	Compute infra.Compute
	Factory Factory
	Config  Config
	Out     io.Writer
	// Err, when set, takes warnings that must stay out of Out.
	Err io.Writer
	// DryRun makes restart print every node's steps and take none. Compute
	// has a dry run of its own for the calls it makes, which the command
	// line sets with this one.
	DryRun bool
}

func (r *Runner) logf(format string, a ...any) {
	fmt.Fprintf(r.Out, format+"\n", a...)
}

func (r *Runner) warnf(format string, a ...any) {
	if r.Err != nil {
		fmt.Fprintf(r.Err, "talosvm: warning: "+format+"\n", a...)
	}
}

// Create makes every VM the config asks for that does not exist yet, and
// starts the cluster's existing VMs that are stopped. It validates the
// config, posts the schematic to Image Factory for the image the VMs boot,
// and has compute plan the VMs, which checks every address, gives each new
// VM its MAC and placement, and refuses any conflict before anything
// changes. It then renders each VM's nocloud network config from the NIC
// compute planned, and has compute create the VMs with it.
func (r *Runner) Create(ctx context.Context) error {
	c := r.Config
	if err := c.Validate(r.Compute.CheckAddress); err != nil {
		return err
	}
	specs, err := c.Specs()
	if err != nil {
		return err
	}
	// The image goes into every spec, so the schematic is posted before
	// the plan, and printed after the VMs that exist, as it always was.
	id, err := r.Factory.SchematicID(ctx)
	if err != nil {
		return err
	}
	img := Image{FactoryURL: r.Factory.BaseURL, SchematicID: id, TalosVersion: c.TalosVersion}
	description := fmt.Sprintf("Created by talosvm (go.holos.run/distro/providers/talos/cmd/talosvm) for cluster %s.\nTalos %s, schematic %s.",
		c.Cluster, c.TalosVersion, id)
	for i := range specs {
		specs[i].Image = img.Boot()
		specs[i].Description = description
	}
	plan, err := r.Compute.Plan(ctx, c.Cluster, specs)
	if err != nil {
		return err
	}
	vms := plan.VMs()
	for i, vm := range vms {
		if vm.ID.Value == "" {
			continue
		}
		r.logf("exists   %-24s %s on %s", vm.Name, vm.ID, vm.Zone)
		r.sizeHint(vm, specs[i].Size)
	}
	r.logf("schematic %s", id)
	r.logf("installer %s", img.Installer())
	configs := map[string]string{}
	for _, vm := range vms {
		configs[vm.Name] = NetworkConfig(vm.NIC)
	}
	return r.Compute.Create(ctx, plan, configs)
}

// sizeHint points at what brings an existing VM to the config's size, since
// create never resizes one. Compute reports the size the VM runs with; only
// when that differs does its Sizing, the VM's own config, decide. A pending
// size equal to the config's needs only a power cycle; any other needs
// resize. A Sizing that could not be read is no reason to stop create, so
// the hint then assumes nothing is pending.
func (r *Runner) sizeHint(vm infra.VM, want infra.Size) {
	cores, mem := vm.Size.Cores, vm.Size.MemoryMiB
	if cores == want.Cores && mem == want.MemoryMiB {
		return
	}
	// The size compute's inventory reports can lag a power cycle by a few
	// seconds, so the VM's own config decides whether the config's size is
	// already set.
	g, err := vm.Sizing, vm.SizingErr
	if err != nil {
		r.warnf("reading the pending size of %s: %v", vm.Name, err)
	}
	pending := err == nil && g.Pending() && g.Next == want
	switch {
	case err == nil && !g.Pending() && g.Now == want:
		return
	case pending && vm.Status == "running":
		r.logf("         runs with %d cores and %d MiB; the config's %d and %d are pending until a power cycle: talosvm restart -cluster %s -mode power-cycle -nodes %s",
			cores, mem, want.Cores, want.MemoryMiB, r.Config.Cluster, vm.Name)
	case pending:
		r.logf("         has %d cores and %d MiB; the config's %d and %d are pending until it starts",
			cores, mem, want.Cores, want.MemoryMiB)
	default:
		r.logf("         runs with %d cores and %d MiB, the config asks for %d and %d: talosvm resize -cluster %s sets it",
			cores, mem, want.Cores, want.MemoryMiB, r.Config.Cluster)
	}
}
