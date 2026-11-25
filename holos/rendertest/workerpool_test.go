// Package rendertest checks the rendered tree committed in holos/deploy, which
// CI's Render job checks is the render of the CUE beside it, for what the CUE
// alone cannot hold to.
package rendertest

import (
	"bytes"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
)

// classLabel is the admin label of a node pool reserved for one sandbox class,
// which only the cluster's admin can set: the node restriction admission plugin
// refuses it from the node's own kubelet.
const classLabel = "node-restriction.kubernetes.io/sandbox-class"

type workerPool struct {
	Kind     string `yaml:"kind"`
	Metadata struct {
		Name      string `yaml:"name"`
		Namespace string `yaml:"namespace"`
	} `yaml:"metadata"`
	Spec struct {
		SandboxClasses []struct {
			Name string `yaml:"name"`
		} `yaml:"sandboxClasses"`
		Template struct {
			NodeSelector map[string]string `yaml:"nodeSelector"`
		} `yaml:"template"`
	} `yaml:"spec"`
}

// TestMicroVMPoolsSelectTheClassLabel checks that every WorkerPool of the
// microvm class selects its nodes by the class's admin label alone.
// ate-controller places a microVM worker by the ate.dev/kvm resource, which
// atelet advertises on every node with /dev/kvm, the general workers too, so
// a pool that selected holos.run/nodepool, which a node sets on itself, or
// nothing, could put its workers off the microvm nodes.
func TestMicroVMPoolsSelectTheClassLabel(t *testing.T) {
	root := filepath.Join("..", "deploy", "clusters")
	found := map[string]int{}
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".yaml") {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if !bytes.Contains(data, []byte("kind: WorkerPool")) {
			return nil
		}
		dec := yaml.NewDecoder(bytes.NewReader(data))
		for {
			var p workerPool
			if err := dec.Decode(&p); errors.Is(err, io.EOF) {
				return nil
			} else if err != nil {
				return err
			}
			if p.Kind != "WorkerPool" {
				continue
			}
			for _, c := range p.Spec.SandboxClasses {
				if c.Name != "microvm" {
					continue
				}
				cluster := strings.Split(filepath.ToSlash(strings.TrimPrefix(path, root+string(filepath.Separator))), "/")[0]
				found[cluster]++
				want := map[string]string{classLabel: "microvm"}
				got := p.Spec.Template.NodeSelector
				if len(got) != len(want) || got[classLabel] != want[classLabel] {
					t.Errorf("%s: WorkerPool %s/%s of class microvm selects %v, want %v alone",
						path, p.Metadata.Namespace, p.Metadata.Name, got, want)
				}
			}
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	// marina runs the class, so a tree with no pool of it read nothing.
	if found["marina"] == 0 {
		t.Errorf("no WorkerPool of class microvm in %s/marina", root)
	}
}
