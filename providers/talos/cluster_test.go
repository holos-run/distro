package talos

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// These tests run cluster.sh itself, from a copy with a config of their own,
// against stubs of go, talosctl and kubectl, so what they check is what it
// writes and calls. They need bash and jq, as the script does.

// inventory is what talosvm list -json gives for the cluster of these tests.
const inventory = `[
  {"name": "lab-cp-1", "vmid": 1, "region": "garage", "zone": "r620a", "role": "controlplane", "address": "10.20.0.90"},
  {"name": "lab-general-1", "vmid": 2, "region": "garage", "zone": "r620b", "role": "worker", "pool": "general", "address": "10.20.0.91"},
  {"name": "lab-microvm-1", "vmid": 3, "region": "garage", "zone": "r620a", "role": "worker", "pool": "microvm", "address": "10.20.0.92"},
  {"name": "lab-microvm-2", "vmid": 4, "region": "garage", "zone": "r620c", "role": "worker", "pool": "microvm", "address": "10.20.0.93"}
]
`

// microvm is the pool the README shows, as JSON fields.
const microvm = `"taints": ["ate.dev/sandboxClass=microvm:NoSchedule"],
  "labels": ["node.kubernetes.io/exclude-from-external-load-balancers="],
  "adminLabels": ["node-restriction.kubernetes.io/sandbox-class=microvm"]`

// stubs are the commands cluster.sh runs. kubectl keeps the cluster's nodes in
// nodes.json, gives a node its address only once kubectl has been asked for
// the nodes as often as the file joins says, and refuses to label a node named
// in the file unlabelled. sleep does not.
var stubs = map[string]string{
	"go": `cat "$STUB/inventory.json"`,
	"talosctl": `case "$1 $2" in
"version --client") echo "Talos v1.14.7" ;;
"gen secrets") echo secret >"$4" ;;
"gen config") while [[ $1 != --output ]]; do shift; done; touch "$2"/{controlplane.yaml,worker.yaml,talosconfig} ;;
"machineconfig patch") while [[ $1 != --output ]]; do shift; done; echo config >"$2" ;;
"kubeconfig "*) echo x >"$2" ;;
esac`,
	"kubectl": `echo "$*" >>"$STUB/kubectl.log"
[[ "$3 $4" != "get --raw" ]] || exit 0
[[ $1 == --kubeconfig && $2 == "$HOLOS_TALOS_DIR/lab/kubeconfig" && $3 == --request-timeout=* ]] || exit 9
shift 3
case "$1 $2" in
"get nodes")
  n=$(cat "$STUB/polls" 2>/dev/null || echo 0); n=$((n + 1)); echo $n >"$STUB/polls"
  [[ ! -e $STUB/down ]] || exit 1
  jq --argjson n $n '.items |= map(select((.joins // 0) <= $n))' "$STUB/nodes.json" ;;
"label node")
  [[ $3 != "$(cat "$STUB/unlabelled" 2>/dev/null)" ]] || exit 1
  [[ $4 == --overwrite ]] || exit 9
  node=$3; shift 4
  for kv; do
    jq --arg node "$node" --arg key "${kv%%=*}" --arg value "${kv#*=}" \
      '(.items[] | select(.metadata.name == $node) | .metadata.labels[$key]) = $value' "$STUB/nodes.json" >"$STUB/new.json"
    mv "$STUB/new.json" "$STUB/nodes.json"
  done ;;
*) exit 9 ;;
esac`,
	"sleep": `echo "$*" >>"$STUB/sleep.log"`,
}

// clusterScript is cluster.sh for the cluster lab, whose pools are as given.
type clusterScript struct {
	t    *testing.T
	dir  string // the copy of the repository
	stub string // the stubs and what they keep
}

func newClusterScript(t *testing.T, config string) clusterScript {
	t.Helper()
	for _, tool := range []string{"bash", "jq"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s not found in PATH", tool)
		}
	}
	dir := t.TempDir()
	s := clusterScript{t, filepath.Join(dir, "repo"), filepath.Join(dir, "stub")}
	script, err := os.ReadFile("cluster.sh")
	if err != nil {
		t.Fatal(err)
	}
	s.write(filepath.Join(s.dir, "providers/talos/cluster.sh"), string(script))
	s.write(filepath.Join(s.dir, "providers/talos/clusters/lab/talosvm.json"), config)
	s.write(filepath.Join(s.stub, "inventory.json"), inventory)
	for name, body := range stubs {
		s.write(filepath.Join(s.stub, "bin", name), "#!/usr/bin/env bash\nset -euo pipefail\n"+body+"\n")
	}
	return s
}

func (s clusterScript) write(path, data string) {
	s.t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		s.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o700); err != nil {
		s.t.Fatal(err)
	}
}

// state is a file of the cluster's state directory.
func (s clusterScript) state(name string) string {
	return filepath.Join(s.stub, "state/lab", name)
}

func (s clusterScript) read(path string) string {
	s.t.Helper()
	b, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		s.t.Fatal(err)
	}
	return string(b)
}

// run runs one command of the script and returns what it logs.
func (s clusterScript) run(command string) (string, error) {
	cmd := exec.Command("bash", filepath.Join(s.dir, "providers/talos/cluster.sh"), command, "lab")
	cmd.Env = append(os.Environ(),
		"PATH="+filepath.Join(s.stub, "bin")+":"+os.Getenv("PATH"),
		"STUB="+s.stub, "HOLOS_TALOS_DIR="+filepath.Join(s.stub, "state"),
		"TALOSCTL=talosctl", "INSTALLER=example.com/installer:v1", "KUBECONFIG=/nonexistent")
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// labConfig is the config of lab, with fields added to its microVM pool.
func labConfig(fields string) string {
	if fields != "" {
		fields = ", " + fields
	}
	return `{"cluster": "lab", "talosVersion": "v1.14.7", "firstAddress": "10.20.0.90", "pools": [
  {"name": "general", "count": 1, "cores": 4, "memoryMiB": 16384, "diskGiB": 64},
  {"name": "microvm", "count": 2, "cores": 8, "memoryMiB": 16384, "diskGiB": 100, "nodes": ["r620a", "r620c"]` + fields + `}
]}`
}

// The patch of each node, with and without each list. Without any, it is what
// the script wrote before pools had them.
func TestClusterScriptNodePatch(t *testing.T) {
	base := func(zone, pool string) string {
		p := "apiVersion: v1alpha1\nkind: KubeNodeConfig\nlabels:\n  topology.kubernetes.io/region: \"garage\"\n  topology.kubernetes.io/zone: \"" + zone + "\"\n"
		if pool != "" {
			p += "  holos.run/nodepool: \"" + pool + "\"\n"
		}
		return p
	}
	const (
		label  = "  \"node.kubernetes.io/exclude-from-external-load-balancers\": \"\"\n"
		kubelt = "---\napiVersion: v1alpha1\nkind: KubeletConfig\nconfig:\n  registerWithTaints:\n"
		taint  = "    - key: \"ate.dev/sandboxClass\"\n      value: \"microvm\"\n      effect: \"NoSchedule\"\n"
	)
	for _, tc := range []struct{ name, fields, want string }{
		{"none", "", ""},
		{"empty", `"taints": [], "labels": null, "adminLabels": []`, ""},
		{"taints", `"taints": ["ate.dev/sandboxClass=microvm:NoSchedule"]`, kubelt + taint},
		{"labels", `"labels": ["node.kubernetes.io/exclude-from-external-load-balancers"]`, label},
		{"adminLabels", `"adminLabels": ["node-restriction.kubernetes.io/sandbox-class=microvm"]`, ""},
		{"all", microvm, label + kubelt + taint},
		{"several", `"labels": ["example.com/a=true", "b=1"], "taints": ["a:NoExecute", "a=:NoSchedule"]`,
			"  \"example.com/a\": \"true\"\n  \"b\": \"1\"\n" + kubelt +
				"    - key: \"a\"\n      value: \"\"\n      effect: \"NoExecute\"\n" +
				"    - key: \"a\"\n      value: \"\"\n      effect: \"NoSchedule\"\n"},
	} {
		s := newClusterScript(t, labConfig(tc.fields))
		if out, err := s.run("gen"); err != nil {
			t.Fatalf("%s: %v\n%s", tc.name, err, out)
		}
		for node, want := range map[string]string{
			"lab-cp-1":      base("r620a", ""),
			"lab-general-1": base("r620b", "general"),
			"lab-microvm-1": base("r620a", "microvm") + tc.want,
			"lab-microvm-2": base("r620c", "microvm") + tc.want,
		} {
			if got := s.read(s.state("nodes/" + node + ".patch.yaml")); got != want {
				t.Errorf("%s: %s =\n%s\nwant\n%s", tc.name, node, got, want)
			}
		}
	}
}

// What talosctl makes of the microVM pool's patch: the labels beside those
// gen always writes, the taint in the kubelet's configuration, and the rest of
// both documents kept. It needs the talosctl of Marina's version, the first
// with such a pool, and is skipped without it.
func TestClusterScriptTalosctl(t *testing.T) {
	const version = "v1.14.7"
	talosctl, err := exec.LookPath("talosctl-" + version)
	if err != nil {
		t.Skip(err)
	}
	s := newClusterScript(t, labConfig(microvm))
	s.write(filepath.Join(s.stub, "bin/talosctl"), "#!/usr/bin/env bash\nexec "+talosctl+" \"$@\"\n")
	for _, patch := range []string{"all.yaml", "controlplane.yaml"} {
		s.write(filepath.Join(s.dir, "providers/talos/patches", patch), s.read(filepath.Join("patches", patch)))
	}
	if out, err := s.run("gen"); err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	docs := func(node string) map[string]string {
		m := map[string]string{}
		for _, d := range strings.Split(s.read(s.state("nodes/"+node+".yaml")), "\n---\n") {
			d = strings.TrimSpace(d) + "\n"
			for _, kind := range []string{"KubeNodeConfig", "KubeletConfig"} {
				if strings.Contains(d, "kind: "+kind+"\n") {
					m[kind] += d
				}
			}
		}
		return m
	}
	for kind, want := range map[string]string{
		"KubeNodeConfig": `apiVersion: v1alpha1
kind: KubeNodeConfig
nodeIP: {}
labels:
    holos.run/nodepool: microvm
    node.kubernetes.io/exclude-from-external-load-balancers: ""
    topology.kubernetes.io/region: garage
    topology.kubernetes.io/zone: r620a
`,
		"KubeletConfig": `apiVersion: v1alpha1
kind: KubeletConfig
image: ghcr.io/siderolabs/kubelet:v1.37.1
config:
    registerWithTaints:
        - effect: NoSchedule
          key: ate.dev/sandboxClass
          value: microvm
defaultRuntimeSeccompProfileEnabled: true
`,
	} {
		if got := docs("lab-microvm-1")[kind]; got != want {
			t.Errorf("%s =\n%s\nwant\n%s", kind, got, want)
		}
	}
	if got := docs("lab-general-1")["KubeletConfig"]; strings.Contains(got, "registerWithTaints") {
		t.Errorf("general node has taints:\n%s", got)
	}
}

// poolCases are values of a pool's lists, and whether they are accepted. The
// same go through Validate and cluster.sh.
var poolCases = []struct {
	field   string
	entries []string
	want    string // part of the refusal, or "" when accepted
}{
	{"taints", []string{"ate.dev/sandboxClass=microvm:NoSchedule"}, ""},
	{"taints", []string{"a:NoExecute", "a=:PreferNoSchedule", "a.b/C_d.e-f=1:NoSchedule"}, ""},
	{"taints", []string{"a=b:NoSchedule", "a=c:NoExecute"}, ""},
	{"taints", []string{"xPrefer:NoSchedule", "x:PreferNoSchedule"}, ""},
	{"taints", []string{"a=b:NoSchedule", "a=c:NoSchedule"}, "twice"},
	{"taints", []string{"a=b:NoSchedule", "a:NoSchedule"}, "twice"},
	{"taints", []string{""}, "want a taint"},
	{"taints", []string{"a"}, "want a taint"},
	{"taints", []string{"a=b"}, "want a taint"},
	{"taints", []string{"a=b:noschedule"}, "want a taint"},
	{"taints", []string{"a=b:NoSchedule:"}, "want a taint"},
	{"taints", []string{"a=b:NoSchedule\n"}, "want a taint"},
	{"taints", []string{"a=b c:NoSchedule"}, "want a taint"},
	{"taints", []string{"=b:NoSchedule"}, "want a taint"},
	{"taints", []string{"a=b=c:NoSchedule"}, "want a taint"},
	{"taints", []string{"A.b/c=d:NoSchedule"}, "want a taint"},
	{"taints", []string{"a/b/c=d:NoSchedule"}, "want a taint"},
	{"taints", []string{"$(id)=d:NoSchedule"}, "want a taint"},
	{"taints", []string{"a=" + strings.Repeat("b", 63) + ":NoSchedule"}, ""},
	{"taints", []string{"a=" + strings.Repeat("b", 64) + ":NoSchedule"}, "want a taint"},
	{"taints", []string{strings.Repeat(strings.Repeat("a", 60)+".", 5) + "a/b:NoSchedule"}, "want a taint"},
	{"labels", []string{"node.kubernetes.io/exclude-from-external-load-balancers"}, ""},
	{"labels", []string{"node.kubernetes.io/exclude-from-external-load-balancers=", "a=b", "x.kubelet.kubernetes.io/a=b", "holos.run/a=nodepool"}, ""},
	{"labels", []string{"a=b", "a=c"}, "twice"},
	{"labels", []string{"a", "a=c"}, "twice"},
	{"labels", []string{"a=b", "b=a", "a="}, "twice"},
	{"labels", []string{""}, "want a label"},
	{"labels", []string{"a=b\n"}, "want a label"},
	{"labels", []string{"a=b:NoSchedule"}, "want a label"},
	{"labels", []string{"a-"}, "want a label"},
	{"labels", []string{"a=b c"}, "want a label"},
	{"labels", []string{"a: b"}, "want a label"},
	{"labels", []string{"a=é"}, "want a label"},
	{"labels", []string{"holos.run/nodepool=general"}, "cluster.sh sets this label"},
	{"labels", []string{"holos.run/nodepool"}, "cluster.sh sets this label"},
	{"labels", []string{"topology.kubernetes.io/zone=r620a"}, "Kubernetes keeps this label"},
	{"labels", []string{"topology.kubernetes.io/region="}, "Kubernetes keeps this label"},
	{"labels", []string{"node-role.kubernetes.io/worker"}, "Kubernetes keeps this label"},
	{"labels", []string{"kubernetes.io/hostname=a"}, "Kubernetes keeps this label"},
	{"labels", []string{"x.k8s.io/a=b"}, "Kubernetes keeps this label"},
	{"labels", []string{"notkubernetes.io/a=b"}, ""},
	{"labels", []string{"node-restriction.kubernetes.io/sandbox-class=microvm"}, "put it in adminLabels"},
	{"labels", []string{"a.node-restriction.kubernetes.io/b"}, "put it in adminLabels"},
	{"adminLabels", []string{"node-restriction.kubernetes.io/sandbox-class=microvm", "a.node-restriction.kubernetes.io/b"}, ""},
	{"adminLabels", []string{"node-restriction.kubernetes.io/a=b", "node-restriction.kubernetes.io/a=c"}, "twice"},
	{"adminLabels", []string{"node-restriction.kubernetes.io/a=b c"}, "want a label"},
	{"adminLabels", []string{"node-restriction.kubernetes.io/"}, "want a label"},
	{"adminLabels", []string{"-o=yaml"}, "want a label"},
	{"adminLabels", []string{"node-restriction.kubernetes.io/a-"}, "want a label"},
	{"adminLabels", []string{"sandbox-class=microvm"}, "since a node can set any other"},
	{"adminLabels", []string{"holos.run/nodepool=microvm"}, "since a node can set any other"},
	{"adminLabels", []string{"anode-restriction.kubernetes.io/a=b"}, "since a node can set any other"},
	{"adminLabels", []string{"node-restriction.kubernetes.io.example.com/a=b"}, "since a node can set any other"},
	{"adminLabels", []string{"topology.kubernetes.io/zone=r620a"}, "since a node can set any other"},
}

func TestPoolLists(t *testing.T) {
	for _, tc := range poolCases {
		c := treasury()
		p := &c.Pools[0]
		switch tc.field {
		case "taints":
			p.Taints = tc.entries
		case "labels":
			p.Labels = tc.entries
		case "adminLabels":
			p.AdminLabels = tc.entries
		}
		err := c.Validate(check)
		if (err == nil) != (tc.want == "") || err != nil && !(strings.Contains(err.Error(), tc.want) && strings.Contains(err.Error(), "pools[0]."+tc.field)) {
			t.Errorf("%s %q: %v, want %q", tc.field, tc.entries, err, tc.want)
		}
	}
}

// cluster.sh accepts and refuses the same.
func TestClusterScriptPoolLists(t *testing.T) {
	t.Parallel()
	for _, tc := range poolCases {
		entries, err := json.Marshal(tc.entries)
		if err != nil {
			t.Fatal(err)
		}
		s := newClusterScript(t, labConfig(fmt.Sprintf("%q: %s", tc.field, entries)))
		out, err := s.run("gen")
		if (err == nil) != (tc.want == "") || err != nil && !(strings.Contains(out, tc.want) && strings.Contains(out, "pools[1]."+tc.field)) {
			t.Errorf("%s %q: %v, want %q\n%s", tc.field, tc.entries, err, tc.want, out)
		}
		if err != nil && s.read(s.state("secrets.yaml")) != "" {
			t.Errorf("%s %q: refused after writing secrets", tc.field, tc.entries)
		}
	}
}

// A key or type cluster.sh would read otherwise than talosvm ends it, rather
// than leaving a pool untainted.
func TestClusterScriptPoolKeys(t *testing.T) {
	t.Parallel()
	replace := func(old, new string) string { return strings.Replace(labConfig(microvm), old, new, 1) }
	for _, tc := range []struct{ config, want string }{
		{replace(`"taints"`, `"Taints"`), "unknown key Taints"},
		{replace(`"taints"`, `"taint"`), "unknown key taint"},
		{replace(`"taints"`, "\"taintſ\""), "unknown key taint"},
		{replace(`"adminLabels"`, `"adminlabels"`), "unknown key adminlabels"},
		{replace(`"labels"`, `"LABELS"`), "unknown key LABELS"},
		{replace(`"name": "microvm"`, `"Name": "microvm"`), "want a pool with a name"},
		{replace(`"pools"`, `"Pools"`), "key Pools"},
		{replace(`"pools"`, "\"poolſ\""), "key pool"},
		{replace(`"microvm"`, `"general"`), "a name is used twice"},
		{replace(`"microvm"`, `""`), "pools[1].name \"\": want"},
		{replace(`"microvm"`, `"Microvm"`), "pools[1].name \"Microvm\": want"},
		{replace(`"microvm"`, `"micro_vm"`), "pools[1].name \"micro_vm\": want"},
		{replace(`"microvm"`, `"cp"`), "pools[1].name \"cp\": want"},
		{replace(`"microvm"`, `"microvm-microvm-micro"`), "pools[1].name \"microvm-microvm-micro\": want"},
		{replace(`"count": 2`, `"count": -1`), "pools[1].count -1: want"},
		{replace(`"count": 2`, `"count": "2"`), "pools[1].count \"2\": want"},
		{replace(`"count": 2`, `"count": false`), "pools[1].count false: want"},
		{`{"talosVersion": "v1.14.7", "pools": {}}`, "pools: want a list"},
		{`{"talosVersion": "v1.14.7", "pools": [null]}`, "pools[0]: want a pool"},
		{labConfig(`"taints": false`), "pools[1].taints: want a list"},
		{labConfig(`"taints": "a:NoSchedule"`), "pools[1].taints: want a list"},
		{labConfig(`"labels": {"a": "b"}`), "pools[1].labels: want a list"},
		{labConfig(`"labels": [null]`), "pools[1].labels[0] null: want a label"},
	} {
		for _, command := range []string{"gen", "labels"} {
			if out, err := newClusterScript(t, tc.config).run(command); err == nil || !strings.Contains(out, tc.want) {
				t.Errorf("%s: %v, want %q\n%s\n%s", command, err, tc.want, out, tc.config)
			}
		}
	}
}

// A worker in no pool of the config, as from a checkout without the pool, is
// refused before anything is written: it would register untainted.
func TestClusterScriptStrayWorker(t *testing.T) {
	t.Parallel()
	without := labConfig("")
	without = without[:strings.Index(without, ",\n  {\"name\": \"microvm\"")] + "\n]}"
	untagged := strings.Replace(inventory, `, "pool": "microvm", "address": "10.20.0.92"`, `, "address": "10.20.0.92"`, 1)
	for _, tc := range []struct{ name, config, inventory, want string }{
		{"pool not in the config", without, inventory, "lab-microvm-1 (microvm), lab-microvm-2 (microvm)"},
		{"another name", strings.Replace(labConfig(microvm), `"name": "microvm"`, `"name": "micro-vm"`, 1), inventory, "lab-microvm-1 (microvm)"},
		{"no pool", labConfig(microvm), untagged, "lab-microvm-1 (none)"},
		{"config without pools", `{"talosVersion": "v1.14.7"}`, inventory, ""},
	} {
		for _, command := range []string{"gen", "labels"} {
			s := newClusterScript(t, tc.config)
			s.write(filepath.Join(s.stub, "inventory.json"), tc.inventory)
			if command == "labels" {
				s.write(s.state("nodes.json"), tc.inventory)
				s.write(s.state("kubeconfig"), "x")
			}
			out, err := s.run(command)
			if (err == nil) != (tc.want == "") || !strings.Contains(out, tc.want) {
				t.Errorf("%s, %s: %v, want %q\n%s", tc.name, command, err, tc.want, out)
			}
			if err != nil && command == "gen" && (s.read(s.state("nodes.json")) != "" || s.read(s.state("secrets.yaml")) != "") {
				t.Errorf("%s: refused after writing", tc.name)
			}
		}
	}
}

// labNodes is the Kubernetes nodes of lab, as kubectl gives them, with edit
// made to each.
func labNodes(t *testing.T, edit func(name string, node, labels map[string]any)) string {
	t.Helper()
	var items []any
	for name, address := range map[string]string{"lab-cp-1": "10.20.0.90", "lab-general-1": "10.20.0.91", "lab-microvm-1": "10.20.0.92", "lab-microvm-2": "10.20.0.93"} {
		labels := map[string]any{"kubernetes.io/hostname": name}
		node := map[string]any{
			"metadata": map[string]any{"name": name, "labels": labels},
			"status":   map[string]any{"addresses": []any{map[string]string{"type": "InternalIP", "address": address}}},
		}
		if edit != nil {
			edit(name, node, labels)
		}
		items = append(items, node)
	}
	b, err := json.Marshal(map[string]any{"items": items})
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

const classLabel = "node-restriction.kubernetes.io/sandbox-class"

// The admin labels step: which nodes it labels, and what it reports.
func TestClusterScriptLabels(t *testing.T) {
	set := func(node string) string {
		return "label node " + node + " --overwrite " + classLabel + "=microvm"
	}
	one, two := set("lab-microvm-1"), set("lab-microvm-2")
	for _, tc := range []struct {
		name   string
		config string
		edit   func(name string, node, labels map[string]any)
		setup  func(s clusterScript)
		labels []string // the kubectl label calls
		log    []string
		fails  bool
		waits  int // the sleeps
	}{
		{name: "both nodes", labels: []string{one, two}, log: []string{"lab-microvm-1 has " + classLabel + "=microvm, lab-microvm-2 has " + classLabel + "=microvm"}},
		{name: "idempotent", edit: func(name string, _, labels map[string]any) { labels[classLabel] = "microvm" }},
		{name: "another value", edit: func(name string, _, labels map[string]any) {
			labels[classLabel] = "microvm"
			if name == "lab-microvm-2" {
				labels[classLabel] = "gvisor"
			}
		}, labels: []string{two}},
		{name: "no pool has any", config: labConfig(""), log: []string{"no pool sets adminLabels"}},
		{name: "joins late", edit: func(name string, node, _ map[string]any) {
			if name == "lab-microvm-2" {
				node["joins"] = 4
			}
		}, labels: []string{one, two}, log: []string{"waiting for nodes to join: lab-microvm-2"}, waits: 3},
		// The others get theirs, and the run fails.
		{name: "never joins", edit: func(name string, node, _ map[string]any) {
			if name == "lab-microvm-1" {
				node["joins"] = 1000
			}
		}, labels: []string{two}, log: []string{"lab-microvm-1 has not joined"}, fails: true, waits: 119},
		{name: "no address yet", edit: func(name string, node, _ map[string]any) {
			if name == "lab-microvm-1" {
				delete(node, "status")
			}
		}, labels: []string{two}, log: []string{"lab-microvm-1 has not joined"}, fails: true, waits: 119},
		{name: "label refused", setup: func(s clusterScript) { s.write(filepath.Join(s.stub, "unlabelled"), "lab-microvm-1") },
			labels: []string{one, two}, log: []string{"lab-microvm-1 lacks " + classLabel + "=microvm"}, fails: true},
		{name: "API down", setup: func(s clusterScript) { s.write(filepath.Join(s.stub, "down"), "") },
			log: []string{"cannot read the nodes back"}, fails: true, waits: 119},
		// Another cluster's nodes, of the same names.
		{name: "another cluster", edit: func(name string, node, _ map[string]any) {
			if name == "lab-microvm-2" {
				node["status"] = map[string]any{"addresses": []any{map[string]string{"type": "InternalIP", "address": "10.20.0.193"}}}
			}
		}, log: []string{"lab-microvm-2 is at 10.20.0.193, not 10.20.0.93"}, fails: true},
		{name: "node gen has not seen", config: strings.Replace(labConfig(microvm), `"count": 2`, `"count": 3`, 1),
			log: []string{"the inventory lacks nodes of pool microvm"}, fails: true},
		{name: "no inventory", setup: func(s clusterScript) { os.Remove(s.state("nodes.json")) }, log: []string{"no inventory"}, fails: true},
		{name: "no kubeconfig", setup: func(s clusterScript) { os.Remove(s.state("kubeconfig")) }, log: []string{"no kubeconfig"}, fails: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if tc.config == "" {
				tc.config = labConfig(microvm)
			}
			s := newClusterScript(t, tc.config)
			s.write(filepath.Join(s.stub, "nodes.json"), labNodes(t, tc.edit))
			s.write(s.state("nodes.json"), inventory)
			s.write(s.state("kubeconfig"), "x")
			if tc.setup != nil {
				tc.setup(s)
			}
			out, err := s.run("labels")
			if (err != nil) != tc.fails {
				t.Errorf("err = %v, want failure %t", err, tc.fails)
			}
			for _, want := range tc.log {
				if !strings.Contains(out, want) {
					t.Errorf("no %q", want)
				}
			}
			var got []string
			for _, l := range strings.Split(s.read(filepath.Join(s.stub, "kubectl.log")), "\n") {
				if _, call, ok := strings.Cut(l, "--request-timeout=30s "); ok && !strings.HasPrefix(call, "get ") {
					got = append(got, call)
				}
			}
			if !slices.Equal(got, tc.labels) {
				t.Errorf("kubectl calls = %q, want %q", got, tc.labels)
			}
			if got := strings.Count(s.read(filepath.Join(s.stub, "sleep.log")), "\n"); got != tc.waits {
				t.Errorf("%d waits, want %d", got, tc.waits)
			}
			if t.Failed() {
				t.Log(out)
			}
		})
	}
}

// up ends with the admin labels, once the API server answers.
func TestClusterScriptUp(t *testing.T) {
	s := newClusterScript(t, labConfig(microvm))
	s.write(filepath.Join(s.stub, "nodes.json"), labNodes(t, nil))
	out, err := s.run("up")
	if err != nil || !strings.HasSuffix(out, "lab-microvm-2 has "+classLabel+"=microvm\n") || strings.Count(s.read(filepath.Join(s.stub, "kubectl.log")), " label node ") != 2 {
		t.Errorf("up: %v\n%s", err, out)
	}
	// Without admin labels up asks kubectl for nothing more than it did.
	s = newClusterScript(t, labConfig(""))
	if out, err := s.run("up"); err != nil || strings.Contains(s.read(filepath.Join(s.stub, "kubectl.log")), "nodes") {
		t.Errorf("up without admin labels: %v\n%s", err, out)
	}
}
