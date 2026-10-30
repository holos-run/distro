package talos

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"

	"go.holos.run/distro/providers/infra"
)

var (
	controlPlane = []infra.Label{{Key: LabelRole, Value: RoleControlPlane}}
	general      = []infra.Label{{Key: LabelRole, Value: RoleWorker}, {Key: LabelPool, Value: "general"}}
)

// resizeVMs is a treasury cluster made at the old 8 GiB worker size, as
// compute lists it, plus a VM the config does not ask for. general-2 is
// stopped, and general-3 has the new size pending from an earlier resize.
func resizeVMs() []infra.VM {
	f := newFakeCompute("treasury")
	f.add("treasury-cp-1", "r620a", "10.20.0.50", infra.Size{Cores: 2, MemoryMiB: 8192}, controlPlane...)
	for _, n := range []string{"treasury-general-1", "treasury-general-2", "treasury-general-3", "treasury-general-4"} {
		f.add(n, "r620b", "", infra.Size{Cores: 4, MemoryMiB: 8192}, general...)
	}
	f.find("treasury-general-2").Status = "stopped"
	f.find("treasury-general-3").Sizing.Next.MemoryMiB = 16384
	return f.vms
}

// resizes is the plan's resizes as "name cores/MiB".
func resizes(p ResizePlan) []string {
	var out []string
	for _, z := range p.Resizes {
		out = append(out, fmt.Sprintf("%s %d/%d", z.VM.Name, z.Size.Cores, z.Size.MemoryMiB))
	}
	return out
}

func TestPlanResize(t *testing.T) {
	vms := resizeVMs()
	p, err := PlanResize(treasury(), vms, ResizeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	// The VMs whose size after their next start is not the config's.
	if got, want := resizes(p), []string{"treasury-general-1 4/16384", "treasury-general-2 4/16384"}; !slices.Equal(got, want) {
		t.Errorf("resizes = %v, want %v", got, want)
	}
	// The stopped VM takes its new size at once; the running one and the
	// one resized earlier wait for a power cycle.
	if want := []string{"treasury-general-1", "treasury-general-3"}; !slices.Equal(p.PowerCycle, want) {
		t.Errorf("PowerCycle = %v, want %v", p.PowerCycle, want)
	}
	want := []string{
		"at size  treasury-cp-1            id 104, 2 cores, 8192 MiB",
		"resize   treasury-general-1       id 105, memory 8192 to 16384 MiB at its next start",
		"resize   treasury-general-2       id 106, memory 8192 to 16384 MiB now, since it is stopped",
		"pending  treasury-general-3       id 107, memory 8192 to 16384 MiB at its next start",
		"skip     treasury-general-4       id 108, not in the config; left as it is",
	}
	if !slices.Equal(p.Notes, want) {
		t.Errorf("notes =\n%s\nwant\n%s", strings.Join(p.Notes, "\n"), strings.Join(want, "\n"))
	}

	// New cores go in the same resize as the memory; a pool the cluster
	// does not have yet is create's to make.
	c := treasury()
	c.Pools[0].Cores = 8
	c.Pools = append(c.Pools, Pool{Name: "microvm", Count: 1, Size: c.Pools[0].Size})
	p, err = PlanResize(c, vms, ResizeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := resizes(p), []string{"treasury-general-1 8/16384", "treasury-general-2 8/16384", "treasury-general-3 8/16384"}; !slices.Equal(got, want) {
		t.Errorf("resizes with new cores = %v, want %v", got, want)
	}
	if last := p.Notes[len(p.Notes)-1]; !strings.HasPrefix(last, "missing  treasury-microvm-1") {
		t.Errorf("last note = %q, want treasury-microvm-1 missing", last)
	}

	// Setting a VM back to what it runs with drops the pending change, so
	// it needs no power cycle.
	c = treasury()
	c.Pools[0].MemoryMiB = 8192
	p, err = PlanResize(c, vms, ResizeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if got := resizes(p); !slices.Equal(got, []string{"treasury-general-3 4/8192"}) || len(p.PowerCycle) != 0 {
		t.Errorf("undo: resizes %v, power cycle %v", got, p.PowerCycle)
	}
	if !slices.Contains(p.Notes, "resize   treasury-general-3       id 107, back to 4 cores and 8192 MiB, which drops its pending change") {
		t.Errorf("undo notes =\n%s", strings.Join(p.Notes, "\n"))
	}

	// A cluster with no VMs has nothing to resize.
	if p, err := PlanResize(treasury(), nil, ResizeOptions{}); err != nil || len(p.Resizes) != 0 || len(p.PowerCycle) != 0 {
		t.Errorf("PlanResize over no VMs = %+v, %v", p, err)
	}

	// Two of the cluster's VMs with one name stop the whole plan.
	dup := slices.Clone(vms)
	dup = slices.Insert(dup, 3, dup[2])
	if _, err := PlanResize(treasury(), dup, ResizeOptions{}); err == nil || !strings.Contains(err.Error(), "2 VMs of cluster treasury are named treasury-general-2") {
		t.Errorf("PlanResize with a duplicate = %v", err)
	}

	// A VM whose size compute could not read refuses the plan.
	bad := slices.Clone(vms)
	bad[1].SizingErr, bad[1].Sizing = errors.New("no memory"), infra.Sizing{}
	if _, err := PlanResize(treasury(), bad, ResizeOptions{}); err == nil || !strings.Contains(err.Error(), "VM treasury-general-1 id 105: its size was not read") {
		t.Errorf("PlanResize with an unread size = %v", err)
	}
}

// resize never shrinks a VM unless told to: without -config it takes the
// built-in sizes, which may be smaller than the ones the cluster was made
// with.
func TestPlanResizeRefusesShrink(t *testing.T) {
	vms := resizeVMs()
	c := treasury()
	c.Pools[0].MemoryMiB = 4096
	_, err := PlanResize(c, vms, ResizeOptions{})
	for _, want := range []string{
		"treasury-general-1 id 105 from 4 cores and 8192 MiB to 4 cores and 4096 MiB",
		"treasury-general-2 id 106 from 4 cores and 8192 MiB to 4 cores and 4096 MiB",
		"treasury-general-3 id 107 from 4 cores and 8192 MiB to 4 cores and 4096 MiB",
		"pass the -config the cluster was created with, or -shrink",
	} {
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("shrink err = %v, want it to mention %q", err, want)
		}
	}
	c.ControlPlane.Cores = 1 // fewer cores is a shrink too
	if _, err := PlanResize(c, vms, ResizeOptions{}); err == nil || !strings.Contains(err.Error(), "treasury-cp-1 id 104 from 2 cores") {
		t.Errorf("cores shrink err = %v", err)
	}
	c.ControlPlane.Cores = 2
	p, err := PlanResize(c, vms, ResizeOptions{Shrink: true})
	if err != nil {
		t.Fatal(err)
	}
	if got := resizes(p); len(got) != 3 || got[0] != "treasury-general-1 4/4096" {
		t.Errorf("-shrink resizes = %v", got)
	}
}

// A VM's role and pool labels must be the ones the config gives its name, so
// a worker renamed by hand to the control plane's name is not sized as one.
func TestPlanResizeChecksRoleAndPool(t *testing.T) {
	for _, labels := range [][]infra.Label{
		general, // a worker named treasury-cp-1
		{{Key: LabelRole, Value: RoleControlPlane}, {Key: LabelPool, Value: "general"}},
		nil,
	} {
		vms := resizeVMs()
		vms[0].Labels = labels
		if _, err := PlanResize(treasury(), vms, ResizeOptions{}); err == nil || !strings.Contains(err.Error(), "VM treasury-cp-1 id 104 is tagged role") {
			t.Errorf("labels %v: err = %v, want a refusal", labels, err)
		}
	}
	vms := resizeVMs()
	vms[1].Labels = []infra.Label{{Key: LabelRole, Value: RoleWorker}, {Key: LabelPool, Value: "microvm"}}
	if _, err := PlanResize(treasury(), vms, ResizeOptions{}); err == nil || !strings.Contains(err.Error(), `pool "microvm", but the config's treasury-general-1 is role "worker" pool "general"`) {
		t.Errorf("wrong pool: err = %v", err)
	}
}

// -nodes limits the resizes to the VMs it names.
func TestPlanResizeNodes(t *testing.T) {
	vms := resizeVMs()
	p, err := PlanResize(treasury(), vms, ResizeOptions{Nodes: []string{"treasury-general-1"}})
	if err != nil {
		t.Fatal(err)
	}
	if got := resizes(p); !slices.Equal(got, []string{"treasury-general-1 4/16384"}) {
		t.Errorf("resizes = %v", got)
	}
	if !slices.Equal(p.PowerCycle, []string{"treasury-general-1"}) {
		t.Errorf("PowerCycle = %v", p.PowerCycle)
	}
	if !slices.Contains(p.Notes, "skip     treasury-general-2       id 106, not in -nodes") {
		t.Errorf("notes =\n%s", strings.Join(p.Notes, "\n"))
	}
	// A name that is not one of the cluster's VMs, such as another
	// cluster's or one not created yet, refuses the run.
	for _, n := range []string{"treasury-general-9", "lab-general-1", "jeffsbox"} {
		if _, err := PlanResize(treasury(), vms, ResizeOptions{Nodes: []string{n}}); err == nil || !strings.Contains(err.Error(), "not VMs of cluster treasury: "+n) {
			t.Errorf("-nodes %s: err = %v", n, err)
		}
	}
}

// A cluster made at the old size, resized to the new default, then power
// cycled, through the fake compute.
func TestResize(t *testing.T) {
	f := newFakeCompute("treasury")
	old := treasury()
	old.Pools[0].MemoryMiB = 8192
	r, out := newRunner(t, f, old)
	ctx := context.Background()
	if err := r.Create(ctx); err != nil {
		t.Fatalf("Create: %v\n%s", err, out)
	}
	r.Config = treasury()

	// A dry run says what changes and the restart to follow, and has
	// compute, in its own dry run, change nothing.
	f.log, f.dryRun, r.DryRun = nil, true, true
	out.Reset()
	if err := r.Resize(ctx, ResizeOptions{}); err != nil {
		t.Fatalf("Resize: %v\n%s", err, out)
	}
	t.Log(out)
	restartCmd := "  talosvm restart -cluster treasury -mode power-cycle -nodes treasury-general-1,treasury-general-2,treasury-general-3\n"
	for _, want := range []string{
		"at size  treasury-cp-1            id 104, 2 cores, 8192 MiB\n",
		"resize   treasury-general-2       id 106, memory 8192 to 16384 MiB at its next start\n",
		"Once resize has run, the new size of a running VM waits in the fake as a pending change",
		restartCmd,
	} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("dry-run resize output lacks %q:\n%s", want, out)
		}
	}
	if want := []string{
		"would resize treasury-general-1 to 4 cores and 16384 MiB",
		"would resize treasury-general-2 to 4 cores and 16384 MiB",
		"would resize treasury-general-3 to 4 cores and 16384 MiB",
	}; !slices.Equal(f.log, want) {
		t.Errorf("dry-run resize = %v", f.log)
	}

	// The real run resizes each worker and nothing else.
	f.log, f.dryRun, r.DryRun = nil, false, false
	out.Reset()
	if err := r.Resize(ctx, ResizeOptions{}); err != nil {
		t.Fatalf("Resize: %v\n%s", err, out)
	}
	if len(f.log) != 3 || !strings.Contains(out.String(), "The new size of a running VM waits in the fake") || !strings.Contains(out.String(), restartCmd) {
		t.Errorf("resize changed %v:\n%s", f.log, out)
	}

	// A rerun before the restart changes nothing and still prints the
	// restart that applies it.
	f.log = nil
	out.Reset()
	if err := r.Resize(ctx, ResizeOptions{}); err != nil {
		t.Fatal(err)
	}
	if len(f.log) != 0 || !strings.Contains(out.String(), "pending  treasury-general-1") || !strings.Contains(out.String(), restartCmd) {
		t.Errorf("rerun changed %v:\n%s", f.log, out)
	}

	// After a power cycle resize has nothing to do.
	for _, n := range treasuryWorkers {
		if err := f.PowerCycle(ctx, "treasury", *f.find(n), 0); err != nil {
			t.Fatal(err)
		}
	}
	f.log = nil
	out.Reset()
	if err := r.Resize(ctx, ResizeOptions{}); err != nil {
		t.Fatal(err)
	}
	if len(f.log) != 0 || out.String() != strings.Join([]string{
		"at size  treasury-cp-1            id 104, 2 cores, 8192 MiB",
		"at size  treasury-general-1       id 105, 4 cores, 16384 MiB",
		"at size  treasury-general-2       id 106, 4 cores, 16384 MiB",
		"at size  treasury-general-3       id 107, 4 cores, 16384 MiB",
		"nothing to do\n"}, "\n") {
		t.Errorf("resize after the restart changed %v:\n%s", f.log, out)
	}
}

// resize refuses, before any change, a shrink, a size compute could not
// read, and a missing privilege.
func TestResizeRefuses(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func(*Runner, *fakeCompute)
		want string
	}{
		{"shrink", func(r *Runner, _ *fakeCompute) { r.Config.ControlPlane.MemoryMiB = 4096 },
			"treasury-cp-1 id 104 from 2 cores and 8192 MiB to 2 cores and 4096 MiB"},
		{"unread size", func(_ *Runner, f *fakeCompute) {
			f.find("treasury-general-2").SizingErr = errors.New("VM treasury-general-2 id 106: its config has no memory")
		}, "VM treasury-general-2 id 106: its config has no memory"},
		{"privilege", func(_ *Runner, f *fakeCompute) { f.checkErr = errors.New("the token lacks VM.Config.Memory") }, "VM.Config.Memory"},
	} {
		f := newFakeCompute("treasury")
		old := treasury()
		old.Pools[0].MemoryMiB = 8192
		r, out := newRunner(t, f, old)
		if err := r.Create(context.Background()); err != nil {
			t.Fatalf("Create: %v\n%s", err, out)
		}
		r.Config = treasury()
		tc.edit(r, f)
		f.log = nil
		if err := r.Resize(context.Background(), ResizeOptions{}); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: err = %v, want %q", tc.name, err, tc.want)
		}
		if len(f.log) != 0 {
			t.Errorf("%s: changed %v", tc.name, f.log)
		}
	}
}

// A cluster made with -workers 5 and resized with the same -workers, which
// the command line applies as Pools[0].Count, resizes workers 4 and 5 too;
// without it they are skipped as VMs the config does not ask for.
func TestResizeWithWorkers(t *testing.T) {
	f := newFakeCompute("treasury")
	old := treasury()
	old.Pools[0].Count, old.Pools[0].MemoryMiB = 5, 8192
	r, out := newRunner(t, f, old)
	ctx := context.Background()
	if err := r.Create(ctx); err != nil {
		t.Fatalf("Create: %v\n%s", err, out)
	}
	r.Config = treasury()
	r.Config.Pools[0].Count = 5
	r.DryRun, f.dryRun = true, true
	out.Reset()
	if err := r.Resize(ctx, ResizeOptions{}); err != nil {
		t.Fatalf("Resize: %v\n%s", err, out)
	}
	for _, want := range []string{
		"resize   treasury-general-4       id 108, memory 8192 to 16384 MiB at its next start\n",
		"resize   treasury-general-5       id 109, memory 8192 to 16384 MiB at its next start\n",
		"-nodes treasury-general-1,treasury-general-2,treasury-general-3,treasury-general-4,treasury-general-5\n",
	} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("resize -workers 5 output lacks %q:\n%s", want, out)
		}
	}
	r.Config.Pools[0].Count = 3
	out.Reset()
	if err := r.Resize(ctx, ResizeOptions{}); err != nil {
		t.Fatalf("Resize: %v\n%s", err, out)
	}
	if !strings.Contains(out.String(), "skip     treasury-general-5       id 109, not in the config") {
		t.Errorf("resize without -workers:\n%s", out)
	}
}
