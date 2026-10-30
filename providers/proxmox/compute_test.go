package proxmox

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"go.holos.run/distro/providers/infra"
	"go.holos.run/distro/providers/proxmox/internal/pve"
	"go.holos.run/distro/providers/proxmox/preflight"
)

// fakePVE is just enough of the Proxmox API for every call Compute makes:
// plan, create, list, resize, power cycle, destroy and check. Tasks finish
// at once. It records every call that is not a GET.
type fakePVE struct {
	mu      sync.Mutex
	vms     []pve.Resource
	configs map[int]map[string]string
	// pending holds the config changes a PUT made to a running VM, which a
	// start applies, as Proxmox does without hotplug.
	pending map[int]map[string]string
	isos    []string // volids in the shared garage storage
	privs   []string
	calls   []string
	forms   []url.Values
	// hook, when set, sees every call that is not a GET, as "METHOD path",
	// before it is answered.
	hook func(call string)
	// failCall, when set, fails every call that is not a GET whose path
	// ends with it.
	failCall string
}

func newFake() *fakePVE {
	f := &fakePVE{vms: tenants(), configs: map[int]map[string]string{}, pending: map[int]map[string]string{}, privs: preflight.Names(preflight.Required())}
	f.configs[100] = map[string]string{"ipconfig0": "ip=10.20.0.4/32,gw=10.20.0.1"}
	f.configs[101] = map[string]string{"ipconfig0": "ip=10.20.0.5/32,gw=10.20.0.1"}
	f.configs[200] = map[string]string{"cicustom": "network=garage:snippets/" + tenantSnippet, "net0": "virtio=BC:24:11:D1:BA:A5,bridge=k8s"}
	return f
}

// tenantSnippet is a snippet another tenant's VM boots with. Nothing may
// change or remove it.
const tenantSnippet = "tenant-k8s1-api1-net.yaml"

const tenantSnippetText = `version: 2
ethernets:
  net0:
    match:
      macaddress: "BC:24:11:D1:BA:A5"
    addresses:
      - 10.20.0.30/32
    routes:
      - to: 0.0.0.0/0
        via: 10.20.0.1
        on-link: true
`

// snippetsDir is a stand-in for the mounted garage export, holding the
// tenant's snippet.
func snippetsDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, tenantSnippet), []byte(tenantSnippetText), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func listDir(t *testing.T, dir string) []string {
	t.Helper()
	es, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range es {
		names = append(names, e.Name())
	}
	return names
}

func (f *fakePVE) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	r.ParseForm()
	path := strings.TrimPrefix(r.URL.Path, "/api2/json")
	parts := strings.Split(strings.Trim(path, "/"), "/")
	reply := func(v any) { json.NewEncoder(w).Encode(map[string]any{"data": v}) }
	upid := func(node, kind string) string { return fmt.Sprintf("UPID:%s:1:2:3:%s:x:u:", node, kind) }
	if r.Method != http.MethodGet {
		f.calls = append(f.calls, r.Method+" "+path)
		f.forms = append(f.forms, r.Form)
		if f.hook != nil {
			f.hook(r.Method + " " + path)
		}
		if f.failCall != "" && strings.HasSuffix(path, f.failCall) {
			http.Error(w, "VM is locked (shutdown)", http.StatusInternalServerError)
			return
		}
	}
	switch {
	case path == "/access/permissions":
		m := map[string]int{}
		for _, p := range f.privs {
			m[p] = 1
		}
		reply(map[string]any{r.Form.Get("path"): m})
	case path == "/nodes":
		reply([]pve.Node{{Node: "r620b", Status: "online"}, {Node: "r620a", Status: "online"}, {Node: "r620c", Status: "online"}, {Node: "old", Status: "offline"}})
	case path == "/cluster/status":
		reply([]map[string]any{{"type": "cluster", "name": "garage"}, {"type": "node", "name": "r620a"}})
	case path == "/cluster/resources" && r.Form.Get("type") == "vm":
		reply(f.vms)
	case path == "/cluster/resources" && r.Form.Get("type") == "storage":
		var ss []pve.Storage
		for _, n := range garageNodes {
			ss = append(ss,
				pve.Storage{Node: n, Storage: "local-zfs", Status: "available", Content: "images,rootdir"},
				pve.Storage{Node: n, Storage: "garage", Status: "available", Shared: 1, Content: "iso,snippets,images,import"})
		}
		reply(ss)
	case path == "/cluster/nextid":
		reply("104")
	case len(parts) == 5 && parts[2] == "tasks":
		reply(pve.TaskStatus{Status: "stopped", ExitStatus: "OK"})
	case len(parts) == 5 && parts[4] == "content":
		var cs []pve.StorageContent
		for _, v := range f.isos {
			cs = append(cs, pve.StorageContent{VolID: v})
		}
		reply(cs)
	case len(parts) == 5 && parts[4] == "download-url":
		f.isos = append(f.isos, parts[3]+":iso/"+r.Form.Get("filename"))
		reply(upid(parts[1], "download"))
	case len(parts) == 5 && parts[4] == "config" && r.Method == http.MethodPut:
		id, _ := strconv.Atoi(parts[3])
		running := slices.ContainsFunc(f.vms, func(v pve.Resource) bool { return v.VMID == id && v.Status == "running" })
		for k := range r.PostForm {
			if running {
				if f.pending[id] == nil {
					f.pending[id] = map[string]string{}
				}
				f.pending[id][k] = r.PostForm.Get(k)
			} else {
				f.configs[id][k] = r.PostForm.Get(k)
			}
		}
		if !running {
			f.applySize(id)
		}
		reply(nil)
	case len(parts) == 5 && parts[4] == "config":
		id, _ := strconv.Atoi(parts[3])
		reply(f.configs[id])
	case len(parts) == 5 && parts[4] == "pending":
		id, _ := strconv.Atoi(parts[3])
		var items []map[string]any
		for k, v := range f.configs[id] {
			item := map[string]any{"key": k, "value": v}
			if p, ok := f.pending[id][k]; ok && p != v {
				item["pending"] = p
			}
			items = append(items, item)
		}
		reply(items)
	case len(parts) == 3 && parts[2] == "qemu" && r.Method == http.MethodPost:
		id, _ := strconv.Atoi(r.Form.Get("vmid"))
		// Proxmox keeps a VM's tags sorted, whatever order they came in.
		tags := strings.Split(r.Form.Get("tags"), ";")
		slices.Sort(tags)
		f.vms = append(f.vms, pve.Resource{VMID: id, Name: r.Form.Get("name"), Node: parts[1], Type: "qemu", Status: "stopped", Tags: strings.Join(tags, ";")})
		f.configs[id] = map[string]string{"cicustom": r.Form.Get("cicustom"), "net0": r.Form.Get("net0"),
			"cores": r.Form.Get("cores"), "memory": r.Form.Get("memory"), "balloon": r.Form.Get("balloon")}
		f.applySize(id)
		reply(upid(parts[1], "qmcreate"))
	case len(parts) == 6 && parts[5] == "start":
		id, _ := strconv.Atoi(parts[3])
		for k, v := range f.pending[id] {
			f.configs[id][k] = v
		}
		delete(f.pending, id)
		f.applySize(id)
		f.setStatus(parts[3], "running")
		reply(upid(parts[1], "qmstart"))
	case len(parts) == 6 && parts[5] == "shutdown":
		f.setStatus(parts[3], "stopped")
		reply(upid(parts[1], "qmshutdown"))
	case len(parts) == 6 && parts[5] == "stop":
		f.setStatus(parts[3], "stopped")
		reply(upid(parts[1], "qmstop"))
	case len(parts) == 4 && r.Method == http.MethodDelete:
		f.vms = slices.DeleteFunc(f.vms, func(v pve.Resource) bool { return strconv.Itoa(v.VMID) == parts[3] })
		reply(upid(parts[1], "qmdestroy"))
	default:
		http.Error(w, "not faked: "+r.Method+" "+path, http.StatusNotImplemented)
	}
}

// applySize sets the VM's maxcpu and maxmem in the resource list from its
// config, as Proxmox reports the size the VM runs with there.
func (f *fakePVE) applySize(id int) {
	cores, _ := strconv.Atoi(f.configs[id]["cores"])
	mem, _ := strconv.Atoi(f.configs[id]["memory"])
	for i := range f.vms {
		if f.vms[i].VMID == id {
			f.vms[i].MaxCPU, f.vms[i].MaxMem = float64(cores), int64(mem)<<20
		}
	}
}

func (f *fakePVE) setStatus(vmid, status string) {
	for i := range f.vms {
		if strconv.Itoa(f.vms[i].VMID) == vmid {
			f.vms[i].Status = status
		}
	}
}

func newCompute(t *testing.T, f *fakePVE) (*Compute, *bytes.Buffer) {
	t.Helper()
	srv := httptest.NewServer(f)
	t.Cleanup(srv.Close)
	c, err := New(srv.URL, "holos@pve!distro", "s", srv.Client())
	if err != nil {
		t.Fatal(err)
	}
	c.pve.PollInterval = time.Millisecond
	out := &bytes.Buffer{}
	c.Out, c.SnippetsDir = out, snippetsDir(t)
	return c, out
}

// testImage is the ISO the specs boot.
var testImage = infra.Image{
	Name: "talos-v1.14.4-0123456789ab-nocloud-amd64.iso",
	URL:  "https://factory.example/image/0123456789abcdef0123/v1.14.4/nocloud-amd64.iso",
}

// treasury is the specs the Kubernetes layer asks for by default: one
// control plane and three general workers, from 10.20.0.50, each with
// workerMiB of memory.
func treasury() []infra.VMSpec { return treasurySpecs(3, 16384) }

func treasurySpecs(workers, workerMiB int) []infra.VMSpec {
	spec := func(name string, labels []infra.Label, size infra.Size, disk, addr int) infra.VMSpec {
		return infra.VMSpec{
			Name: name, Labels: labels, Description: "made by a test", Image: testImage, Size: size,
			Disks: []infra.Disk{{SizeGiB: disk}}, Network: "k8s", Address: netip.AddrFrom4([4]byte{10, 20, 0, byte(addr)}),
		}
	}
	specs := []infra.VMSpec{spec("treasury-cp-1", []infra.Label{{Key: "role", Value: "controlplane"}}, infra.Size{Cores: 2, MemoryMiB: 8192}, 32, 50)}
	for i := range workers {
		specs = append(specs, spec(fmt.Sprintf("treasury-general-%d", i+1),
			[]infra.Label{{Key: "role", Value: "worker"}, {Key: "pool", Value: "general"}}, infra.Size{Cores: 4, MemoryMiB: workerMiB}, 64, 51+i))
	}
	return specs
}

// render stands in for the Kubernetes layer's config: a network-config
// that names the VM's MAC and address, which is all the provider ever looks
// for in it.
func render(nic infra.NIC) string {
	return fmt.Sprintf("version: 2\nethernets:\n  net0:\n    match:\n      macaddress: %q\n    addresses:\n      - %s\n", nic.MAC, nic.Address)
}

// create does with the contract what the Kubernetes layer's create does:
// plan, render each VM's config from the NIC the plan gives it, create.
func create(ctx context.Context, c infra.Compute, specs []infra.VMSpec) error {
	plan, err := c.Plan(ctx, "treasury", specs)
	if err != nil {
		return err
	}
	configs := map[string]string{}
	for _, vm := range plan.VMs() {
		configs[vm.Name] = render(vm.NIC)
	}
	return c.Create(ctx, plan, configs)
}

func TestCreateDryRunPrintsExactCalls(t *testing.T) {
	f := newFake()
	c, out := newCompute(t, f)
	c.DryRun = true
	if err := create(context.Background(), c, treasury()); err != nil {
		t.Fatalf("Create: %v\n%s", err, out)
	}
	t.Log(out) // go test -v shows what a first real run prints
	if len(f.calls) != 0 {
		t.Errorf("dry run sent calls: %v", f.calls)
	}
	if got := listDir(t, c.SnippetsDir); !slices.Equal(got, []string{tenantSnippet}) {
		t.Errorf("dry run wrote files: %v", got)
	}
	for _, want := range []string{
		"WRITE " + filepath.Join(c.SnippetsDir, "talosvm_treasury_treasury-cp-1-net.yaml") + " (mode 0644)\n",
		"    | # Written by talosvm for cluster treasury, VM treasury-cp-1.\n",
		"    | version: 2\n",
		"POST /api2/json/nodes/r620a/qemu/104/status/start\n",
		"    |       - 10.20.0.50/32\n",
		"    cicustom=network=garage:snippets/talosvm_treasury_treasury-cp-1-net.yaml\n",
		"    net0=virtio=" + MACFor("treasury", "treasury-cp-1", 0) + ",bridge=k8s,mtu=1\n",
		"POST /api2/json/nodes/r620a/storage/garage/download-url",
		"    url=" + testImage.URL,
		"    ide0=garage:iso/" + testImage.Name + ",media=cdrom\n",
		"POST /api2/json/nodes/r620a/qemu\n",
		"    name=treasury-cp-1\n",
		"    tags=talosvm;talosvm-cluster-treasury;talosvm-role-controlplane\n",
		"    vmid=104\n",
		"    name=treasury-general-3\n",
		"    tags=talosvm;talosvm-cluster-treasury;talosvm-role-worker;talosvm-pool-general\n",
		"    vmid=107\n",
		"dry run: sent none of these 13 calls",
	} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("dry run output lacks %q:\n%s", want, out)
		}
	}
}

// The contract, end to end against the fake Proxmox: Plan gives each new VM
// its address, MAC and placement before anything changes; Create makes them
// with the configs rendered from that; List reports them as Plan said they
// would be; a rerun neither renumbers nor recreates; Resize sets a size a
// running VM takes at its power cycle; Destroy removes only the group's VMs.
func TestComputeContract(t *testing.T) {
	f := newFake()
	c, out := newCompute(t, f)
	var compute infra.Compute = c
	ctx := context.Background()
	specs := treasurySpecs(3, 8192)

	plan, err := compute.Plan(ctx, "treasury", specs)
	if err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 0 {
		t.Errorf("Plan sent %v", f.calls)
	}
	planned := plan.VMs()
	for i, vm := range planned {
		want := fmt.Sprintf("%s %s/%s %s/32 %s via %s mtu %d dns %v %v",
			specs[i].Name, "garage", []string{"r620a", "r620b", "r620c", "r620a"}[i], specs[i].Address,
			MACFor("treasury", specs[i].Name, 0), Gateway, VnetMTU, []netip.Addr{netip.MustParseAddr("192.168.2.1")}, []string{"lan"})
		got := fmt.Sprintf("%s %s/%s %s %s via %s mtu %d dns %v %v",
			vm.Name, vm.Region, vm.Zone, vm.NIC.Address, vm.NIC.MAC, vm.NIC.Gateway, vm.NIC.MTU, vm.NIC.Nameservers, vm.NIC.SearchDomains)
		if got != want || vm.ID.Value != "" || vm.NIC.Subnet != NodeSubnet {
			t.Errorf("planned %s (ID %q, subnet %s), want %s", got, vm.ID, vm.NIC.Subnet, want)
		}
	}
	configs := map[string]string{}
	for _, vm := range planned {
		configs[vm.Name] = render(vm.NIC)
	}
	if err := compute.Create(ctx, plan, configs); err != nil {
		t.Fatalf("Create: %v\n%s", err, out)
	}
	// The garage storage is shared, so one download serves every node,
	// and it comes before the VMs that need it.
	wantCalls := []string{
		"POST /nodes/r620a/storage/garage/download-url",
		"POST /nodes/r620a/qemu", "POST /nodes/r620a/qemu/104/status/start",
		"POST /nodes/r620b/qemu", "POST /nodes/r620b/qemu/105/status/start",
		"POST /nodes/r620c/qemu", "POST /nodes/r620c/qemu/106/status/start",
		"POST /nodes/r620a/qemu", "POST /nodes/r620a/qemu/107/status/start",
	}
	if !slices.Equal(f.calls, wantCalls) {
		t.Errorf("calls =\n%v\nwant\n%v", f.calls, wantCalls)
	}
	// The config is attached as it was given, after the provider's header.
	b, _ := os.ReadFile(filepath.Join(c.SnippetsDir, "talosvm_treasury_treasury-general-2-net.yaml"))
	if want := SnippetHeader("treasury", "treasury-general-2") + "\n" + configs["treasury-general-2"]; string(b) != want {
		t.Errorf("snippet =\n%s\nwant\n%s", b, want)
	}

	// List reports what Plan said, with the IDs Create gave.
	vms, err := compute.List(ctx, "treasury")
	if err != nil {
		t.Fatal(err)
	}
	if len(vms) != 4 {
		t.Fatalf("List = %+v", vms)
	}
	for i, vm := range vms {
		p := planned[i]
		if vm.Name != p.Name || vm.Zone != p.Zone || vm.Region != p.Region || vm.NIC.Address != p.NIC.Address || vm.NIC.MAC != p.NIC.MAC ||
			vm.NIC.Network != "k8s" || !sameLabels(vm.Labels, specs[i].Labels) || vm.ID != (infra.ID{Kind: "vmid", Value: strconv.Itoa(104 + i)}) ||
			vm.Status != "running" || vm.Size != specs[i].Size || vm.Sizing != (infra.Sizing{Now: specs[i].Size, Next: specs[i].Size}) {
			t.Errorf("listed %+v, planned %+v", vm, p)
		}
	}

	// A rerun plans the same VMs as they are, and creates nothing.
	f.calls = nil
	if err := create(ctx, compute, specs); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 0 {
		t.Errorf("rerun sent %v", f.calls)
	}
	plan, err = compute.Plan(ctx, "treasury", specs)
	if err != nil {
		t.Fatal(err)
	}
	for i, vm := range plan.VMs() {
		if vm.ID != vms[i].ID || vm.NIC.MAC != vms[i].NIC.MAC || vm.NIC.Address != vms[i].NIC.Address || vm.Zone != vms[i].Zone {
			t.Errorf("rerun planned %+v, have %+v", vm, vms[i])
		}
	}

	// Resize sends only what differs, and a running VM keeps its size
	// until a power cycle, after which it runs with the new one.
	var resizes []infra.Resize
	for _, vm := range vms[1:] {
		resizes = append(resizes, infra.Resize{VM: vm, Size: infra.Size{Cores: 4, MemoryMiB: 16384}})
	}
	resizes = append(resizes, infra.Resize{VM: vms[0], Size: vms[0].Size})
	f.calls, f.forms = nil, nil
	if err := compute.Resize(ctx, "treasury", resizes); err != nil {
		t.Fatal(err)
	}
	if want := []string{"PUT /nodes/r620b/qemu/105/config", "PUT /nodes/r620c/qemu/106/config", "PUT /nodes/r620a/qemu/107/config"}; !slices.Equal(f.calls, want) {
		t.Errorf("Resize sent %v, want %v", f.calls, want)
	}
	for i, form := range f.forms {
		if want := (url.Values{"memory": {"16384"}}); !equalForms(form, want) {
			t.Errorf("call %d form = %v, want %v", i, form, want)
		}
	}
	vms, _ = compute.List(ctx, "treasury")
	g := vms[1]
	if g.Size.MemoryMiB != 8192 || g.Sizing.Now.MemoryMiB != 8192 || g.Sizing.Next.MemoryMiB != 16384 || !g.Sizing.Pending() {
		t.Errorf("before the power cycle: %+v", g)
	}
	f.calls = nil
	if err := compute.PowerCycle(ctx, "treasury", g, time.Minute); err != nil {
		t.Fatal(err)
	}
	if want := []string{"POST /nodes/r620b/qemu/105/status/shutdown", "POST /nodes/r620b/qemu/105/status/start"}; !slices.Equal(f.calls, want) {
		t.Errorf("PowerCycle sent %v", f.calls)
	}
	vms, _ = compute.List(ctx, "treasury")
	if g := vms[1]; g.Size.MemoryMiB != 16384 || g.Sizing.Pending() || f.configs[105]["balloon"] != "0" {
		t.Errorf("after the power cycle: %+v, balloon %q", g, f.configs[105]["balloon"])
	}

	// Another cluster's VM survives Destroy, which leaves nothing of the
	// group.
	f.vms = append(f.vms, res(120, "lab-cp-1", "r620b", "talosvm;talosvm-cluster-lab;talosvm-role-controlplane"))
	if err := compute.Destroy(ctx, "treasury"); err != nil {
		t.Fatal(err)
	}
	if vms, err := compute.List(ctx, "treasury"); err != nil || len(vms) != 0 {
		t.Errorf("after Destroy, List = %v, %v", vms, err)
	}
	if vms, err := compute.List(ctx, "lab"); err != nil || len(vms) != 1 {
		t.Errorf("after Destroy, lab = %v, %v", vms, err)
	}
}

func TestCreateListDestroy(t *testing.T) {
	f := newFake()
	c, out := newCompute(t, f)
	ctx := context.Background()
	if err := create(ctx, c, treasury()); err != nil {
		t.Fatalf("Create: %v\n%s", err, out)
	}
	want := []string{
		"talosvm_treasury_treasury-cp-1-net.yaml",
		"talosvm_treasury_treasury-general-1-net.yaml",
		"talosvm_treasury_treasury-general-2-net.yaml",
		"talosvm_treasury_treasury-general-3-net.yaml",
		tenantSnippet,
	}
	if got := listDir(t, c.SnippetsDir); !slices.Equal(got, want) {
		t.Errorf("snippets = %v, want %v", got, want)
	}
	b, _ := os.ReadFile(filepath.Join(c.SnippetsDir, "talosvm_treasury_treasury-general-2-net.yaml"))
	if !strings.Contains(string(b), "- 10.20.0.52/32") || !strings.Contains(string(b), MACFor("treasury", "treasury-general-2", 0)) {
		t.Errorf("snippet:\n%s", b)
	}

	// A second create changes nothing: the VMs exist, the ISO is there,
	// and the snippets are unchanged, so none is rewritten.
	f.calls = nil
	out.Reset()
	if err := create(ctx, c, treasury()); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 0 || strings.Contains(out.String(), WriteFile) {
		t.Errorf("second create sent calls %v or wrote:\n%s", f.calls, out)
	}
	// A stopped VM is started on a rerun, and nothing else happens.
	f.setStatus("105", "stopped")
	if err := create(ctx, c, treasury()); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(f.calls, []string{"POST /nodes/r620b/qemu/105/status/start"}) {
		t.Errorf("rerun with a stopped VM sent %v", f.calls)
	}

	// A rerun whose specs would move the cluster's nodes, here because the
	// layer above forgot the cluster's first address, is refused before any
	// change, and the snippets keep their addresses.
	f.calls = nil
	moved := treasury()
	for i := range moved {
		moved[i].Address = netip.AddrFrom4([4]byte{10, 20, 0, byte(60 + i)})
	}
	if err := create(ctx, c, moved); err == nil || !strings.Contains(err.Error(), "VM treasury-cp-1 has address 10.20.0.50, config says 10.20.0.60") {
		t.Errorf("moved create = %v", err)
	}
	if len(f.calls) != 0 {
		t.Errorf("moved create sent %v", f.calls)
	}
	if b, _ := os.ReadFile(filepath.Join(c.SnippetsDir, "talosvm_treasury_treasury-cp-1-net.yaml")); !strings.Contains(string(b), "10.20.0.50/32") {
		t.Errorf("snippet changed:\n%s", b)
	}

	// A missing snippet of an existing VM is written again, with the MAC
	// on its net0.
	os.Remove(filepath.Join(c.SnippetsDir, "talosvm_treasury_treasury-general-1-net.yaml"))
	out.Reset()
	if err := create(ctx, c, treasury()); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(filepath.Join(c.SnippetsDir, "talosvm_treasury_treasury-general-1-net.yaml")); err != nil || !strings.Contains(string(b), MACFor("treasury", "treasury-general-1", 0)) {
		t.Errorf("missing snippet not rewritten: %v\n%s", err, b)
	}
	if !strings.Contains(out.String(), "# 1/1 write the missing network snippet of treasury-general-1, 10.20.0.51/32 on MAC "+MACFor("treasury", "treasury-general-1", 0)) {
		t.Errorf("rewrite output:\n%s", out)
	}

	vms, err := c.List(ctx, "treasury")
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, v := range vms {
		got = append(got, fmt.Sprintf("%s %s %s/%s %s %s %s", v.Name, v.ID, v.Region, v.Zone, v.Label("role"), v.Label("pool"), v.NIC.Address))
	}
	want = []string{
		"treasury-cp-1 vmid 104 garage/r620a controlplane  10.20.0.50/32",
		"treasury-general-1 vmid 105 garage/r620b worker general 10.20.0.51/32",
		"treasury-general-2 vmid 106 garage/r620c worker general 10.20.0.52/32",
		"treasury-general-3 vmid 107 garage/r620a worker general 10.20.0.53/32",
	}
	if !slices.Equal(got, want) {
		t.Errorf("list =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}

	// A dry-run destroy, the command line's default, sends nothing.
	f.calls = nil
	c.DryRun = true
	if err := c.Destroy(ctx, "treasury"); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 0 {
		t.Errorf("dry-run destroy sent calls: %v", f.calls)
	}

	if got := listDir(t, c.SnippetsDir); len(got) != 5 {
		t.Errorf("dry-run destroy removed snippets: %v", got)
	}

	// Another cluster's VM and snippet, and every tenant and its snippet,
	// survive a real destroy.
	f.vms = append(f.vms, res(120, "lab-cp-1", "r620b", "talosvm;talosvm-cluster-lab;talosvm-role-controlplane"))
	os.WriteFile(filepath.Join(c.SnippetsDir, "talosvm_lab_lab-cp-1-net.yaml"), []byte(SnippetHeader("lab", "lab-cp-1")+"\n"), 0o644)
	os.WriteFile(filepath.Join(c.SnippetsDir, "talosvm_treasury_handmade-net.yaml"), []byte(SnippetHeader("treasury", "handmade")+"\n"), 0o644)
	c.DryRun = false
	if err := c.Destroy(ctx, "treasury"); err != nil {
		t.Fatal(err)
	}
	var left []int
	for _, v := range f.vms {
		left = append(left, v.VMID)
	}
	if !slices.Equal(left, []int{100, 101, 102, 103, 200, 9101, 9102, 9201, 9202, 9301, 9302, 120}) {
		t.Errorf("after destroy = %v", left)
	}
	if n := len(f.calls); n != 8 {
		t.Errorf("destroy sent %d calls, want a stop and a delete for each of 4 VMs: %v", n, f.calls)
	}
	// The prefix alone is not enough: talosvm_treasury_handmade-net.yaml
	// belongs to no VM destroy selected, so it stays.
	if got := listDir(t, c.SnippetsDir); !slices.Equal(got, []string{"talosvm_lab_lab-cp-1-net.yaml", "talosvm_treasury_handmade-net.yaml", tenantSnippet}) {
		t.Errorf("snippets after destroy = %v", got)
	}
	if b, _ := os.ReadFile(filepath.Join(c.SnippetsDir, tenantSnippet)); string(b) != tenantSnippetText {
		t.Error("destroy changed the tenant's snippet")
	}
}

func TestCreateRefusesBeforeChanging(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func(*fakePVE)
		want string
	}{
		{"name taken", func(f *fakePVE) { f.vms = append(f.vms, res(150, "treasury-general-1", "r620a", "")) }, "names are taken"},
		{"address taken", func(f *fakePVE) { f.configs[103] = map[string]string{"ipconfig0": "ip=10.20.0.52/32,gw=10.20.0.1"} }, "10.20.0.52 is already used by vmid 103 jeffsbox"},
		{"address in a cicustom snippet", func(f *fakePVE) {
			f.configs[103] = map[string]string{"cicustom": "network=garage:snippets/jeffsbox-net.yaml"}
		}, "10.20.0.53 is already used by vmid 103 jeffsbox"},
		{"privilege missing", func(f *fakePVE) {
			f.privs = slices.DeleteFunc(f.privs, func(p string) bool { return p == "VM.Config.Cloudinit" })
		}, "VM.Config.Cloudinit"},
	} {
		f := newFake()
		tc.edit(f)
		c, _ := newCompute(t, f)
		os.WriteFile(filepath.Join(c.SnippetsDir, "jeffsbox-net.yaml"), []byte("version: 2\nethernets:\n  net0:\n    addresses: [10.20.0.53/32]\n"), 0o644)
		err := create(context.Background(), c, treasury())
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: err = %v, want %q", tc.name, err, tc.want)
		}
		if len(f.calls) != 0 {
			t.Errorf("%s: Create changed the cluster before refusing: %v", tc.name, f.calls)
		}
		if got := listDir(t, c.SnippetsDir); len(got) != 2 {
			t.Errorf("%s: Create wrote snippets before refusing: %v", tc.name, got)
		}
	}
}

// The provider guards what goes into names, tags, property strings and
// file names, whatever the layer above validated.
func TestPlanRefusesBadSpecs(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func(*infra.VMSpec)
		want string
	}{
		{"name", func(s *infra.VMSpec) { s.Name = "../x" }, `VM name "../x"`},
		{"label key", func(s *infra.VMSpec) { s.Labels = []infra.Label{{Key: "cluster", Value: "lab"}} }, "label cluster=lab"},
		{"label value", func(s *infra.VMSpec) { s.Labels = []infra.Label{{Key: "pool", Value: "a;b"}} }, "label pool=a;b"},
		{"network", func(s *infra.VMSpec) { s.Network = "k8s,mtu=1500" }, `network "k8s,mtu=1500"`},
		{"image", func(s *infra.VMSpec) { s.Image.Name = "../x.iso" }, `image "../x.iso"`},
		{"disks", func(s *infra.VMSpec) { s.Disks = append(s.Disks, s.Disks[0]) }, "exactly one disk"},
		{"address", func(s *infra.VMSpec) { s.Address = netip.MustParseAddr("10.20.0.35") }, "reserved (ingress)"},
	} {
		f := newFake()
		c, _ := newCompute(t, f)
		specs := treasury()
		tc.edit(&specs[1])
		if _, err := c.Plan(context.Background(), "treasury", specs); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: Plan = %v, want %q", tc.name, err, tc.want)
		}
	}
}

// A Compute built outside talosvm still has its config checked before Plan
// reads anything, so a bad nameserver is refused rather than left off every
// NIC.
func TestPlanChecksConfig(t *testing.T) {
	f := newFake()
	c, _ := newCompute(t, f)
	c.Config.Nameserver = "dns.lan"
	if _, err := c.Plan(context.Background(), "treasury", treasury()); err == nil || !strings.Contains(err.Error(), `nameserver "dns.lan"`) {
		t.Errorf("Plan = %v, want the nameserver refused", err)
	}
}

func TestDestroyChecksPrivileges(t *testing.T) {
	f := newFake()
	f.privs = slices.DeleteFunc(f.privs, func(p string) bool { return p == "VM.Allocate" })
	c, _ := newCompute(t, f)
	var me *preflight.MissingError
	if err := c.Destroy(context.Background(), "treasury"); !errors.As(err, &me) {
		t.Errorf("Destroy err = %v, want a MissingError", err)
	}
}

func TestCreateRejectsOfflineNode(t *testing.T) {
	c, _ := newCompute(t, newFake())
	c.Config.Nodes = []string{"old"}
	if err := create(context.Background(), c, treasury()); err == nil || !strings.Contains(err.Error(), `"old" is not an online`) {
		t.Errorf("Create err = %v, want old offline", err)
	}
	// A spec's own zones must be online too.
	c.Config.Nodes = nil
	specs := treasury()
	specs[2].Zones = []string{"old"}
	if err := create(context.Background(), c, specs); err == nil || !strings.Contains(err.Error(), `"old" is not an online`) {
		t.Errorf("Create err = %v, want old offline", err)
	}
}

func TestSnippetsDirRequired(t *testing.T) {
	f := newFake()
	c, _ := newCompute(t, f)
	c.SnippetsDir = filepath.Join(t.TempDir(), "not-mounted")
	for _, run := range []func(context.Context) error{
		func(ctx context.Context) error { return create(ctx, c, treasury()) },
		func(ctx context.Context) error { return c.Destroy(ctx, "treasury") },
	} {
		if err := run(context.Background()); err == nil || !strings.Contains(err.Error(), "snippets dir") {
			t.Errorf("err = %v, want the snippets dir refused", err)
		}
	}
	if len(f.calls) != 0 {
		t.Errorf("sent calls without a snippets dir: %v", f.calls)
	}
}

func TestWriteFileAtomic(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "talosvm_treasury_treasury-cp-1-net.yaml")
	if err := writeFileAtomic(p, "a\n"); err != nil {
		t.Fatal(err)
	}
	if err := writeFileAtomic(p, "b\n"); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(p); string(b) != "b\n" || fi.Mode().Perm() != 0o644 {
		t.Errorf("content %q mode %v", b, fi.Mode().Perm())
	}
	if got := listDir(t, dir); len(got) != 1 {
		t.Errorf("temporary files left: %v", got)
	}
}

// A file at a VM's snippet name that the provider did not write for that VM
// is never overwritten: create refuses before any change.
func TestCreateRefusesForeignSnippet(t *testing.T) {
	f := newFake()
	c, _ := newCompute(t, f)
	p := filepath.Join(c.SnippetsDir, SnippetName("treasury", "treasury-cp-1"))
	os.WriteFile(p, []byte("# hand-written\nversion: 2\n"), 0o644)
	if err := create(context.Background(), c, treasury()); err == nil || !strings.Contains(err.Error(), "refusing to touch") {
		t.Errorf("Create = %v, want a refusal", err)
	}
	if len(f.calls) != 0 {
		t.Errorf("sent %v", f.calls)
	}
	if b, _ := os.ReadFile(p); string(b) != "# hand-written\nversion: 2\n" {
		t.Errorf("foreign file changed:\n%s", b)
	}
}

// Other tenants' snippets are read through readSnippet, which must not
// follow a symlink, block on a FIFO, or read a huge file whole.
func TestReadSnippetIsCareful(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "target")
	os.WriteFile(target, []byte("10.20.0.9\n"), 0o644)
	link := filepath.Join(dir, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	fifo := filepath.Join(dir, "fifo")
	if err := syscall.Mkfifo(fifo, 0o644); err != nil {
		t.Fatal(err)
	}
	big := filepath.Join(dir, "big")
	os.WriteFile(big, make([]byte, maxSnippetSize+1), 0o644)
	for _, p := range []string{link, fifo, big, dir} {
		done := make(chan error, 1)
		go func() { _, _, err := readSnippet(p); done <- err }()
		select {
		case err := <-done:
			if err == nil {
				t.Errorf("readSnippet(%s) accepted it", filepath.Base(p))
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("readSnippet(%s) blocked", filepath.Base(p))
		}
	}
	if text, found, err := readSnippet(target); err != nil || !found || text != "10.20.0.9\n" {
		t.Errorf("readSnippet(regular) = %q, %v, %v", text, found, err)
	}
	if _, found, err := readSnippet(filepath.Join(dir, "missing")); err != nil || found {
		t.Errorf("readSnippet(missing) = %v, %v", found, err)
	}
}

// One VM whose pending size cannot be read does not fail List: it carries
// the error, and the rest are reported as usual.
func TestListToleratesUnreadableSize(t *testing.T) {
	f := newFake()
	c, out := newCompute(t, f)
	ctx := context.Background()
	if err := create(ctx, c, treasury()); err != nil {
		t.Fatalf("Create: %v\n%s", err, out)
	}
	delete(f.configs[106], "memory")
	vms, err := c.List(ctx, "treasury")
	if err != nil {
		t.Fatal(err)
	}
	if g := vms[2]; g.Name != "treasury-general-2" || g.SizingErr == nil || !strings.Contains(g.SizingErr.Error(), "VM treasury-general-2 vmid 106: its config has no memory") || g.Sizing != (infra.Sizing{}) {
		t.Errorf("unreadable VM = %+v", g)
	}
	if g := vms[1]; g.SizingErr != nil || g.Sizing.Now.MemoryMiB != 16384 {
		t.Errorf("readable VM = %+v", g)
	}
}

// PowerCycle shuts the VM down cleanly, with a hard stop after the timeout,
// then starts it; a failure of either says what state the VM is left in.
func TestPowerCycle(t *testing.T) {
	f := newFake()
	f.vms = append(f.vms, res(105, "treasury-general-1", "r620b", "talosvm;talosvm-cluster-treasury;talosvm-role-worker;talosvm-pool-general"))
	c, _ := newCompute(t, f)
	ctx := context.Background()
	vms, err := c.List(ctx, "treasury")
	if err != nil || len(vms) != 1 {
		t.Fatalf("List = %v, %v", vms, err)
	}
	vm := vms[0]
	want := []string{
		"POST /api2/json/nodes/r620b/qemu/105/status/shutdown\n    forceStop=1\n    timeout=300",
		"POST /api2/json/nodes/r620b/qemu/105/status/start",
	}
	if got := c.PowerCycleCalls(vm, 5*time.Minute); !slices.Equal(got, want) {
		t.Errorf("PowerCycleCalls =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	if err := c.PowerCycle(ctx, "treasury", vm, 5*time.Minute); err != nil {
		t.Fatal(err)
	}
	if want := []string{"POST /nodes/r620b/qemu/105/status/shutdown", "POST /nodes/r620b/qemu/105/status/start"}; !slices.Equal(f.calls, want) {
		t.Errorf("sent %v", f.calls)
	}
	if form := f.forms[0]; form.Get("forceStop") != "1" || form.Get("timeout") != "300" {
		t.Errorf("shutdown form = %v", form)
	}
	for _, tc := range []struct{ call, want string }{
		{"/status/shutdown", "500 Internal Server Error; the VM may still be shutting down: once it is stopped, start it in Proxmox"},
		{"/status/start", "the VM is stopped: start it in Proxmox"},
	} {
		f.failCall, f.calls = tc.call, nil
		if err := c.PowerCycle(ctx, "treasury", vm, time.Minute); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s fails: err = %v, want %q", tc.call, err, tc.want)
		}
		if last := f.calls[len(f.calls)-1]; !strings.HasSuffix(last, tc.call) {
			t.Errorf("%s fails: went on to %s", tc.call, last)
		}
	}
	// A dry run checks the VM and sends nothing.
	f.failCall, f.calls, c.DryRun = "", nil, true
	if err := c.PowerCycle(ctx, "treasury", vm, time.Minute); err != nil || len(f.calls) != 0 {
		t.Errorf("dry-run PowerCycle = %v, sent %v", err, f.calls)
	}
}

// Resize and PowerCycle act only on the cluster's own VMs, as Proxmox lists
// them now, whatever VM a caller hands in: not another cluster's VM, not a
// hand-made VM with one of the cluster's names, not a VM of another
// provider, and not for a cluster the VM is not in. Nothing is sent.
func TestResizeAndPowerCycleCheckOwnership(t *testing.T) {
	f := newFake()
	f.vms = append(f.vms,
		res(105, "treasury-general-1", "r620b", "talosvm;talosvm-cluster-treasury;talosvm-pool-general;talosvm-role-worker"),
		res(120, "lab-general-1", "r620c", "talosvm;talosvm-cluster-lab;talosvm-pool-general;talosvm-role-worker"),
		res(300, "treasury-general-2", "r620c", ""))
	c, _ := newCompute(t, f)
	ctx := context.Background()
	sizing := infra.Sizing{Now: infra.Size{Cores: 4, MemoryMiB: 8192}, Next: infra.Size{Cores: 4, MemoryMiB: 8192}}
	vm := func(name, vmid, zone string) infra.VM {
		return infra.VM{Name: name, ID: infra.ID{Kind: "vmid", Value: vmid}, Zone: zone, Sizing: sizing}
	}
	for _, tc := range []struct {
		name, cluster string
		vm            infra.VM
		want          string
	}{
		{"another cluster's VM", "treasury", vm("treasury-general-3", "120", "r620c"), "is not a VM of cluster treasury"},
		{"another cluster's VM by its own name", "treasury", vm("lab-general-1", "120", "r620c"), "is not a VM of cluster treasury"},
		{"a hand-made VM with a cluster name", "treasury", vm("treasury-general-2", "300", "r620c"), "is not a VM of cluster treasury"},
		{"a VMID that names another VM", "treasury", vm("treasury-general-2", "105", "r620b"), "is not a VM of cluster treasury"},
		{"no such VMID", "treasury", vm("treasury-general-4", "999", "r620a"), "is not a VM of cluster treasury"},
		{"the wrong cluster", "lab", vm("treasury-general-1", "105", "r620b"), "is not a VM of cluster lab"},
		{"another provider's VM", "treasury", infra.VM{Name: "treasury-general-1", ID: infra.ID{Kind: "instance", Value: "i-1"}, Zone: "a"}, "not a Proxmox VM"},
	} {
		f.calls = nil
		if err := c.Resize(ctx, tc.cluster, []infra.Resize{{VM: tc.vm, Size: infra.Size{Cores: 4, MemoryMiB: 16384}}}); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: Resize = %v, want %q", tc.name, err, tc.want)
		}
		if err := c.PowerCycle(ctx, tc.cluster, tc.vm, time.Minute); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: PowerCycle = %v, want %q", tc.name, err, tc.want)
		}
		if len(f.calls) != 0 {
			t.Errorf("%s: sent %v", tc.name, f.calls)
		}
	}
	// One VM that is not the cluster's stops the whole resize.
	f.calls = nil
	err := c.Resize(ctx, "treasury", []infra.Resize{
		{VM: vm("treasury-general-1", "105", "r620b"), Size: infra.Size{Cores: 4, MemoryMiB: 16384}},
		{VM: vm("treasury-general-2", "300", "r620c"), Size: infra.Size{Cores: 4, MemoryMiB: 16384}},
	})
	if err == nil || len(f.calls) != 0 {
		t.Errorf("mixed Resize = %v, sent %v", err, f.calls)
	}
	// The cluster's own VM is resized, at the node Proxmox lists it on.
	if err := c.Resize(ctx, "treasury", []infra.Resize{{VM: vm("treasury-general-1", "105", "elsewhere"), Size: infra.Size{Cores: 4, MemoryMiB: 16384}}}); err != nil ||
		!slices.Equal(f.calls, []string{"PUT /nodes/r620b/qemu/105/config"}) {
		t.Errorf("own Resize = %v, sent %v", err, f.calls)
	}
}

// sameLabels compares labels in any order: Proxmox sorts the tags they are
// kept in.
func sameLabels(a, b []infra.Label) bool {
	cmp := func(x, y infra.Label) int { return strings.Compare(x.Key+"="+x.Value, y.Key+"="+y.Value) }
	a, b = slices.Clone(a), slices.Clone(b)
	slices.SortFunc(a, cmp)
	slices.SortFunc(b, cmp)
	return slices.Equal(a, b)
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
