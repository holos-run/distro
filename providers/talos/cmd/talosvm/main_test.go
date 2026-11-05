package main

import (
	"context"
	"errors"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"go.holos.run/distro/providers/infra"
	"go.holos.run/distro/providers/proxmox"
	"go.holos.run/distro/providers/talos"
)

func env(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

// The checks below all fail before any request is sent, so they need no
// Proxmox to talk to. Those that name treasury run from this package's
// directory and so read its committed config.
func TestRunRejects(t *testing.T) {
	full := map[string]string{
		"PROXMOX_URL":          "https://r620a.lan:8006",
		"PROXMOX_TOKEN_ID":     "holos@pve!distro",
		"PROXMOX_TOKEN_SECRET": "x",
	}
	without := func(k string) map[string]string {
		m := map[string]string{}
		for kk, v := range full {
			if kk != k {
				m[kk] = v
			}
		}
		return m
	}
	for _, tc := range []struct {
		name string
		args []string
		env  map[string]string
		want string
	}{
		{"no command", nil, full, "no command"},
		{"unknown command", []string{"apply"}, full, "unknown command"},
		{"stray argument", []string{"list", "extra"}, full, "takes no arguments"},
		{"no endpoint", []string{"list", "-cluster", "treasury"}, without("PROXMOX_URL"), "PROXMOX_URL"},
		{"http endpoint", []string{"list", "-cluster", "treasury"}, map[string]string{"PROXMOX_URL": "http://r620a:8006", "PROXMOX_TOKEN_ID": "a@pve!b", "PROXMOX_TOKEN_SECRET": "x"}, "want https"},
		{"no secret", []string{"list", "-cluster", "treasury"}, without("PROXMOX_TOKEN_SECRET"), "PROXMOX_TOKEN_SECRET"},
		{"ca and insecure", []string{"list", "-ca-file", "x.pem", "-insecure"}, full, "mutually exclusive"},
		{"missing config", []string{"create", "-config", "/nonexistent/talosvm.json"}, full, "no such file"},
		{"no cluster", []string{"create"}, full, "cluster is required"},
		{"ingress address", []string{"create", "-cluster", "treasury", "-first-address", "10.20.0.45"}, full, "reserved (ingress)"},
		{"manual address", []string{"create", "-cluster", "treasury", "-first-address", "10.20.0.22"}, full, "reserved (manual)"},
		{"secret in token ID", []string{"list", "-cluster", "treasury"}, map[string]string{"PROXMOX_URL": "https://r620a:8006", "PROXMOX_TOKEN_ID": "0b1c2d3e-secret", "PROXMOX_TOKEN_SECRET": "holos@pve!distro"}, "want USER@REALM!TOKENID"},
		{"credentials in URL", []string{"list", "-cluster", "treasury"}, map[string]string{"PROXMOX_URL": "https://u:0b1c2d3e-secret@r620a:8006", "PROXMOX_TOKEN_ID": "a@pve!b", "PROXMOX_TOKEN_SECRET": "x"}, "without credentials"},
		{"restart mode", []string{"restart", "-cluster", "treasury", "-mode", "halt"}, full, `mode "halt"`},
		{"restart no cluster", []string{"restart", "-kubectl", "/bin/true"}, full, "cluster is required"},
		{"restart node twice", []string{"restart", "-cluster", "treasury", "-nodes", "treasury-general-1,treasury-general-1"}, full, "named twice"},
		{"restart daemonset", []string{"restart", "-cluster", "treasury", "-require-daemonsets", "cilium"}, full, "want namespace/name"},
		{"restart shutdown timeout", []string{"restart", "-cluster", "treasury", "-mode", "power-cycle", "-timeout", "1m", "-shutdown-timeout", "5m"}, full, "less than the timeout"},
		{"restart no kubectl", []string{"restart", "-cluster", "treasury", "-kubectl", "/nonexistent/kubectl"}, full, "-kubectl"},
		{"restart no talosctl", []string{"restart", "-cluster", "treasury", "-kubectl", "/bin/true", "-talosctl", "/nonexistent/talosctl"}, full, "-talosctl"},
		{"off subnet", []string{"create", "-cluster", "treasury", "-first-address", "192.168.2.50"}, full, "outside the node subnet"},
		{"resize no cluster", []string{"resize"}, full, "cluster is required"},
		{"resize missing config", []string{"resize", "-config", "/nonexistent/talosvm.json"}, full, "no such file"},
		{"resize takes no -yes", []string{"resize", "-cluster", "treasury", "-yes"}, full, "flag provided but not defined"},
		{"resize node twice", []string{"resize", "-cluster", "treasury", "-nodes", "treasury-cp-1,treasury-cp-1"}, full, "named twice"},
		{"resize bad node", []string{"resize", "-cluster", "treasury", "-nodes", "Treasury-cp-1"}, full, "not a VM name"},
		{"resize no endpoint", []string{"resize", "-cluster", "treasury", "-dry-run"}, without("PROXMOX_URL"), "PROXMOX_URL"},
	} {
		err := run(context.Background(), tc.args, io.Discard, io.Discard, env(tc.env))
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: err = %v, want it to mention %q", tc.name, err, tc.want)
		}
		if err != nil && strings.Contains(err.Error(), "0b1c2d3e") {
			t.Errorf("%s: error echoes a secret: %v", tc.name, err)
		}
	}
}

// resize takes -workers as create does, through the same override, so a
// cluster made with -workers is resized with the same pool. Each case fails
// before any request is sent: on the config, or, once the config is valid,
// on the missing endpoint.
func TestWorkersFlag(t *testing.T) {
	noPools := filepath.Join(t.TempDir(), "nopools.json")
	if err := os.WriteFile(noPools, []byte(`{"pools":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, cmd := range []string{"create", "resize"} {
		for _, tc := range []struct {
			args []string
			want string
		}{
			{[]string{"-workers", "5"}, "PROXMOX_URL"},
			{[]string{"-workers", "250"}, "pools[0] VM"},
			{[]string{"-config", noPools, "-workers", "2"}, "-workers: the config has no pools"},
		} {
			args := append([]string{cmd, "-cluster", "treasury"}, tc.args...)
			err := run(context.Background(), args, io.Discard, io.Discard, env(nil))
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Errorf("%v: err = %v, want it to mention %q", args, err, tc.want)
			}
		}
	}
}

// The config file keeps the flat keys it had before the split, half of them
// the Talos layer's and half the Proxmox provider's, and its defaults are
// the garage's: the file README.md shows is the defaults with a cluster.
func TestConfigFile(t *testing.T) {
	file := filepath.Join(t.TempDir(), "talosvm.json")
	if err := os.WriteFile(file, []byte(`{
  "cluster": "treasury",
  "talosVersion": "v1.14.4",
  "nodes": [],
  "diskStorage": "local-zfs",
  "isoStorage": "garage",
  "snippetStorage": "garage",
  "diskSSD": true,
  "bridge": "k8s",
  "nameserver": "192.168.2.1",
  "searchDomain": "lan",
  "firstAddress": "10.20.0.50",
  "controlPlane": { "count": 1, "cores": 2, "memoryMiB": 8192, "diskGiB": 32 },
  "pools": [
    { "name": "general", "count": 3, "cores": 4, "memoryMiB": 16384, "diskGiB": 64 }
  ]
}`), 0o600); err != nil {
		t.Fatal(err)
	}
	got := defaultConfig()
	if err := talos.Decode(file, &got); err != nil {
		t.Fatal(err)
	}
	want := defaultConfig()
	want.Cluster = "treasury"
	want.Nodes = []string{}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("config =\n%+v\nwant\n%+v", got, want)
	}
	if err := errors.Join(got.TalosConfig.Validate(proxmox.CheckNodeAddress), got.ProxmoxConfig.Validate()); err != nil {
		t.Errorf("the README's config is invalid: %v", err)
	}
}

// committedCluster reads a committed config over the defaults, as run does.
func committedCluster(t *testing.T, name string) config {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root, ok := repoRoot(dir)
	if !ok {
		t.Fatalf("no repository root above %s", dir)
	}
	cfg := defaultConfig()
	if err := talos.Decode(filepath.Join(root, clusterConfigDir, name, clusterConfigFile), &cfg); err != nil {
		t.Fatal(err)
	}
	return cfg
}

// Every committed config is valid for both layers and names the directory it
// is in, since -cluster finds it by that name and overrides what it says. Each
// states its own version and first address, since cluster.sh reads the version
// from the file alone and a file without an address would land on slot 1's, and
// no two clusters share an address.
func TestCommittedClusters(t *testing.T) {
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root, ok := repoRoot(dir)
	if !ok {
		t.Fatalf("no repository root above %s", dir)
	}
	entries, err := os.ReadDir(filepath.Join(root, clusterConfigDir))
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	owners := map[netip.Addr]string{}
	for _, e := range entries {
		if !e.IsDir() {
			t.Errorf("%s: want one directory per cluster", e.Name())
			continue
		}
		seen[e.Name()] = true
		var stated config
		if err := talos.Decode(filepath.Join(root, clusterConfigDir, e.Name(), clusterConfigFile), &stated); err != nil {
			t.Fatal(err)
		}
		if stated.TalosVersion == "" {
			t.Errorf("%s: the file sets no talosVersion", e.Name())
		}
		if stated.FirstAddress == "" {
			t.Errorf("%s: the file sets no firstAddress", e.Name())
		}
		cfg := committedCluster(t, e.Name())
		if cfg.Cluster != e.Name() {
			t.Errorf("%s: cluster = %q, want the directory's name", e.Name(), cfg.Cluster)
		}
		if err := errors.Join(cfg.TalosConfig.Validate(proxmox.CheckNodeAddress), cfg.ProxmoxConfig.Validate()); err != nil {
			t.Errorf("%s: %v", e.Name(), err)
			continue
		}
		specs, err := cfg.TalosConfig.Specs()
		if err != nil {
			t.Errorf("%s: %v", e.Name(), err)
			continue
		}
		for _, s := range specs {
			if other, dup := owners[s.Address]; dup {
				t.Errorf("%s: %s is also %s's", e.Name(), s.Address, other)
			}
			owners[s.Address] = e.Name()
		}
	}
	for _, name := range []string{"cartography", "treasury"} {
		if !seen[name] {
			t.Errorf("no committed config for %s", name)
		}
	}
}

// Treasury's file records the defaults it was made with, so pinning it changes
// nothing for its live VMs.
func TestTreasuryIsTheDefaults(t *testing.T) {
	want := defaultConfig()
	want.Cluster = "treasury"
	if got := committedCluster(t, "treasury"); !reflect.DeepEqual(got, want) {
		t.Errorf("config =\n%+v\nwant\n%+v", got, want)
	}
}

// Cartography takes slot 2 at treasury's sizes, a patch ahead of it.
func TestCartography(t *testing.T) {
	cfg := committedCluster(t, "cartography")
	if cfg.TalosVersion != "v1.14.5" {
		t.Errorf("talosVersion = %q", cfg.TalosVersion)
	}
	specs, err := cfg.Specs()
	if err != nil {
		t.Fatal(err)
	}
	type vm struct {
		name, address string
		size          infra.Size
		diskGiB       int
	}
	var got []vm
	for _, s := range specs {
		got = append(got, vm{s.Name, s.Address.String(), s.Size, s.Disks[0].SizeGiB})
	}
	cp, worker := infra.Size{Cores: 2, MemoryMiB: 8192}, infra.Size{Cores: 4, MemoryMiB: 16384}
	want := []vm{
		{"cartography-cp-1", "10.20.0.60", cp, 32},
		{"cartography-general-1", "10.20.0.61", worker, 64},
		{"cartography-general-2", "10.20.0.62", worker, 64},
		{"cartography-general-3", "10.20.0.63", worker, 64},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("specs = %+v\nwant %+v", got, want)
	}
}

// fakeRepo makes a directory tree that passes for the repository, with the
// named clusters' config files holding the given text, and returns its root.
func fakeRepo(t *testing.T, clusters map[string]string) string {
	t.Helper()
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "go.mod"), []byte("module "+repoModule+"\n\ngo 1.25\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	for name, text := range clusters {
		dir := filepath.Join(root, clusterConfigDir, name)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, clusterConfigFile), []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// runCommand runs cmd -cluster name with no environment. restart needs a
// kubectl and a talosctl to get as far as the endpoint check, and CI has
// neither.
func runCommand(cmd, cluster string) error {
	args := []string{cmd, "-cluster", cluster}
	if cmd == "restart" {
		args = append(args, "-kubectl", "/bin/true", "-talosctl", "/bin/true")
	}
	return run(context.Background(), args, io.Discard, io.Discard, env(nil))
}

// -cluster alone reads the cluster's file, from anywhere in the repository. The
// file's address shows it was read: the defaults would pass.
func TestClusterConfigIsTheDefault(t *testing.T) {
	root := fakeRepo(t, map[string]string{"lab": `{"firstAddress":"10.20.0.45"}`})
	sub := filepath.Join(root, "providers")
	if err := os.MkdirAll(sub, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, wd := range []string{root, sub} {
		t.Chdir(wd)
		for _, cmd := range []string{"create", "resize"} {
			if err := runCommand(cmd, "lab"); err == nil || !strings.Contains(err.Error(), "reserved (ingress)") {
				t.Errorf("%s from %s: err = %v, want the file's address refused", cmd, wd, err)
			}
		}
	}
}

// create and resize refuse a cluster with no file, naming the path, from
// anywhere in the repository; the commands that only find a cluster's VMs go
// on to the next check, the endpoint, without it. Reaching PROXMOX_URL shows
// that they got past the config, without any request being sent.
func TestMissingClusterConfig(t *testing.T) {
	root := fakeRepo(t, nil)
	sub := filepath.Join(root, "providers", "talos", "patches")
	if err := os.MkdirAll(sub, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, clusterConfigDir, "nosuch", clusterConfigFile)
	for _, wd := range []string{root, sub} {
		t.Chdir(wd)
		for _, cmd := range []string{"create", "resize"} {
			err := runCommand(cmd, "nosuch")
			if err == nil || !strings.Contains(err.Error(), path) || !strings.Contains(err.Error(), "-config") {
				t.Errorf("%s from %s: err = %v, want it to name %s and -config", cmd, wd, err, path)
			}
		}
		for _, cmd := range []string{"list", "restart", "destroy"} {
			if err := runCommand(cmd, "nosuch"); err == nil || !strings.Contains(err.Error(), "PROXMOX_URL") {
				t.Errorf("%s from %s: err = %v, want it to reach the endpoint check", cmd, wd, err)
			}
		}
	}
}

// Outside the repository there is no file to find: create and resize say so,
// and the others go on, as they do for a cluster with no file.
func TestNoRepositoryRoot(t *testing.T) {
	t.Chdir(t.TempDir())
	for _, cmd := range []string{"create", "resize"} {
		err := runCommand(cmd, "treasury")
		if err == nil || !strings.Contains(err.Error(), "no go.mod for "+repoModule) {
			t.Errorf("%s: err = %v, want it to say the repository root was not found", cmd, err)
		}
	}
	for _, cmd := range []string{"list", "restart", "destroy"} {
		if err := runCommand(cmd, "treasury"); err == nil || !strings.Contains(err.Error(), "PROXMOX_URL") {
			t.Errorf("%s: err = %v, want it to reach the endpoint check", cmd, err)
		}
	}
	// A -config needs no repository.
	file := filepath.Join(t.TempDir(), "talosvm.json")
	if err := os.WriteFile(file, []byte(`{"cluster":"treasury"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	err := run(context.Background(), []string{"create", "-config", file}, io.Discard, io.Discard, env(nil))
	if err == nil || !strings.Contains(err.Error(), "PROXMOX_URL") {
		t.Errorf("create -config: err = %v, want it to reach the endpoint check", err)
	}
}

// A name that is not a cluster name never becomes a path. The malformed files
// sit where the name would lead if it did, so reading one would fail with the
// file's path instead of the check each command should reach.
func TestClusterNameIsNotAPath(t *testing.T) {
	root := fakeRepo(t, nil)
	t.Chdir(root)
	for _, rel := range []string{"providers/x", "providers/talos", "providers/talos/clusters"} {
		dir := filepath.Join(root, rel)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, clusterConfigFile), []byte("not json"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"../../x", ".", "..", "treasury/../.."} {
		for _, cmd := range []string{"create", "resize"} {
			err := runCommand(cmd, name)
			if err == nil || !strings.Contains(err.Error(), "want a lowercase DNS label") {
				t.Errorf("%s -cluster %q: err = %v, want the cluster name refused", cmd, name, err)
			}
		}
		for _, cmd := range []string{"list", "restart", "destroy"} {
			if err := runCommand(cmd, name); err == nil || !strings.Contains(err.Error(), "PROXMOX_URL") {
				t.Errorf("%s -cluster %q: err = %v, want it to reach the endpoint check", cmd, name, err)
			}
		}
	}
}

// A file that is there but bad stops every command: only a missing file is
// passed over, so a broken config cannot quietly become the defaults.
func TestBadClusterConfig(t *testing.T) {
	for name, text := range map[string]string{"malformed": "not json", "unknown": `{"clustr":"unknown"}`, "empty": ""} {
		root := fakeRepo(t, map[string]string{name: text})
		t.Chdir(root)
		path := filepath.Join(root, clusterConfigDir, name, clusterConfigFile)
		for _, cmd := range []string{"create", "resize", "list", "restart", "destroy"} {
			if err := runCommand(cmd, name); err == nil || !strings.Contains(err.Error(), path) {
				t.Errorf("%s %s: err = %v, want it to name %s", cmd, name, err, path)
			}
		}
	}
	// A directory where the file should be is unreadable, not missing.
	root := fakeRepo(t, nil)
	t.Chdir(root)
	if err := os.MkdirAll(filepath.Join(root, clusterConfigDir, "dir", clusterConfigFile), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := runCommand("list", "dir"); err == nil || strings.Contains(err.Error(), "PROXMOX_URL") {
		t.Errorf("list dir: err = %v, want the read refused", err)
	}
}

// -config wins over the cluster's file, and a missing -config stays an error
// for every command, which the default path is not.
func TestExplicitConfig(t *testing.T) {
	root := fakeRepo(t, map[string]string{"lab": "not json"})
	t.Chdir(root)
	good := filepath.Join(root, "good.json")
	if err := os.WriteFile(good, []byte(`{"firstAddress":"10.20.0.60"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	err := run(context.Background(), []string{"create", "-cluster", "lab", "-config", good}, io.Discard, io.Discard, env(nil))
	if err == nil || !strings.Contains(err.Error(), "PROXMOX_URL") {
		t.Errorf("-config over a bad cluster file: err = %v, want it to reach the endpoint check", err)
	}
	for _, cmd := range []string{"create", "resize", "list", "restart", "destroy"} {
		err := run(context.Background(), []string{cmd, "-cluster", "lab", "-config", "/nonexistent/talosvm.json"}, io.Discard, io.Discard, env(nil))
		if err == nil || !strings.Contains(err.Error(), "no such file") {
			t.Errorf("%s: err = %v, want the missing -config refused", cmd, err)
		}
	}
}

// The root is the nearest go.mod of this module, whatever other modules' go.mod
// files lie between it and the working directory.
func TestRepoRoot(t *testing.T) {
	root := fakeRepo(t, nil)
	nested := filepath.Join(root, "spike", "tool")
	if err := os.MkdirAll(nested, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "spike", "go.mod"), []byte("module example.com/spike\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, ok := repoRoot(nested); !ok || got != root {
		t.Errorf("repoRoot(%s) = %q, %v, want %q", nested, got, ok, root)
	}
	if got, ok := repoRoot(t.TempDir()); ok {
		t.Errorf("repoRoot outside the repository = %q", got)
	}
	for _, tc := range []struct {
		text string
		want bool
	}{
		{"module go.holos.run/distro\n", true},
		{"// a comment\n\nmodule \"go.holos.run/distro\"\n", true},
		{"module go.holos.run/distro // the distro\n", true},
		{"module go.holos.run/distro/sub\n", false},
		{"// module go.holos.run/distro\nmodule other\n", false},
		{"", false},
	} {
		if got := declaresModule([]byte(tc.text), repoModule); got != tc.want {
			t.Errorf("declaresModule(%q) = %v, want %v", tc.text, got, tc.want)
		}
	}
}
