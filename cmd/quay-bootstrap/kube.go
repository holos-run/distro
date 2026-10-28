package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
)

// Platform secrets carry the label the Secrets Manager lists Secrets by and
// its grant annotation, as the Ceph key bootstrap writes them (holos/README.md,
// Bootstrap Argo CD): platform owners own each one, so they see it under
// Platform and may read and share it.
const (
	managedByLabel = "app.kubernetes.io/managed-by"
	managedBy      = "holos.run"
	shareRoles     = "holos.run/share-roles"
	ownersGrant    = `[{"principal":"/platform/owners","role":"owner"}]`
)

// secret is the part of a Kubernetes Secret this program reads and writes.
type secret struct {
	namespace   string
	name        string
	typ         string
	data        map[string][]byte
	labels      map[string]string
	annotations map[string]string
}

// kube is the cluster half of the program. kubectl implements it; the tests
// use a fake.
type kube interface {
	// getSecret returns the Secret, or nil when it does not exist.
	getSecret(ctx context.Context, namespace, name string) (*secret, error)
	createSecret(ctx context.Context, s *secret) error
	// patchSecret merge-patches a Secret with a JSON body.
	patchSecret(ctx context.Context, namespace, name string, patch []byte) error
	// configMapValue returns one key of a ConfigMap.
	configMapValue(ctx context.Context, namespace, name, key string) (string, error)
}

// kubectl runs kubectl, so the program needs no Kubernetes client library and
// acts with whatever credentials and context kubectl would. Secret values go
// to it on stdin, never in its arguments.
type kubectl struct {
	// context, when set, is passed as --context.
	context string
}

func (k *kubectl) run(ctx context.Context, stdin []byte, args ...string) ([]byte, error) {
	if k.context != "" {
		args = append([]string{"--context", k.context}, args...)
	}
	cmd := exec.CommandContext(ctx, "kubectl", args...)
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("kubectl %s: %w: %s", strings.Join(redact(args), " "), err, strings.TrimSpace(stderr.String()))
	}
	return stdout.Bytes(), nil
}

// redact keeps an error message to the verb and the object: the arguments
// carry no secret, but a patch file path or a manifest might be long.
func redact(args []string) []string {
	if len(args) > 6 {
		return append(args[:6:6], "...")
	}
	return args
}

func (k *kubectl) currentContext(ctx context.Context) (string, error) {
	if k.context != "" {
		return k.context, nil
	}
	out, err := k.run(ctx, nil, "config", "current-context")
	return strings.TrimSpace(string(out)), err
}

func (k *kubectl) getSecret(ctx context.Context, namespace, name string) (*secret, error) {
	out, err := k.run(ctx, nil, "-n", namespace, "get", "secret", name, "-o", "json", "--ignore-not-found")
	if err != nil {
		return nil, err
	}
	if len(bytes.TrimSpace(out)) == 0 {
		return nil, nil
	}
	return decodeSecret(out)
}

func (k *kubectl) createSecret(ctx context.Context, s *secret) error {
	manifest, err := encodeSecret(s)
	if err != nil {
		return err
	}
	_, err = k.run(ctx, manifest, "create", "-f", "-")
	return err
}

func (k *kubectl) patchSecret(ctx context.Context, namespace, name string, patch []byte) error {
	_, err := k.run(ctx, patch, "-n", namespace, "patch", "secret", name, "--type=merge", "--patch-file=/dev/stdin")
	return err
}

func (k *kubectl) configMapValue(ctx context.Context, namespace, name, key string) (string, error) {
	path := "{.data." + strings.ReplaceAll(key, ".", `\.`) + "}"
	out, err := k.run(ctx, nil, "-n", namespace, "get", "configmap", name, "-o", "jsonpath="+path)
	if err != nil {
		return "", err
	}
	if len(out) == 0 {
		return "", fmt.Errorf("configmap %s/%s has no key %s", namespace, name, key)
	}
	return string(out), nil
}

// secretJSON is a Secret as the API serves it. encoding/json decodes and
// encodes []byte as base64, which is the API's encoding of data.
type secretJSON struct {
	APIVersion string `json:"apiVersion"`
	Kind       string `json:"kind"`
	Metadata   struct {
		Name        string            `json:"name"`
		Namespace   string            `json:"namespace"`
		Labels      map[string]string `json:"labels,omitempty"`
		Annotations map[string]string `json:"annotations,omitempty"`
	} `json:"metadata"`
	Type string            `json:"type,omitempty"`
	Data map[string][]byte `json:"data,omitempty"`
}

func decodeSecret(b []byte) (*secret, error) {
	var j secretJSON
	if err := json.Unmarshal(b, &j); err != nil {
		return nil, fmt.Errorf("decoding secret: %w", err)
	}
	return &secret{
		namespace:   j.Metadata.Namespace,
		name:        j.Metadata.Name,
		typ:         j.Type,
		data:        j.Data,
		labels:      j.Metadata.Labels,
		annotations: j.Metadata.Annotations,
	}, nil
}

func encodeSecret(s *secret) ([]byte, error) {
	var j secretJSON
	j.APIVersion, j.Kind = "v1", "Secret"
	j.Metadata.Name, j.Metadata.Namespace = s.name, s.namespace
	j.Metadata.Labels, j.Metadata.Annotations = s.labels, s.annotations
	j.Type, j.Data = s.typ, s.data
	return json.Marshal(j)
}

// platformSecret is a Secret in the management namespace with the Secrets
// Manager's label and the platform owners' grant.
func platformSecret(namespace, name, typ string, data map[string][]byte) *secret {
	return &secret{
		namespace:   namespace,
		name:        name,
		typ:         typ,
		data:        data,
		labels:      map[string]string{managedByLabel: managedBy},
		annotations: map[string]string{shareRoles: ownersGrant},
	}
}

// secretPatch returns the merge patch that brings have to want, or nil when
// none is needed. Only the keys of want are compared and written, so a key
// someone added stays. The label is set if it differs; the grant annotation
// is added only when absent, since a person may have shared the secret
// further in the Secrets Manager, which rewrites it.
func secretPatch(have, want *secret) ([]byte, error) {
	if have.typ != want.typ {
		return nil, fmt.Errorf("secret %s/%s is of type %s, want %s; delete it to replace it", want.namespace, want.name, have.typ, want.typ)
	}
	data := map[string][]byte{}
	for k, v := range want.data {
		if !bytes.Equal(have.data[k], v) {
			data[k] = v
		}
	}
	labels := map[string]string{}
	for k, v := range want.labels {
		if have.labels[k] != v {
			labels[k] = v
		}
	}
	annotations := map[string]string{}
	for k, v := range want.annotations {
		if _, ok := have.annotations[k]; !ok {
			annotations[k] = v
		}
	}
	if len(data) == 0 && len(labels) == 0 && len(annotations) == 0 {
		return nil, nil
	}
	patch := map[string]any{}
	if len(data) > 0 {
		patch["data"] = data
	}
	meta := map[string]any{}
	if len(labels) > 0 {
		meta["labels"] = labels
	}
	if len(annotations) > 0 {
		meta["annotations"] = annotations
	}
	if len(meta) > 0 {
		patch["metadata"] = meta
	}
	return json.Marshal(patch)
}

// applySecret creates want, or patches the Secret that exists to match it,
// and reports whether anything changed. A converged run writes nothing.
func applySecret(ctx context.Context, k kube, want *secret) (bool, error) {
	have, err := k.getSecret(ctx, want.namespace, want.name)
	if err != nil {
		return false, err
	}
	if have == nil {
		if err := k.createSecret(ctx, want); err != nil {
			return false, err
		}
		logf("created secret %s/%s", want.namespace, want.name)
		return true, nil
	}
	patch, err := secretPatch(have, want)
	if err != nil || patch == nil {
		return false, err
	}
	if err := k.patchSecret(ctx, want.namespace, want.name, patch); err != nil {
		return false, err
	}
	logf("updated secret %s/%s", want.namespace, want.name)
	return true, nil
}
