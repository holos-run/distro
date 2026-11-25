package talos

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// A cluster's etcd snapshot drop-in repeats its Talos version and its control
// plane's address, and a Talos upgrade that changed only talosvm.json would
// leave the timer on the old talosctl.
func TestEtcdSnapshotDropIns(t *testing.T) {
	const pattern = "systemd/etcd-snapshot@*.service.d"
	dirs, err := filepath.Glob(pattern)
	if err != nil || len(dirs) == 0 {
		t.Fatalf("%s: %v, %v", pattern, dirs, err)
	}
	name := regexp.MustCompile(`@(.+)\.service\.d$`)
	for _, dir := range dirs {
		cluster := name.FindStringSubmatch(dir)[1]
		dropIn, err := os.ReadFile(filepath.Join(dir, "cluster.conf"))
		if err != nil {
			t.Fatal(err)
		}
		raw, err := os.ReadFile(filepath.Join("clusters", cluster, "talosvm.json"))
		if err != nil {
			t.Fatal(err)
		}
		c := Default()
		if err := json.Unmarshal(raw, &c); err != nil {
			t.Fatal(err)
		}
		lines := strings.Split(string(dropIn), "\n")
		for _, want := range []string{
			"Environment=ETCD_SNAPSHOT_TALOSCTL=%h/.local/bin/talosctl-" + c.TalosVersion,
			"Environment=ETCD_SNAPSHOT_NODE=" + c.FirstAddress,
		} {
			if !slices.Contains(lines, want) {
				t.Errorf("%s/cluster.conf does not set %q", dir, want)
			}
		}
	}
}
