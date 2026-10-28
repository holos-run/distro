package talosvm

import (
	"bytes"
	"context"
	"encoding/json"
	"net/url"
	"slices"
	"strings"
	"testing"
	"time"

	"go.holos.run/distro/providers/proxmox/internal/pve"
)

func TestGuestSizeOf(t *testing.T) {
	for _, tc := range []struct {
		name  string
		items []pve.PendingItem
		want  GuestSize
		err   string
	}{
		{"at size", []pve.PendingItem{{Key: "cores", Value: "4"}, {Key: "memory", Value: "16384"}, {Key: "balloon", Value: "0"}},
			GuestSize{4, 16384, 4, 16384}, ""},
		{"memory pending", []pve.PendingItem{{Key: "cores", Value: "4"}, {Key: "memory", Value: "8192", Pending: "16384", HasPending: true}},
			GuestSize{4, 8192, 4, 16384}, ""},
		{"property string", []pve.PendingItem{{Key: "cores", Value: "2", Pending: "4", HasPending: true}, {Key: "memory", Value: "current=6144"}},
			GuestSize{2, 6144, 4, 6144}, ""},
		{"no memory", []pve.PendingItem{{Key: "cores", Value: "4"}}, GuestSize{}, "no memory"},
		{"memory deleted", []pve.PendingItem{{Key: "cores", Value: "4"}, {Key: "memory", Value: "8192", Delete: 1}}, GuestSize{}, "pending deletion"},
		{"garbage", []pve.PendingItem{{Key: "cores", Value: "four"}, {Key: "memory", Value: "8192"}}, GuestSize{}, `cores "four"`},
	} {
		got, err := GuestSizeOf(tc.items)
		switch {
		case tc.err != "":
			if err == nil || !strings.Contains(err.Error(), tc.err) {
				t.Errorf("%s: err = %v, want %q", tc.name, err, tc.err)
			}
		case err != nil || got != tc.want:
			t.Errorf("%s: GuestSizeOf = %+v, %v, want %+v", tc.name, got, err, tc.want)
		}
	}
}

// resizeGuests is the garage's tenants and a treasury cluster made at the
// old 8 GiB worker size, plus VMs resize must leave alone: a hand-made VM
// with a treasury name, another cluster's worker, and a treasury VM the
// config does not ask for.
func resizeGuests() ([]pve.Resource, map[int]GuestSize) {
	worker := "talosvm;talosvm-cluster-treasury;talosvm-role-worker;talosvm-pool-general"
	guests := append(tenants(),
		res(104, "treasury-cp-1", "r620a", "talosvm;talosvm-cluster-treasury;talosvm-role-controlplane"),
		res(105, "treasury-general-1", "r620b", worker),
		res(106, "treasury-general-2", "r620c", worker),
		res(107, "treasury-general-3", "r620a", worker),
		res(108, "treasury-general-4", "r620b", worker),
		res(300, "treasury-general-1", "r620c", ""),
		res(120, "lab-general-1", "r620c", "talosvm;talosvm-cluster-lab;talosvm-role-worker;talosvm-pool-general"),
	)
	guests[slices.IndexFunc(guests, func(g pve.Resource) bool { return g.VMID == 106 })].Status = "stopped"
	have := map[int]GuestSize{
		104: {2, 6144, 2, 6144},
		105: {4, 8192, 4, 8192},
		106: {4, 8192, 4, 8192},
		107: {4, 8192, 4, 16384}, // an earlier resize, not restarted since
		108: {4, 8192, 4, 8192},
		300: {4, 8192, 4, 8192},
		120: {4, 8192, 4, 8192},
	}
	return guests, have
}

func TestPlanResize(t *testing.T) {
	guests, have := resizeGuests()
	p, err := PlanResize(treasury(), guests, have, ResizeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	// Memory only, since the cores already match, and never balloon.
	if got, want := printedCalls(p.Calls), []string{
		"PUT /api2/json/nodes/r620b/qemu/105/config\n    memory=16384",
		"PUT /api2/json/nodes/r620c/qemu/106/config\n    memory=16384",
	}; !slices.Equal(got, want) {
		t.Errorf("calls =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	// The stopped VM takes its new size at once; the running one and the
	// one resized earlier wait for a power cycle.
	if want := []string{"treasury-general-1", "treasury-general-3"}; !slices.Equal(p.PowerCycle, want) {
		t.Errorf("PowerCycle = %v, want %v", p.PowerCycle, want)
	}
	want := []string{
		"at size  treasury-cp-1            vmid 104, 2 cores, 6144 MiB",
		"resize   treasury-general-1       vmid 105, memory 8192 to 16384 MiB at its next start",
		"resize   treasury-general-2       vmid 106, memory 8192 to 16384 MiB now, since it is stopped",
		"pending  treasury-general-3       vmid 107, memory 8192 to 16384 MiB at its next start",
		"skip     treasury-general-4       vmid 108, not in the config; left as it is",
	}
	if !slices.Equal(p.Notes, want) {
		t.Errorf("notes =\n%s\nwant\n%s", strings.Join(p.Notes, "\n"), strings.Join(want, "\n"))
	}

	// New cores go in the same call as the memory; a pool the cluster
	// does not have yet is create's to make.
	c := treasury()
	c.Pools[0].Cores = 8
	c.Pools = append(c.Pools, Pool{Name: "microvm", Count: 1, Size: c.Pools[0].Size})
	p, err = PlanResize(c, guests, have, ResizeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if got := printedCalls(p.Calls); len(got) != 3 || got[0] != "PUT /api2/json/nodes/r620b/qemu/105/config\n    cores=8\n    memory=16384" ||
		got[2] != "PUT /api2/json/nodes/r620a/qemu/107/config\n    cores=8" {
		t.Errorf("calls with new cores =\n%s", strings.Join(got, "\n"))
	}
	if last := p.Notes[len(p.Notes)-1]; !strings.HasPrefix(last, "missing  treasury-microvm-1") {
		t.Errorf("last note = %q, want treasury-microvm-1 missing", last)
	}

	// Setting a VM back to what it runs with drops the pending change, so
	// it needs no power cycle.
	c = treasury()
	c.Pools[0].MemoryMiB = 8192
	p, err = PlanResize(c, guests, have, ResizeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if got := printedCalls(p.Calls); !slices.Equal(got, []string{"PUT /api2/json/nodes/r620a/qemu/107/config\n    memory=8192"}) || len(p.PowerCycle) != 0 {
		t.Errorf("undo: calls %v, power cycle %v", got, p.PowerCycle)
	}

	// None of another tenant's or another cluster's VMs is ever selected.
	if p, err := PlanResize(treasury(), tenants(), nil, ResizeOptions{}); err != nil || len(p.Calls) != 0 || len(p.PowerCycle) != 0 {
		t.Errorf("PlanResize over tenants = %+v, %v", p, err)
	}

	// Two of the cluster's VMs with one name stop the whole plan.
	dup := append(guests, res(109, "treasury-general-2", "r620a", "talosvm;talosvm-cluster-treasury"))
	have[109] = have[106]
	if _, err := PlanResize(treasury(), dup, have, ResizeOptions{}); err == nil || !strings.Contains(err.Error(), "2 VMs of cluster treasury are named treasury-general-2") {
		t.Errorf("PlanResize with a duplicate = %v", err)
	}
}

// resize never shrinks a VM unless told to: without -config it takes the
// built-in sizes, which may be smaller than the ones the cluster was made
// with.
func TestPlanResizeRefusesShrink(t *testing.T) {
	guests, have := resizeGuests()
	c := treasury()
	c.Pools[0].MemoryMiB = 4096
	_, err := PlanResize(c, guests, have, ResizeOptions{})
	for _, want := range []string{
		"treasury-general-1 vmid 105 from 4 cores and 8192 MiB to 4 cores and 4096 MiB",
		"treasury-general-2 vmid 106 from 4 cores and 8192 MiB to 4 cores and 4096 MiB",
		"treasury-general-3 vmid 107 from 4 cores and 8192 MiB to 4 cores and 4096 MiB",
		"pass the -config the cluster was created with, or -shrink",
	} {
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("shrink err = %v, want it to mention %q", err, want)
		}
	}
	c.ControlPlane.Cores = 1 // fewer cores is a shrink too
	if _, err := PlanResize(c, guests, have, ResizeOptions{}); err == nil || !strings.Contains(err.Error(), "treasury-cp-1 vmid 104 from 2 cores") {
		t.Errorf("cores shrink err = %v", err)
	}
	c.ControlPlane.Cores = 2
	p, err := PlanResize(c, guests, have, ResizeOptions{Shrink: true})
	if err != nil {
		t.Fatal(err)
	}
	if got := printedCalls(p.Calls); len(got) != 3 || got[0] != "PUT /api2/json/nodes/r620b/qemu/105/config\n    memory=4096" {
		t.Errorf("-shrink calls =\n%s", strings.Join(got, "\n"))
	}
}

// A VM's role and pool tags must be the ones the config gives its name, so a
// worker renamed by hand to the control plane's name is not sized as one.
func TestPlanResizeChecksRoleAndPool(t *testing.T) {
	for _, tags := range []string{
		"talosvm;talosvm-cluster-treasury;talosvm-role-worker;talosvm-pool-general", // a worker named treasury-cp-1
		"talosvm;talosvm-cluster-treasury;talosvm-role-controlplane;talosvm-pool-general",
		"talosvm;talosvm-cluster-treasury",
	} {
		guests, have := resizeGuests()
		guests[slices.IndexFunc(guests, func(g pve.Resource) bool { return g.VMID == 104 })].Tags = tags
		if _, err := PlanResize(treasury(), guests, have, ResizeOptions{}); err == nil || !strings.Contains(err.Error(), "VM treasury-cp-1 vmid 104 is tagged role") {
			t.Errorf("tags %s: err = %v, want a refusal", tags, err)
		}
	}
	guests, have := resizeGuests()
	guests[slices.IndexFunc(guests, func(g pve.Resource) bool { return g.VMID == 105 })].Tags = "talosvm;talosvm-cluster-treasury;talosvm-role-worker;talosvm-pool-microvm"
	if _, err := PlanResize(treasury(), guests, have, ResizeOptions{}); err == nil || !strings.Contains(err.Error(), `pool "microvm", but the config's treasury-general-1 is role "worker" pool "general"`) {
		t.Errorf("wrong pool: err = %v", err)
	}
}

// -nodes limits the calls to the VMs it names.
func TestPlanResizeNodes(t *testing.T) {
	guests, have := resizeGuests()
	p, err := PlanResize(treasury(), guests, have, ResizeOptions{Nodes: []string{"treasury-general-1"}})
	if err != nil {
		t.Fatal(err)
	}
	if got := printedCalls(p.Calls); !slices.Equal(got, []string{"PUT /api2/json/nodes/r620b/qemu/105/config\n    memory=16384"}) {
		t.Errorf("calls = %v", got)
	}
	if !slices.Equal(p.PowerCycle, []string{"treasury-general-1"}) {
		t.Errorf("PowerCycle = %v", p.PowerCycle)
	}
	if !slices.Contains(p.Notes, "skip     treasury-general-2       vmid 106, not in -nodes") {
		t.Errorf("notes =\n%s", strings.Join(p.Notes, "\n"))
	}
	// A name that is not one of the cluster's VMs, such as a tenant's or
	// one not created yet, refuses the run.
	for _, n := range []string{"treasury-general-9", "lab-general-1", "jeffsbox"} {
		if _, err := PlanResize(treasury(), guests, have, ResizeOptions{Nodes: []string{n}}); err == nil || !strings.Contains(err.Error(), "not VMs of cluster treasury: "+n) {
			t.Errorf("-nodes %s: err = %v", n, err)
		}
	}
}

// A cluster made at the old size, resized to the new default, then power
// cycled, through the fake Proxmox.
func TestResize(t *testing.T) {
	f := newFake()
	old := treasury()
	old.Pools[0].MemoryMiB = 8192
	r, out := newRunner(t, f, old)
	ctx := context.Background()
	if err := r.Create(ctx); err != nil {
		t.Fatalf("Create: %v\n%s", err, out)
	}
	r.Config = treasury()

	// create points at resize and changes nothing.
	f.calls = nil
	out.Reset()
	r.DryRun = true
	if err := r.Create(ctx); err != nil {
		t.Fatalf("Create: %v\n%s", err, out)
	}
	if !strings.Contains(out.String(), "runs with 4 cores and 8192 MiB, the config asks for 4 and 16384: talosvm resize -cluster treasury sets it") {
		t.Errorf("create does not point at resize:\n%s", out)
	}
	if len(f.calls) != 0 {
		t.Errorf("dry-run create sent %v", f.calls)
	}

	// A hand-made VM with a treasury name and another cluster's worker,
	// both at the old size; resize must not touch either.
	f.vms = append(f.vms,
		res(300, "treasury-general-1", "r620c", ""),
		res(120, "lab-general-1", "r620c", "talosvm;talosvm-cluster-lab;talosvm-role-worker;talosvm-pool-general"))
	f.configs[300] = map[string]string{"cores": "4", "memory": "8192"}
	f.configs[120] = map[string]string{"cores": "4", "memory": "8192"}

	// A dry run prints the exact calls and the restart to follow, and
	// sends nothing.
	out.Reset()
	if err := r.Resize(ctx, ResizeOptions{}); err != nil {
		t.Fatalf("Resize: %v\n%s", err, out)
	}
	t.Log(out)
	if len(f.calls) != 0 {
		t.Errorf("dry-run resize sent %v", f.calls)
	}
	restartCmd := "  talosvm restart -cluster treasury -mode power-cycle -nodes treasury-general-1,treasury-general-2,treasury-general-3\n"
	for _, want := range []string{
		"at size  treasury-cp-1            vmid 104, 2 cores, 6144 MiB\n",
		"resize   treasury-general-2       vmid 106, memory 8192 to 16384 MiB at its next start\n",
		"PUT /api2/json/nodes/r620c/qemu/106/config\n    memory=16384\n",
		"dry run: sent none of these 3 calls\n",
		"Once resize has run, the new size of a running VM waits in Proxmox as a pending change",
		restartCmd,
	} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("dry-run resize output lacks %q:\n%s", want, out)
		}
	}

	// The real run sends exactly memory to each worker and nothing else.
	f.forms = nil
	out.Reset()
	r.DryRun = false
	if err := r.Resize(ctx, ResizeOptions{}); err != nil {
		t.Fatalf("Resize: %v\n%s", err, out)
	}
	if want := []string{"PUT /nodes/r620b/qemu/105/config", "PUT /nodes/r620c/qemu/106/config", "PUT /nodes/r620a/qemu/107/config"}; !slices.Equal(f.calls, want) {
		t.Errorf("resize sent %v, want %v", f.calls, want)
	}
	for i, form := range f.forms {
		if want := (url.Values{"memory": {"16384"}}); !equalForms(form, want) {
			t.Errorf("call %d form = %v, want %v", i, form, want)
		}
	}
	if !strings.Contains(out.String(), restartCmd) {
		t.Errorf("resize does not print the restart:\n%s", out)
	}
	for _, id := range []int{300, 120} {
		if f.configs[id]["memory"] != "8192" || len(f.pending[id]) != 0 {
			t.Errorf("vmid %d was changed: %v, pending %v", id, f.configs[id], f.pending[id])
		}
	}

	// list shows the pending memory of the running VMs.
	rows := listRows(t, r)
	for _, v := range rows[1:] {
		if v.MemoryMiB != 8192 || v.PendingMemoryMiB != 16384 || v.PendingCores != 0 {
			t.Errorf("list row before the restart: %+v", v)
		}
	}

	// A rerun before the restart sends nothing and still prints the
	// restart that applies it.
	f.calls, f.forms = nil, nil
	out.Reset()
	if err := r.Resize(ctx, ResizeOptions{}); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 0 || !strings.Contains(out.String(), "pending  treasury-general-1") || !strings.Contains(out.String(), restartCmd) {
		t.Errorf("rerun sent %v:\n%s", f.calls, out)
	}

	// After a power cycle the workers run with 16 GiB, ballooning still
	// off, and resize has nothing to do.
	for _, v := range OwnedVMs(f.vms, "treasury") {
		if RoleOf(v) != RoleWorker {
			continue
		}
		shutdown, start := powerCycleCalls(v, time.Minute)
		for _, c := range []Call{shutdown, start} {
			if err := r.call(ctx, c); err != nil {
				t.Fatal(err)
			}
		}
		if f.configs[v.VMID]["balloon"] != "0" {
			t.Errorf("%s balloon = %q", v.Name, f.configs[v.VMID]["balloon"])
		}
	}
	for _, v := range listRows(t, r)[1:] {
		if v.MemoryMiB != 16384 || v.PendingMemoryMiB != 0 {
			t.Errorf("list row after the restart: %+v", v)
		}
	}
	f.calls = nil
	out.Reset()
	if err := r.Resize(ctx, ResizeOptions{}); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 0 || !strings.HasSuffix(out.String(), "nothing to do\n") || strings.Contains(out.String(), "power-cycle") {
		t.Errorf("resize after the restart sent %v:\n%s", f.calls, out)
	}
}

func listRows(t *testing.T, r *Runner) []VM {
	t.Helper()
	var b strings.Builder
	saved := r.Out
	r.Out = &b
	defer func() { r.Out = saved }()
	if err := r.List(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	var rows []VM
	if err := json.Unmarshal([]byte(b.String()), &rows); err != nil {
		t.Fatal(err)
	}
	if len(rows) != 4 || rows[0].Name != "treasury-cp-1" {
		t.Fatalf("list = %+v", rows)
	}
	return rows
}

func equalForms(a, b url.Values) bool {
	if len(a) != len(b) {
		return false
	}
	for k := range a {
		if !slices.Equal(a[k], b[k]) {
			return false
		}
	}
	return true
}

// A shrink is refused by a dry run too, before anything is printed as sent.
func TestResizeDryRunRefusesShrink(t *testing.T) {
	f := newFake()
	r, out := newRunner(t, f, treasury())
	ctx := context.Background()
	if err := r.Create(ctx); err != nil {
		t.Fatalf("Create: %v\n%s", err, out)
	}
	f.calls = nil
	r.Config = Default() // a resize that forgot -config
	r.Config.Cluster = "treasury"
	r.Config.ControlPlane.MemoryMiB = 4096
	r.DryRun = true
	if err := r.Resize(ctx, ResizeOptions{}); err == nil || !strings.Contains(err.Error(), "treasury-cp-1 vmid 104 from 2 cores and 6144 MiB to 2 cores and 4096 MiB") {
		t.Errorf("dry-run shrink err = %v", err)
	}
	if len(f.calls) != 0 {
		t.Errorf("sent %v", f.calls)
	}
}

// One VM whose pending size cannot be read does not fail list: the table
// shows ?, the JSON leaves the pending fields out, and a warning goes to Err.
func TestListToleratesUnreadableSize(t *testing.T) {
	f := newFake()
	r, out := newRunner(t, f, treasury())
	ctx := context.Background()
	if err := r.Create(ctx); err != nil {
		t.Fatalf("Create: %v\n%s", err, out)
	}
	delete(f.configs[106], "memory")
	var warn bytes.Buffer
	r.Err = &warn
	rows := listRows(t, r)
	if rows[2].Name != "treasury-general-2" || rows[2].PendingMemoryMiB != 0 || !strings.Contains(warn.String(), "treasury-general-2") {
		t.Errorf("row %+v, warning %q", rows[2], warn.String())
	}
	out.Reset()
	if err := r.List(ctx, false); err != nil {
		t.Fatal(err)
	}
	t.Log(out)
	for _, line := range strings.Split(out.String(), "\n") {
		if strings.HasPrefix(line, "treasury-general-2 ") && !strings.HasSuffix(strings.TrimSpace(line), "?") ||
			strings.HasPrefix(line, "treasury-general-1 ") && !strings.HasSuffix(strings.TrimSpace(line), "-") {
			t.Errorf("table line %q", line)
		}
	}
}

func TestResizeChecksPrivileges(t *testing.T) {
	f := newFake()
	f.privs = slices.DeleteFunc(f.privs, func(p string) bool { return p == "VM.Config.Memory" })
	r, _ := newRunner(t, f, treasury())
	if err := r.Resize(context.Background(), ResizeOptions{}); err == nil || !strings.Contains(err.Error(), "VM.Config.Memory") {
		t.Errorf("Resize err = %v, want VM.Config.Memory missing", err)
	}
	if len(f.calls) != 0 {
		t.Errorf("sent %v", f.calls)
	}
}

// printedCalls is the calls as a dry run prints them, with their form fields.
func printedCalls(calls []Call) []string {
	var out []string
	for _, c := range calls {
		out = append(out, c.String())
	}
	return out
}
