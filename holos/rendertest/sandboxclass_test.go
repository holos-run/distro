package rendertest

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// toolsVar is the environment variable that runs TestClaimSandboxClass, which
// CI's Render job sets: that job has cue and holos on PATH and the Substrate
// submodules checked out, which the test needs and the Go job does not have.
const toolsVar = "RENDERTEST_TOOLS"

// claimFile and bindingFile are a claim and its Planboard binding the test adds
// to a copy of the collections, never to the tree: a claim that asks for a
// class its cluster does not run would fail every render, and one that does
// would render a project nobody asked for.
const (
	claimFile   = "sandbox-class-test.cue"
	bindingFile = "sandbox-class-test-planboard.cue"
)

// claim is the test's claim on cluster, with runtime, which is CUE or empty.
func claim(cluster, runtime string) string {
	return `package projects

projects: "sandbox-class-test": {
	clusterSelector: matchLabels: "holos.run/cluster-name": "` + cluster + `"
	owners: "sandbox-owner@bank.internal": _
	` + runtime + `
}
`
}

// binding binds Planboard to the test's claim.
const binding = `package bindings

bindings: "sandbox-class-test-planboard": {
	project: "sandbox-class-test"
	productRefs: [{name: "planboard"}]
}
`

// module is a copy of the CUE module in holos/ with the test's claim and
// binding: every entry of holos/ but projects/, bindings/ and deploy/ is a link
// to the original, and projects/ and bindings/ directories of their own,
// holding copies of the collection's files and the test's.
func module(t *testing.T, test string) string {
	t.Helper()
	src, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	entries, err := os.ReadDir(src)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		switch e.Name() {
		case "projects", "bindings", "deploy":
			continue
		}
		if err := os.Symlink(filepath.Join(src, e.Name()), filepath.Join(dir, e.Name())); err != nil {
			t.Fatal(err)
		}
	}
	for collection, extra := range map[string][2]string{
		"projects": {claimFile, test},
		"bindings": {bindingFile, binding},
	} {
		dst := filepath.Join(dir, collection)
		if err := os.Mkdir(dst, 0o755); err != nil {
			t.Fatal(err)
		}
		files, err := filepath.Glob(filepath.Join(src, collection, "*.cue"))
		if err != nil {
			t.Fatal(err)
		}
		for _, path := range files {
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dst, filepath.Base(path)), data, 0o644); err != nil {
				t.Fatal(err)
			}
		}
		if err := os.WriteFile(filepath.Join(dst, extra[0]), []byte(extra[1]), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// requireTools fails the test unless cue and holos are on PATH and every
// Substrate submodule under holos/vendor is checked out, since the substrate
// component renders from it and an empty one would fail for another reason.
func requireTools(t *testing.T) {
	t.Helper()
	for _, tool := range []string{"cue", "holos"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Fatalf("%s=1 but %s is not on PATH", toolsVar, tool)
		}
	}
	trees, err := filepath.Glob(filepath.Join("..", "vendor", "substrate-*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(trees) == 0 {
		t.Fatalf("%s=1 but holos/vendor holds no substrate-* submodule", toolsVar)
	}
	for _, tree := range trees {
		entries, err := os.ReadDir(tree)
		if err != nil {
			t.Fatal(err)
		}
		if len(entries) == 0 {
			t.Fatalf("%s=1 but %s is empty: run git submodule update --init", toolsVar, tree)
		}
	}
}

// run runs a command in dir, and returns its combined output and error.
func run(dir string, args ...string) (string, error) {
	var out bytes.Buffer
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Dir = dir
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	return out.String(), err
}

// TestClaimSandboxClass checks that a claim may ask only for a sandbox class
// each of its clusters runs (claimSandboxClasses, collections.cue): microvm on
// treasury, which runs gVisor alone, fails cue vet at the root, which CI's
// Render job runs first, and holos's render of the claim's own component,
// project-<claim>, and of its binding's, product-planboard-<claim>, each with
// the claim, the class and the cluster in the message. The product's matters
// because a render of that component alone, holos render platform --selector
// component=product-planboard-<claim>, would otherwise write a microvm pool
// into the cluster's tree. The renders are holos's, not cue export's: cue fails
// on an error anywhere in the instance, holos only on one in what it renders,
// so only holos shows that each component folds the check into what it
// renders. On marina, which runs the class, all three pass, as they do for a
// claim on treasury that says nothing and so takes gvisor.
//
// It runs only with RENDERTEST_TOOLS=1, which CI's Render job sets, and then
// fails without cue, holos or a checked-out Substrate submodule; without the
// variable it is skipped, as in CI's Go job, which has none of them.
func TestClaimSandboxClass(t *testing.T) {
	if os.Getenv(toolsVar) != "1" {
		t.Skipf("set %s=1 to run it, with cue and holos on PATH and the Substrate submodules checked out", toolsVar)
	}
	requireTools(t)
	const message = `claim sandbox-class-test asks for sandbox class microvm, which cluster treasury does not run: its sandboxClasses are gvisor (clusters.cue)`
	for _, tc := range []struct {
		name    string
		cluster string
		runtime string
		fails   bool
	}{
		{name: "microvm on treasury", cluster: "treasury", runtime: `runtime: sandboxClass: "microvm"`, fails: true},
		{name: "microvm on marina", cluster: "marina", runtime: `runtime: sandboxClass: "microvm"`},
		{name: "default on treasury", cluster: "treasury"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := module(t, claim(tc.cluster, tc.runtime))
			for _, args := range [][]string{
				{"cue", "vet", "."},
				{"holos", "render", "component", "./components/project",
					"-t", "project=sandbox-class-test", "-t", "clusterName=" + tc.cluster,
					"--write-to", t.TempDir()},
				{"holos", "render", "component", "./components/product-planboard",
					"-t", "project=sandbox-class-test", "-t", "product=planboard", "-t", "clusterName=" + tc.cluster,
					"--write-to", t.TempDir()},
			} {
				out, err := run(dir, args...)
				command := strings.Join(args[:min(len(args), 4)], " ")
				switch {
				case tc.fails && err == nil:
					t.Errorf("%s: passed, want it to fail with %q", command, message)
				case tc.fails && !strings.Contains(out, message):
					t.Errorf("%s: failed without %q:\n%s", command, message, out)
				case !tc.fails && err != nil:
					t.Errorf("%s: %v:\n%s", command, err, out)
				}
			}
		})
	}
}
