package talosvm

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"slices"
	"strings"
	"testing"

	"go.holos.run/distro/providers/proxmox/internal/pve"
)

var garageNodes = []string{"r620a", "r620b", "r620c"}

func mustSpecs(t *testing.T, c Config, nodes []string) []Spec {
	t.Helper()
	specs, err := Specs(c, nodes)
	if err != nil {
		t.Fatal(err)
	}
	return specs
}

func TestSpecsPlacement(t *testing.T) {
	c := treasury()
	c.Pools = append(c.Pools, Pool{Name: "microvm", Count: 2, Size: c.Pools[0].Size, Nodes: []string{"r620c"}})
	var got []string
	for _, s := range mustSpecs(t, c, garageNodes) {
		got = append(got, s.Name+"@"+s.Node+"="+s.Address.String())
	}
	// One control plane, then the three general workers one per host.
	want := []string{
		"treasury-cp-1@r620a=10.20.0.50",
		"treasury-general-1@r620b=10.20.0.51", "treasury-general-2@r620c=10.20.0.52", "treasury-general-3@r620a=10.20.0.53",
		"treasury-microvm-1@r620c=10.20.0.54", "treasury-microvm-2@r620c=10.20.0.55",
	}
	if !slices.Equal(got, want) {
		t.Errorf("Specs =\n%v\nwant\n%v", got, want)
	}
}

func TestCreateParams(t *testing.T) {
	c := treasury()
	s := mustSpecs(t, c, garageNodes)[1]
	img := Image{FactoryURL: FactoryURL, SchematicID: "abcdef0123456789", TalosVersion: "v1.14.4"}
	p := CreateParams(c, s, 105, img, "d")
	want := map[string]string{
		"vmid":        "105",
		"name":        "treasury-general-1",
		"tags":        "talosvm;talosvm-cluster-treasury;talosvm-role-worker;talosvm-pool-general",
		"ostype":      "l26",
		"machine":     "q35",
		"bios":        "ovmf",
		"efidisk0":    "local-zfs:1,efitype=4m,pre-enrolled-keys=0",
		"cpu":         "host",
		"sockets":     "1",
		"cores":       "4",
		"memory":      "8192",
		"balloon":     "0",
		"scsihw":      "virtio-scsi-pci",
		"scsi0":       "local-zfs:64,discard=on,ssd=1",
		"ide0":        "garage:iso/talos-v1.14.4-abcdef012345-nocloud-amd64.iso,media=cdrom",
		"ide2":        "local-zfs:cloudinit",
		"citype":      "nocloud",
		"cicustom":    "network=garage:snippets/talosvm_treasury_treasury-general-1-net.yaml",
		"net0":        "virtio=" + MACFor("treasury", "treasury-general-1", 0) + ",bridge=k8s,mtu=1",
		"serial0":     "socket",
		"boot":        "order=scsi0;ide0",
		"agent":       "enabled=1",
		"onboot":      "1",
		"description": "d",
	}
	for k, v := range want {
		if got := p.Get(k); got != v {
			t.Errorf("%s = %q, want %q", k, got, v)
		}
	}
	// Nothing is sent that the test does not pin down, so a new parameter
	// is a deliberate change here and in privileges.txt.
	for k := range p {
		if _, ok := want[k]; !ok {
			t.Errorf("unexpected parameter %s=%q", k, p.Get(k))
		}
	}
}

func TestSchematicAndImage(t *testing.T) {
	want := "customization:\n  systemExtensions:\n    officialExtensions:\n" +
		"      - siderolabs/gvisor\n      - siderolabs/kata-containers\n      - siderolabs/qemu-guest-agent\n"
	if Schematic() != want {
		t.Errorf("Schematic =\n%s", Schematic())
	}
	img := Image{FactoryURL: FactoryURL, SchematicID: "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba", TalosVersion: "v1.14.4"}
	if got := img.ISOURL(); got != "https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/v1.14.4/nocloud-amd64.iso" {
		t.Errorf("ISOURL = %s", got)
	}
	if got := img.Installer(); got != "factory.talos.dev/nocloud-installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.14.4" {
		t.Errorf("Installer = %s", got)
	}
	if got := img.VolID("garage"); got != "garage:iso/talos-v1.14.4-376567988ad3-nocloud-amd64.iso" {
		t.Errorf("VolID = %s", got)
	}
}

func TestFactorySchematicID(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if r.Method != http.MethodPost || r.URL.Path != "/schematics" || string(body) != Schematic() {
			t.Errorf("got %s %s %q", r.Method, r.URL.Path, body)
		}
		if ct := r.Header.Get("Content-Type"); ct != "application/yaml" {
			t.Errorf("Content-Type = %q", ct)
		}
		w.WriteHeader(http.StatusCreated)
		io.WriteString(w, `{"id":"feedface","schematic":"x"}`)
	}))
	defer srv.Close()
	id, err := Factory{BaseURL: srv.URL, HTTP: srv.Client()}.SchematicID(context.Background())
	if err != nil || id != "feedface" {
		t.Fatalf("SchematicID = %q, %v", id, err)
	}
}

func res(vmid int, name, node, tags string) pve.Resource {
	return pve.Resource{VMID: vmid, Name: name, Node: node, Type: "qemu", Status: "running", Tags: tags}
}

// tenants is the garage's other guests as of the inventory. None of them may
// ever be selected.
func tenants() []pve.Resource {
	rs := []pve.Resource{
		res(100, "tenant-admin-vm", "r620a", ""),
		res(101, "runner", "r620a", ""),
		res(102, "claude", "r620b", ""),
		res(103, "jeffsbox", "r620c", ""),
		res(200, "tenant-k8s1-api1", "r620b", "k8s"),
	}
	for _, id := range []int{9101, 9102, 9201, 9202, 9301, 9302} {
		r := res(id, "talos-template", "r620a", "talos")
		r.Template = 1
		r.Status = "stopped"
		rs = append(rs, r)
	}
	return rs
}

func TestOwned(t *testing.T) {
	for _, tc := range []struct {
		r    pve.Resource
		want bool
	}{
		{res(1, "a", "n", "talosvm;talosvm-cluster-treasury;talosvm-role-worker"), true},
		{res(1, "a", "n", "talosvm-cluster-treasury,talosvm"), true},
		{res(1, "a", "n", "talosvm;talosvm-cluster-lab"), false},
		{res(1, "a", "n", "talosvm-cluster-treasury"), false},
		{res(1, "a", "n", "talosvm;cluster-treasury"), false},
		{res(1, "a", "n", "talosvm"), false},
		{res(1, "treasury-cp-1", "n", ""), false}, // a name alone is never ownership
		{pve.Resource{Type: "lxc", Tags: "talosvm;talosvm-cluster-treasury"}, false},
		{pve.Resource{Type: "qemu", Template: 1, Tags: "talosvm;talosvm-cluster-treasury"}, false},
	} {
		if got := Owned(tc.r, "treasury"); got != tc.want {
			t.Errorf("Owned(%+v) = %v, want %v", tc.r, got, tc.want)
		}
	}
	if Owned(res(1, "a", "n", "talosvm;talosvm-cluster-"), "") {
		t.Error("Owned matched an empty cluster name")
	}
}

// ownedFile is a fake readOwnedSnippet over a map of files: a file whose
// first line is not the header is refused, as the real one does.
func ownedFile(files map[string]string, asked *[]string) func(string, string) (string, bool, error) {
	return func(path, header string) (string, bool, error) {
		if asked != nil {
			*asked = append(*asked, path)
		}
		text, ok := files[path]
		if !ok {
			return "", false, nil
		}
		if first, _, _ := strings.Cut(text, "\n"); first != header {
			return "", false, fmt.Errorf("refusing to touch %s", path)
		}
		return text, true, nil
	}
}

func TestDestroyCallsSelectOnlyTheCluster(t *testing.T) {
	guests := append(tenants(),
		res(104, "treasury-cp-1", "r620a", "talosvm;talosvm-cluster-treasury;talosvm-role-controlplane"),
		res(105, "treasury-general-1", "r620b", "talosvm;talosvm-cluster-treasury;talosvm-role-worker;talosvm-pool-general"),
		res(106, "lab-cp-1", "r620c", "talosvm;talosvm-cluster-lab;talosvm-role-controlplane"),
		res(107, "treasury-general-2", "r620c", "talosvm-cluster-treasury"), // hand-tagged, not ours
	)
	guests[len(guests)-3].Status = "stopped"
	files := map[string]string{
		"/mnt/s/talosvm_treasury_treasury-cp-1-net.yaml": SnippetHeader("treasury", "treasury-cp-1") + "\nversion: 2\n",
		"/mnt/s/talosvm_lab_lab-cp-1-net.yaml":           SnippetHeader("lab", "lab-cp-1") + "\n",
	}
	var asked []string
	calls, err := DestroyCalls(guests, "treasury", "/mnt/s", ownedFile(files, &asked))
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, c := range calls {
		got = append(got, c.String())
	}
	want := []string{
		"POST /api2/json/nodes/r620a/qemu/104/status/stop",
		"DELETE /api2/json/nodes/r620a/qemu/104?purge=1",
		"REMOVE /mnt/s/talosvm_treasury_treasury-cp-1-net.yaml",
		"DELETE /api2/json/nodes/r620b/qemu/105?purge=1",
	}
	if !slices.Equal(asked, []string{"/mnt/s/talosvm_treasury_treasury-cp-1-net.yaml", "/mnt/s/talosvm_treasury_treasury-general-1-net.yaml"}) {
		t.Errorf("DestroyCalls looked at %v", asked)
	}
	if !slices.Equal(got, want) {
		t.Errorf("DestroyCalls =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	if calls, _ := DestroyCalls(tenants(), "treasury", "/mnt/s", ownedFile(files, nil)); len(calls) != 0 {
		t.Errorf("DestroyCalls selected tenants: %v", calls)
	}
	// A file at our name that talosvm did not write for this VM stops the
	// whole destroy before anything is deleted.
	files["/mnt/s/talosvm_treasury_treasury-general-1-net.yaml"] = "# someone else's\n"
	if _, err := DestroyCalls(guests, "treasury", "/mnt/s", ownedFile(files, nil)); err == nil || !strings.Contains(err.Error(), "refusing") {
		t.Errorf("DestroyCalls = %v, want a refusal", err)
	}
}

// Labels cannot hold the separator, so no two (cluster, VM) pairs share a
// snippet name; with hyphens these two did.
func TestSnippetNameIsUnambiguous(t *testing.T) {
	if a, b := SnippetName("a", "a-a-cp-1"), SnippetName("a-a", "a-a-cp-1"); a == b {
		t.Errorf("SnippetName collides: %s", a)
	}
	if label.MatchString("a_b") {
		t.Error("labels allow an underscore, SnippetName's separator")
	}
}

func TestReconcile(t *testing.T) {
	specs := mustSpecs(t, treasury(), garageNodes)
	existing := append(tenants(), res(104, "treasury-cp-1", "r620b", "talosvm;talosvm-cluster-treasury;talosvm-role-controlplane"))
	create, skip, err := Reconcile(specs, existing, "treasury")
	if err != nil {
		t.Fatal(err)
	}
	if len(skip) != 1 || skip[0].Spec.Name != "treasury-cp-1" || len(create) != 3 {
		t.Errorf("create %d skip %d, want 3 and 1", len(create), len(skip))
	}
	conflict := append(existing, res(300, "treasury-general-2", "r620a", "hand-made"))
	if _, _, err := Reconcile(specs, conflict, "treasury"); err == nil || !strings.Contains(err.Error(), "treasury-general-2") {
		t.Errorf("Reconcile err = %v, want a conflict on treasury-general-2", err)
	}
	dup := append(existing, res(108, "treasury-cp-1", "r620a", "talosvm;talosvm-cluster-treasury"))
	if _, _, err := Reconcile(specs, dup, "treasury"); err == nil {
		t.Error("Reconcile accepted two VMs with the same name")
	}
}

func treasuryPlan(t *testing.T) VMPlan {
	t.Helper()
	specs := mustSpecs(t, treasury(), garageNodes)
	var create []Action
	for _, s := range specs {
		create = append(create, Action{Spec: s})
	}
	return VMPlan{
		Config: treasury(), Create: create, Guests: tenants(), Nets: map[int]GuestNet{},
		Dir: "/mnt/s", VMIDs: []int{104, 105, 106, 107},
		Image: Image{FactoryURL: FactoryURL, SchematicID: "abc", TalosVersion: "v1.14.4"},
		Read:  ownedFile(map[string]string{}, nil),
	}
}

func callStrings(calls []Call) []string {
	var out []string
	for _, c := range calls {
		out = append(out, c.Method+" "+c.Path)
	}
	return out
}

func TestPlanCreatesThenStarts(t *testing.T) {
	calls, err := treasuryPlan(t).Calls()
	if err != nil {
		t.Fatal(err)
	}
	got := callStrings(calls)
	want := []string{
		"WRITE /mnt/s/talosvm_treasury_treasury-cp-1-net.yaml", "POST /nodes/r620a/qemu", "POST /nodes/r620a/qemu/104/status/start",
		"WRITE /mnt/s/talosvm_treasury_treasury-general-1-net.yaml", "POST /nodes/r620b/qemu", "POST /nodes/r620b/qemu/105/status/start",
		"WRITE /mnt/s/talosvm_treasury_treasury-general-2-net.yaml", "POST /nodes/r620c/qemu", "POST /nodes/r620c/qemu/106/status/start",
		"WRITE /mnt/s/talosvm_treasury_treasury-general-3-net.yaml", "POST /nodes/r620a/qemu", "POST /nodes/r620a/qemu/107/status/start",
	}
	if !slices.Equal(got, want) {
		t.Errorf("calls =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	if calls[1].Params.Has("start") {
		t.Error("create asks Proxmox to start the VM, which hides a failed start")
	}
}

func TestPlanCollisions(t *testing.T) {
	p := treasuryPlan(t)
	p.Nets = map[int]GuestNet{
		100: {Addresses: []netip.Addr{netip.MustParseAddr("10.20.0.4")}},
		103: {Addresses: []netip.Addr{netip.MustParseAddr("10.20.0.52")}},
	}
	_, err := p.Calls()
	if err == nil || !strings.Contains(err.Error(), "treasury-general-2: address 10.20.0.52 is already used by vmid 103 jeffsbox") {
		t.Errorf("Calls = %v", err)
	}
}

// A taken MAC moves on to the next candidate, and so does one an earlier
// VM of the same run just took.
func TestPlanRehashesMACs(t *testing.T) {
	p := treasuryPlan(t)
	p.Nets = map[int]GuestNet{102: {MACs: []string{MACFor("treasury", "treasury-general-3", 0)}}}
	// Make treasury-general-1's first candidate the same as treasury-cp-1's, as
	// a 24-bit hash can.
	p.Create[1].Spec.Name = "treasury-cp-1"
	calls, err := p.Calls()
	if err != nil {
		t.Fatal(err)
	}
	var macs []string
	for _, c := range calls {
		if c.Method == http.MethodPost && strings.HasSuffix(c.Path, "/qemu") {
			mac, _, _ := strings.Cut(strings.TrimPrefix(c.Params.Get("net0"), "virtio="), ",")
			macs = append(macs, mac)
		}
	}
	want := []string{
		MACFor("treasury", "treasury-cp-1", 0), MACFor("treasury", "treasury-cp-1", 1),
		MACFor("treasury", "treasury-general-2", 0), MACFor("treasury", "treasury-general-3", 1),
	}
	if !slices.Equal(macs, want) {
		t.Errorf("MACs = %v, want %v", macs, want)
	}
}

func TestPlanExistingVMs(t *testing.T) {
	cp := res(104, "treasury-cp-1", "r620a", "talosvm;talosvm-cluster-treasury;talosvm-role-controlplane")
	cp.Status = "stopped"
	specs := mustSpecs(t, treasury(), garageNodes)
	cpPath := "/mnt/s/talosvm_treasury_treasury-cp-1-net.yaml"
	base := func() VMPlan {
		return VMPlan{
			Config: treasury(), Existing: []Action{{Spec: specs[0], Existing: &cp}},
			Guests: append(tenants(), cp), Dir: "/mnt/s",
			Nets: map[int]GuestNet{104: {Net0MAC: "BC:24:11:AA:BB:CC", MACs: []string{"BC:24:11:AA:BB:CC"}}},
		}
	}

	// Snippet there with the same address: nothing to write; the stopped
	// VM is started.
	p := base()
	p.Read = ownedFile(map[string]string{cpPath: NetworkConfig(treasury(), specs[0], "BC:24:11:AA:BB:CC")}, nil)
	calls, err := p.Calls()
	if err != nil || !slices.Equal(callStrings(calls), []string{"POST /nodes/r620a/qemu/104/status/start"}) {
		t.Errorf("same address: %v, %v", callStrings(calls), err)
	}

	// The config now says another address: refused, never rewritten.
	moved := specs[0]
	moved.Address = netip.MustParseAddr("10.20.0.60")
	p.Read = ownedFile(map[string]string{cpPath: NetworkConfig(treasury(), moved, "BC:24:11:AA:BB:CC")}, nil)
	if _, err := p.Calls(); err == nil || !strings.Contains(err.Error(), "VM treasury-cp-1 has address 10.20.0.60, config says 10.20.0.50") {
		t.Errorf("moved address: %v", err)
	}

	// Snippet missing: written again with the MAC on net0.
	p.Read = ownedFile(map[string]string{}, nil)
	calls, err = p.Calls()
	if err != nil || len(calls) != 2 || calls[0].Method != WriteFile || !strings.Contains(calls[0].Content, `macaddress: "BC:24:11:AA:BB:CC"`) {
		t.Errorf("missing snippet: %v, %v", callStrings(calls), err)
	}

	// Snippet missing and the address taken meanwhile: refused.
	p.Nets[103] = GuestNet{Addresses: []netip.Addr{netip.MustParseAddr("10.20.0.50")}}
	if _, err := p.Calls(); err == nil || !strings.Contains(err.Error(), "its address 10.20.0.50 is now used by vmid 103 jeffsbox") {
		t.Errorf("missing snippet, address taken: %v", err)
	}
}

func TestCheckStorages(t *testing.T) {
	var ss []pve.Storage
	for _, n := range garageNodes {
		ss = append(ss,
			pve.Storage{Node: n, Storage: "local-zfs", Status: "available", Content: "images,rootdir"},
			pve.Storage{Node: n, Storage: "garage", Status: "available", Shared: 1, Content: "iso,snippets,images,import"},
			pve.Storage{Node: n, Storage: "local", Status: "available", Content: "iso,import"},
			pve.Storage{Node: n, Storage: "nosnip", Status: "available", Shared: 1, Content: "iso"},
		)
	}
	shared, err := CheckStorages(treasury(), garageNodes, ss)
	if err != nil || !shared {
		t.Errorf("CheckStorages = %v, %v; want shared, nil", shared, err)
	}
	c := treasury()
	c.ISOStorage = "local"
	if shared, err := CheckStorages(c, garageNodes, ss); err != nil || shared {
		t.Errorf("CheckStorages(local) = %v, %v; want not shared", shared, err)
	}
	c.DiskStorage = "ssd"
	if _, err := CheckStorages(c, garageNodes, ss); err == nil || !strings.Contains(err.Error(), "storage ssd is not on node r620a") {
		t.Errorf("CheckStorages(ssd) = %v", err)
	}
	c = treasury()
	c.SnippetStorage = "nosnip"
	if _, err := CheckStorages(c, garageNodes, ss); err == nil || !strings.Contains(err.Error(), "does not allow snippets") {
		t.Errorf("CheckStorages(nosnip) = %v", err)
	}
	c = treasury()
	c.DiskStorage = "local"
	if _, err := CheckStorages(c, garageNodes, ss); err == nil || !strings.Contains(err.Error(), "does not allow images") {
		t.Errorf("CheckStorages(local disks) = %v", err)
	}
}

func TestAllocateVMIDs(t *testing.T) {
	guests := []pve.Resource{res(105, "x", "n", ""), res(106, "y", "n", "")}
	if got := AllocateVMIDs(104, 3, guests); !slices.Equal(got, []int{104, 107, 108}) {
		t.Errorf("AllocateVMIDs = %v", got)
	}
}
