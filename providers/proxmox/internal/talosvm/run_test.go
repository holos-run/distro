package talosvm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
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

	"go.holos.run/distro/providers/proxmox/internal/pve"
	"go.holos.run/distro/providers/proxmox/preflight"
)

// fakePVE is just enough of the Proxmox API for create, list, destroy,
// check and restart. Tasks finish at once. It records every call that is not a GET.
type fakePVE struct {
	mu      sync.Mutex
	vms     []pve.Resource
	configs map[int]map[string]string
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
	f := &fakePVE{vms: tenants(), configs: map[int]map[string]string{}, privs: preflight.Names(preflight.Required())}
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
	case len(parts) == 5 && parts[4] == "config":
		id, _ := strconv.Atoi(parts[3])
		reply(f.configs[id])
	case len(parts) == 3 && parts[2] == "qemu" && r.Method == http.MethodPost:
		id, _ := strconv.Atoi(r.Form.Get("vmid"))
		f.vms = append(f.vms, pve.Resource{VMID: id, Name: r.Form.Get("name"), Node: parts[1], Type: "qemu", Status: "stopped", Tags: r.Form.Get("tags")})
		f.configs[id] = map[string]string{"cicustom": r.Form.Get("cicustom"), "net0": r.Form.Get("net0")}
		reply(upid(parts[1], "qmcreate"))
	case len(parts) == 6 && parts[5] == "start":
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

func (f *fakePVE) setStatus(vmid, status string) {
	for i := range f.vms {
		if strconv.Itoa(f.vms[i].VMID) == vmid {
			f.vms[i].Status = status
		}
	}
}

func newRunner(t *testing.T, f *fakePVE, cfg Config) (*Runner, *bytes.Buffer) {
	t.Helper()
	srv := httptest.NewServer(f)
	t.Cleanup(srv.Close)
	factory := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusCreated)
		io.WriteString(w, `{"id":"0123456789abcdef0123"}`)
	}))
	t.Cleanup(factory.Close)
	c, err := pve.New(srv.URL, "holos@pve!distro", "s", srv.Client())
	if err != nil {
		t.Fatal(err)
	}
	c.PollInterval = time.Millisecond
	out := &bytes.Buffer{}
	return &Runner{PVE: c, Factory: Factory{BaseURL: factory.URL, HTTP: factory.Client()}, Config: cfg, Out: out, SnippetsDir: snippetsDir(t)}, out
}

func TestCreateDryRunPrintsExactCalls(t *testing.T) {
	f := newFake()
	r, out := newRunner(t, f, treasury())
	r.DryRun = true
	if err := r.Create(context.Background()); err != nil {
		t.Fatalf("Create: %v\n%s", err, out)
	}
	t.Log(out) // go test -v shows what a first real run prints
	if len(f.calls) != 0 {
		t.Errorf("dry run sent calls: %v", f.calls)
	}
	if got := listDir(t, r.SnippetsDir); !slices.Equal(got, []string{tenantSnippet}) {
		t.Errorf("dry run wrote files: %v", got)
	}
	for _, want := range []string{
		"WRITE " + filepath.Join(r.SnippetsDir, "talosvm_treasury_treasury-cp-1-net.yaml") + " (mode 0644)\n",
		"    | # Written by talosvm for cluster treasury, VM treasury-cp-1.\n",
		"POST /api2/json/nodes/r620a/qemu/104/status/start\n",
		"    |       - 10.20.0.50/32\n",
		"    |         on-link: true\n",
		"    cicustom=network=garage:snippets/talosvm_treasury_treasury-cp-1-net.yaml\n",
		"    net0=virtio=" + MACFor("treasury", "treasury-cp-1", 0) + ",bridge=k8s,mtu=1\n",
		"POST /api2/json/nodes/r620a/storage/garage/download-url",
		"    url=" + r.Factory.BaseURL + "/image/0123456789abcdef0123/v1.14.4/nocloud-amd64.iso",
		"POST /api2/json/nodes/r620a/qemu\n",
		"    name=treasury-cp-1\n",
		"    vmid=104\n",
		"    name=treasury-general-3\n",
		"    vmid=107\n",
		"dry run: sent none of these 13 calls",
	} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("dry run output lacks %q:\n%s", want, out)
		}
	}
}

func TestCreateListDestroy(t *testing.T) {
	f := newFake()
	r, out := newRunner(t, f, treasury())
	ctx := context.Background()
	if err := r.Create(ctx); err != nil {
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

	want := []string{
		"talosvm_treasury_treasury-cp-1-net.yaml",
		"talosvm_treasury_treasury-general-1-net.yaml",
		"talosvm_treasury_treasury-general-2-net.yaml",
		"talosvm_treasury_treasury-general-3-net.yaml",
		tenantSnippet,
	}
	if got := listDir(t, r.SnippetsDir); !slices.Equal(got, want) {
		t.Errorf("snippets = %v, want %v", got, want)
	}
	b, _ := os.ReadFile(filepath.Join(r.SnippetsDir, "talosvm_treasury_treasury-general-2-net.yaml"))
	if !strings.Contains(string(b), "- 10.20.0.52/32") || !strings.Contains(string(b), MACFor("treasury", "treasury-general-2", 0)) {
		t.Errorf("snippet:\n%s", b)
	}

	// A second create changes nothing: the VMs exist, the ISO is there,
	// and the snippets are unchanged, so none is rewritten.
	f.calls = nil
	out.Reset()
	if err := r.Create(ctx); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 0 || strings.Contains(out.String(), WriteFile) {
		t.Errorf("second create sent calls %v or wrote:\n%s", f.calls, out)
	}
	// A stopped VM is started on a rerun, and nothing else happens.
	f.setStatus("105", "stopped")
	if err := r.Create(ctx); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(f.calls, []string{"POST /nodes/r620b/qemu/105/status/start"}) {
		t.Errorf("rerun with a stopped VM sent %v", f.calls)
	}

	// A rerun whose config would move the cluster's nodes, here because it
	// forgot the cluster's -first-address, is refused before any change,
	// and the snippets keep their addresses.
	f.calls = nil
	moved := *r
	moved.Config.FirstAddress = "10.20.0.60"
	if err := moved.Create(ctx); err == nil || !strings.Contains(err.Error(), "VM treasury-cp-1 has address 10.20.0.50, config says 10.20.0.60") {
		t.Errorf("moved create = %v", err)
	}
	if len(f.calls) != 0 {
		t.Errorf("moved create sent %v", f.calls)
	}
	if b, _ := os.ReadFile(filepath.Join(r.SnippetsDir, "talosvm_treasury_treasury-cp-1-net.yaml")); !strings.Contains(string(b), "10.20.0.50/32") {
		t.Errorf("snippet changed:\n%s", b)
	}

	// A missing snippet of an existing VM is written again, with the MAC
	// on its net0.
	os.Remove(filepath.Join(r.SnippetsDir, "talosvm_treasury_treasury-general-1-net.yaml"))
	out.Reset()
	if err := r.Create(ctx); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(filepath.Join(r.SnippetsDir, "talosvm_treasury_treasury-general-1-net.yaml")); err != nil || !strings.Contains(string(b), MACFor("treasury", "treasury-general-1", 0)) {
		t.Errorf("missing snippet not rewritten: %v\n%s", err, b)
	}

	out.Reset()
	if err := r.List(ctx, true); err != nil {
		t.Fatal(err)
	}
	var rows []VM
	if err := json.Unmarshal(out.Bytes(), &rows); err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, v := range rows {
		got = append(got, fmt.Sprintf("%s %d %s/%s %s %s %s", v.Name, v.VMID, v.Region, v.Zone, v.Role, v.Pool, v.Address))
	}
	want = []string{
		"treasury-cp-1 104 garage/r620a controlplane  10.20.0.50",
		"treasury-general-1 105 garage/r620b worker general 10.20.0.51",
		"treasury-general-2 106 garage/r620c worker general 10.20.0.52",
		"treasury-general-3 107 garage/r620a worker general 10.20.0.53",
	}
	if !slices.Equal(got, want) {
		t.Errorf("list =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}

	// A dry-run destroy, the command line's default, sends nothing.
	f.calls = nil
	r.DryRun = true
	if err := r.Destroy(ctx); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 0 {
		t.Errorf("dry-run destroy sent calls: %v", f.calls)
	}

	if got := listDir(t, r.SnippetsDir); len(got) != 5 {
		t.Errorf("dry-run destroy removed snippets: %v", got)
	}

	// Another cluster's VM and snippet, and every tenant and its snippet,
	// survive a real destroy.
	f.vms = append(f.vms, res(120, "lab-cp-1", "r620b", "talosvm;talosvm-cluster-lab;talosvm-role-controlplane"))
	os.WriteFile(filepath.Join(r.SnippetsDir, "talosvm_lab_lab-cp-1-net.yaml"), []byte(SnippetHeader("lab", "lab-cp-1")+"\n"), 0o644)
	os.WriteFile(filepath.Join(r.SnippetsDir, "talosvm_treasury_handmade-net.yaml"), []byte(SnippetHeader("treasury", "handmade")+"\n"), 0o644)
	r.DryRun = false
	if err := r.Destroy(ctx); err != nil {
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
	if got := listDir(t, r.SnippetsDir); !slices.Equal(got, []string{"talosvm_lab_lab-cp-1-net.yaml", "talosvm_treasury_handmade-net.yaml", tenantSnippet}) {
		t.Errorf("snippets after destroy = %v", got)
	}
	if b, _ := os.ReadFile(filepath.Join(r.SnippetsDir, tenantSnippet)); string(b) != tenantSnippetText {
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
		r, _ := newRunner(t, f, treasury())
		os.WriteFile(filepath.Join(r.SnippetsDir, "jeffsbox-net.yaml"), []byte("version: 2\nethernets:\n  net0:\n    addresses: [10.20.0.53/32]\n"), 0o644)
		err := r.Create(context.Background())
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: err = %v, want %q", tc.name, err, tc.want)
		}
		if len(f.calls) != 0 {
			t.Errorf("%s: Create changed the cluster before refusing: %v", tc.name, f.calls)
		}
		if got := listDir(t, r.SnippetsDir); len(got) != 2 {
			t.Errorf("%s: Create wrote snippets before refusing: %v", tc.name, got)
		}
	}
}

func TestDestroyChecksPrivileges(t *testing.T) {
	f := newFake()
	f.privs = slices.DeleteFunc(f.privs, func(p string) bool { return p == "VM.Allocate" })
	r, _ := newRunner(t, f, treasury())
	var me *preflight.MissingError
	if err := r.Destroy(context.Background()); !errors.As(err, &me) {
		t.Errorf("Destroy err = %v, want a MissingError", err)
	}
}

func TestCreateRejectsOfflineNode(t *testing.T) {
	cfg := treasury()
	cfg.Nodes = []string{"old"}
	r, _ := newRunner(t, newFake(), cfg)
	if err := r.Create(context.Background()); err == nil || !strings.Contains(err.Error(), `"old" is not an online`) {
		t.Errorf("Create err = %v, want old offline", err)
	}
}

func TestSnippetsDirRequired(t *testing.T) {
	f := newFake()
	r, _ := newRunner(t, f, treasury())
	r.SnippetsDir = filepath.Join(t.TempDir(), "not-mounted")
	for _, run := range []func(context.Context) error{r.Create, r.Destroy} {
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

// A file at a VM's snippet name that talosvm did not write for that VM is
// never overwritten: create refuses before any change.
func TestCreateRefusesForeignSnippet(t *testing.T) {
	f := newFake()
	r, _ := newRunner(t, f, treasury())
	p := filepath.Join(r.SnippetsDir, SnippetName("treasury", "treasury-cp-1"))
	os.WriteFile(p, []byte("# hand-written\nversion: 2\n"), 0o644)
	if err := r.Create(context.Background()); err == nil || !strings.Contains(err.Error(), "refusing to touch") {
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
