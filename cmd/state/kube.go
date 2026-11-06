package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os/exec"
	"strings"
)

// lastApplied holds a copy of the object, and is kubectl's rather than state.
const lastApplied = "kubectl.kubernetes.io/last-applied-configuration"

// errAlreadyExists reports a create that lost a race, or a namespace that
// appeared after it was checked.
var errAlreadyExists = errors.New("already exists")

// metadata is the allow-list of what comes back from a Secret: uid,
// resourceVersion, managedFields and the rest stay behind, since they belong
// to the object on the old cluster. Labels and annotations are kept because
// they mean something. cert-manager finds the root's Secret by the label
// controller.cert-manager.io/fao, and the Secrets Manager lists a platform
// secret by its managed-by label and holos.run/share-roles.
type metadata struct {
	Name        string            `json:"name"`
	Namespace   string            `json:"namespace"`
	Labels      map[string]string `json:"labels,omitempty"`
	Annotations map[string]string `json:"annotations,omitempty"`
}

// secret is the part of a Kubernetes Secret that survives a rebuild. Decoding
// kubectl's JSON into it is what applies the allow-list.
type secret struct {
	APIVersion string            `json:"apiVersion"`
	Kind       string            `json:"kind"`
	Metadata   metadata          `json:"metadata"`
	Type       string            `json:"type,omitempty"`
	Immutable  *bool             `json:"immutable,omitempty"`
	Data       map[string][]byte `json:"data,omitempty"`
}

func (s *secret) id() identity {
	return identity{s.Metadata.Namespace, s.Metadata.Name}
}

// sameContent compares what a Secret holds, not how it is labelled: a key
// entered again by hand carries the same value under different metadata.
func sameContent(a, b *secret) bool {
	return a.Type == b.Type && maps.EqualFunc(a.Data, b.Data, bytes.Equal)
}

// kube is the cluster half of the program.
type kube interface {
	// clusterName returns the name of the cluster the kubeconfig selects.
	clusterName(ctx context.Context) (string, error)
	// getSecret returns the Secret, or nil when it or its namespace does not
	// exist. Any other failure is an error, so an API that cannot be reached
	// never reads as a Secret that is missing.
	getSecret(ctx context.Context, namespace, name string) (*secret, error)
	// namespacePhase returns the namespace's status.phase, or "" when it does
	// not exist.
	namespacePhase(ctx context.Context, name string) (string, error)
	// createNamespace returns errAlreadyExists when it lost a race.
	createNamespace(ctx context.Context, name string) error
	createSecret(ctx context.Context, s *secret) error
	replaceSecret(ctx context.Context, s *secret) error
}

// kubectl runs kubectl, so the program needs no Kubernetes client library.
// Secret values go to it on stdin, never in its arguments. --kubeconfig is
// always passed, so the shell's KUBECONFIG is never read.
type kubectl struct {
	kubeconfig string
}

func (k *kubectl) run(ctx context.Context, stdin []byte, args ...string) ([]byte, error) {
	full := append([]string{"--kubeconfig", k.kubeconfig, "--request-timeout=30s"}, args...)
	cmd := exec.CommandContext(ctx, "kubectl", full...)
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		switch {
		case strings.Contains(msg, "(NotFound)"):
			return nil, fmt.Errorf("%w: kubectl %s: %s", errNotFound, strings.Join(args, " "), msg)
		case strings.Contains(msg, "(AlreadyExists)"):
			return nil, fmt.Errorf("%w: kubectl %s: %s", errAlreadyExists, strings.Join(args, " "), msg)
		}
		return nil, fmt.Errorf("kubectl %s: %w: %s", strings.Join(args, " "), err, msg)
	}
	return stdout.Bytes(), nil
}

// errNotFound reports an object kubectl says does not exist. A Secret whose
// namespace does not exist reports the same way, which is what save wants: a
// resource that is not there, whatever the reason.
var errNotFound = errors.New("not found")

func (k *kubectl) clusterName(ctx context.Context) (string, error) {
	out, err := k.run(ctx, nil, "config", "view", "--minify", "-o", "jsonpath={.clusters[0].name}")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func (k *kubectl) getSecret(ctx context.Context, namespace, name string) (*secret, error) {
	out, err := k.run(ctx, nil, "-n", namespace, "get", "secret", name, "-o", "json")
	if errors.Is(err, errNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var s secret
	if err := json.Unmarshal(out, &s); err != nil {
		return nil, fmt.Errorf("decoding Secret %s/%s", namespace, name)
	}
	delete(s.Metadata.Annotations, lastApplied)
	if len(s.Metadata.Annotations) == 0 {
		s.Metadata.Annotations = nil
	}
	return &s, nil
}

func (k *kubectl) namespacePhase(ctx context.Context, name string) (string, error) {
	out, err := k.run(ctx, nil, "get", "namespace", name, "-o", "jsonpath={.status.phase}")
	if errors.Is(err, errNotFound) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func (k *kubectl) createNamespace(ctx context.Context, name string) error {
	_, err := k.run(ctx, nil, "create", "namespace", name)
	return err
}

func (k *kubectl) createSecret(ctx context.Context, s *secret) error {
	return k.applySecret(ctx, s, "create")
}

func (k *kubectl) replaceSecret(ctx context.Context, s *secret) error {
	return k.applySecret(ctx, s, "replace")
}

func (k *kubectl) applySecret(ctx context.Context, s *secret, verb string) error {
	manifest, err := json.Marshal(s)
	if err != nil {
		return err
	}
	if _, err := k.run(ctx, manifest, verb, "-f", "-"); err != nil {
		return fmt.Errorf("%s Secret %s: %w", verb, s.id(), err)
	}
	return nil
}
