package talos

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"

	"go.holos.run/distro/providers/infra"
)

func newRunner(t *testing.T, c infra.Compute, cfg Config) (*Runner, *bytes.Buffer) {
	t.Helper()
	factory := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusCreated)
		io.WriteString(w, `{"id":"0123456789abcdef0123"}`)
	}))
	t.Cleanup(factory.Close)
	out := &bytes.Buffer{}
	return &Runner{Compute: c, Factory: Factory{BaseURL: factory.URL, HTTP: factory.Client()}, Config: cfg, Out: out}, out
}

// The Talos layer's create through the contract: it asks compute for the
// config's VMs with the image and labels, renders each VM's network config
// from the NIC compute planned for it, address, MAC, gateway, MTU and
// resolvers, and hands those to Create; a rerun reports the VMs that exist
// and makes none.
func TestCreateContract(t *testing.T) {
	f := newFakeCompute("treasury")
	r, out := newRunner(t, f, treasury())
	ctx := context.Background()
	if err := r.Create(ctx); err != nil {
		t.Fatalf("Create: %v\n%s", err, out)
	}
	host := strings.TrimPrefix(r.Factory.BaseURL, "http://")
	if want := "schematic 0123456789abcdef0123\ninstaller " + host + "/nocloud-installer/0123456789abcdef0123:v1.14.4\n"; out.String() != want {
		t.Errorf("output =\n%s\nwant\n%s", out, want)
	}
	iso := "talos-v1.14.4-0123456789ab-nocloud-amd64.iso"
	want := []string{
		"create treasury-cp-1 with " + iso + " on r620a",
		"create treasury-general-1 with " + iso + " on r620b",
		"create treasury-general-2 with " + iso + " on r620c",
		"create treasury-general-3 with " + iso + " on r620a",
	}
	if !slices.Equal(f.log, want) {
		t.Errorf("log =\n%s\nwant\n%s", strings.Join(f.log, "\n"), strings.Join(want, "\n"))
	}
	for _, s := range f.specs {
		if s.Image.URL != r.Factory.BaseURL+"/image/0123456789abcdef0123/v1.14.4/nocloud-amd64.iso" ||
			s.Description != "Created by talosvm (go.holos.run/distro/providers/talos/cmd/talosvm) for cluster treasury.\nTalos v1.14.4, schematic 0123456789abcdef0123." {
			t.Errorf("spec %s: image %+v, description %q", s.Name, s.Image, s.Description)
		}
	}
	// The config is rendered from what compute planned, which the fake
	// chose differently from Proxmox: its MAC, MTU and resolvers.
	cfg := f.configs["treasury-general-2"]
	for _, w := range []string{`macaddress: "02:00:00:00:01:02"`, "- 10.20.0.52/32", "mtu: 9000", "via: 10.20.0.1", "addresses: [10.20.0.2, 10.20.0.3]", "search: [example]"} {
		if !strings.Contains(cfg, w) {
			t.Errorf("config lacks %q:\n%s", w, cfg)
		}
	}
	if len(f.configs) != 4 {
		t.Errorf("configs for %d VMs", len(f.configs))
	}

	// A rerun names the VMs that exist, by compute's ID and zone, and
	// changes nothing but starting a stopped one.
	f.log = nil
	out.Reset()
	f.find("treasury-general-1").Status = "stopped"
	if err := r.Create(ctx); err != nil {
		t.Fatal(err)
	}
	for _, w := range []string{
		"exists   treasury-cp-1            id 104 on r620a\n",
		"exists   treasury-general-3       id 107 on r620a\n",
	} {
		if !strings.Contains(out.String(), w) {
			t.Errorf("rerun output lacks %q:\n%s", w, out)
		}
	}
	if !slices.Equal(f.log, []string{"start treasury-general-1"}) {
		t.Errorf("rerun changed %v", f.log)
	}

	// A config compute's address rule refuses is refused before compute
	// is asked for anything; so is a missing privilege.
	f.log, f.specs = nil, nil
	bad := treasury()
	bad.FirstAddress = "10.20.0.40"
	r.Config = bad
	if err := r.Create(ctx); err == nil || !strings.Contains(err.Error(), "controlPlane VM 1: address 10.20.0.40 is reserved") {
		t.Errorf("Create with a reserved address = %v", err)
	}
	if f.specs != nil || f.log != nil {
		t.Errorf("compute was asked for %v, changed %v", f.specs, f.log)
	}
	r.Config = treasury()
	f.checkErr = errors.New("the token lacks VM.Allocate")
	if err := r.Create(ctx); err == nil || !strings.Contains(err.Error(), "VM.Allocate") {
		t.Errorf("Create without the privilege = %v", err)
	}
}

// create says how an existing VM reaches the config's size: resize, when
// nothing or something else is pending; a power cycle, when the config's
// size is pending; nothing, once it runs with it.
func TestCreateSizeHint(t *testing.T) {
	f := newFakeCompute("treasury")
	old := treasury()
	old.Pools[0].MemoryMiB = 8192
	r, out := newRunner(t, f, old)
	ctx := context.Background()
	if err := r.Create(ctx); err != nil {
		t.Fatalf("Create: %v\n%s", err, out)
	}
	r.Config = treasury()
	create := func() string {
		t.Helper()
		f.log = nil
		out.Reset()
		if err := r.Create(ctx); err != nil {
			t.Fatalf("Create: %v\n%s", err, out)
		}
		// Starting a stopped VM is all a create of existing VMs does.
		if slices.ContainsFunc(f.log, func(l string) bool { return !strings.HasPrefix(l, "start ") }) {
			t.Errorf("create changed %v", f.log)
		}
		return out.String()
	}
	resizeHint := "runs with 4 cores and 8192 MiB, the config asks for 4 and 16384: talosvm resize -cluster treasury sets it"
	cycleHint := func(vm string) string {
		return "runs with 4 cores and 8192 MiB; the config's 4 and 16384 are pending until a power cycle: talosvm restart -cluster treasury -mode power-cycle -nodes " + vm + "\n"
	}

	// Running at the old size with nothing pending: resize, for each
	// worker and not the control plane, which is at size.
	if got := create(); strings.Count(got, resizeHint) != 3 || strings.Count(got, "runs with") != 3 || strings.Contains(got, "power-cycle") {
		t.Errorf("before resize:\n%s", got)
	}

	// general-1 has another size pending, general-2's cannot be read,
	// which create shrugs off, and general-3 has the config's pending.
	var warnings bytes.Buffer
	r.Err = &warnings
	f.find("treasury-general-1").Sizing.Next.MemoryMiB = 12288
	f.find("treasury-general-2").SizingErr = errors.New("VM treasury-general-2 id 106: its config has no memory")
	f.find("treasury-general-3").Sizing.Next.MemoryMiB = 16384
	got := create()
	if strings.Count(got, resizeHint) != 2 || !strings.Contains(got, cycleHint("treasury-general-3")) || strings.Contains(got, "-nodes treasury-general-1") {
		t.Errorf("after resize:\n%s", got)
	}
	if !strings.Contains(warnings.String(), "talosvm: warning: reading the pending size of treasury-general-2: VM treasury-general-2 id 106") {
		t.Errorf("warnings = %q", warnings.String())
	}
	r.Err = nil
	f.find("treasury-general-1").Sizing.Next.MemoryMiB = 16384
	f.find("treasury-general-2").SizingErr = nil
	f.find("treasury-general-2").Sizing.Next.MemoryMiB = 16384
	if got := create(); strings.Contains(got, resizeHint) || !strings.Contains(got, cycleHint("treasury-general-1")) || !strings.Contains(got, cycleHint("treasury-general-2")) {
		t.Errorf("with the config's size pending:\n%s", got)
	}

	// A stopped VM takes its pending size when create starts it.
	f.find("treasury-general-3").Status = "stopped"
	got = create()
	if !strings.Contains(got, "has 4 cores and 8192 MiB; the config's 4 and 16384 are pending until it starts") || strings.Contains(got, cycleHint("treasury-general-3")) {
		t.Errorf("with a stopped VM:\n%s", got)
	}
	f.find("treasury-general-3").Status = "running"

	// After a power cycle the VMs run at the config's size: no hint.
	for _, name := range treasuryWorkers {
		if err := f.PowerCycle(ctx, "treasury", *f.find(name), 0); err != nil {
			t.Fatal(err)
		}
	}
	if got := create(); strings.Contains(got, "runs with") {
		t.Errorf("after the power cycle:\n%s", got)
	}
	// The size compute's inventory reports lags a power cycle by a few
	// seconds; the VM's config, with nothing pending, decides.
	f.find("treasury-general-1").Size.MemoryMiB = 8192
	if got := create(); strings.Contains(got, "runs with") {
		t.Errorf("with the inventory behind:\n%s", got)
	}
}
