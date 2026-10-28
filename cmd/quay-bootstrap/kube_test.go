package main

import (
	"context"
	"encoding/json"
	"testing"
)

// fakeKube keeps Secrets in memory and counts writes, so a test can assert
// that a converged run writes nothing.
type fakeKube struct {
	secrets map[string]*secret
	writes  int
}

func newFakeKube() *fakeKube { return &fakeKube{secrets: map[string]*secret{}} }

func (f *fakeKube) getSecret(_ context.Context, ns, name string) (*secret, error) {
	s, ok := f.secrets[ns+"/"+name]
	if !ok {
		return nil, nil
	}
	c := *s
	return &c, nil
}

func (f *fakeKube) createSecret(_ context.Context, s *secret) error {
	f.writes++
	c := *s
	f.secrets[s.namespace+"/"+s.name] = &c
	return nil
}

func (f *fakeKube) patchSecret(_ context.Context, ns, name string, patch []byte) error {
	f.writes++
	var p struct {
		Data     map[string][]byte `json:"data"`
		Metadata struct {
			Labels      map[string]string `json:"labels"`
			Annotations map[string]string `json:"annotations"`
		} `json:"metadata"`
	}
	if err := json.Unmarshal(patch, &p); err != nil {
		return err
	}
	s := f.secrets[ns+"/"+name]
	data := map[string][]byte{}
	for k, v := range s.data {
		data[k] = v
	}
	for k, v := range p.Data {
		data[k] = v
	}
	s.data = data
	merge := func(dst map[string]string, src map[string]string) map[string]string {
		out := map[string]string{}
		for k, v := range dst {
			out[k] = v
		}
		for k, v := range src {
			out[k] = v
		}
		return out
	}
	s.labels = merge(s.labels, p.Metadata.Labels)
	s.annotations = merge(s.annotations, p.Metadata.Annotations)
	return nil
}

func (f *fakeKube) configMapValue(context.Context, string, string, string) (string, error) {
	return "", nil
}

func TestApplySecret(t *testing.T) {
	ctx := context.Background()
	k := newFakeKube()
	want := platformSecret("holos-prj-platform", "s", "Opaque", map[string][]byte{"token": []byte("a")})

	if changed, err := applySecret(ctx, k, want); err != nil || !changed || k.writes != 1 {
		t.Fatalf("create: changed %v, err %v, writes %d", changed, err, k.writes)
	}
	if changed, err := applySecret(ctx, k, want); err != nil || changed || k.writes != 1 {
		t.Fatalf("converged: changed %v, err %v, writes %d", changed, err, k.writes)
	}

	// A person shared it further: the grant is theirs to keep. A key someone
	// added stays too.
	s := k.secrets["holos-prj-platform/s"]
	s.annotations = map[string]string{shareRoles: `[{"principal":"jeff","role":"viewer"}]`}
	s.data = map[string][]byte{"token": []byte("a"), "extra": []byte("x")}
	if changed, err := applySecret(ctx, k, want); err != nil || changed {
		t.Fatalf("grant changed: changed %v, err %v", changed, err)
	}

	want.data["token"] = []byte("b")
	if changed, err := applySecret(ctx, k, want); err != nil || !changed {
		t.Fatalf("update: changed %v, err %v", changed, err)
	}
	s = k.secrets["holos-prj-platform/s"]
	if string(s.data["token"]) != "b" || string(s.data["extra"]) != "x" || s.annotations[shareRoles] == ownersGrant {
		t.Errorf("after update: %+v", s)
	}

	// The label goes back if someone removed it.
	s.labels = nil
	if changed, err := applySecret(ctx, k, want); err != nil || !changed || k.secrets["holos-prj-platform/s"].labels[managedByLabel] != managedBy {
		t.Errorf("label not restored: changed %v, err %v", changed, err)
	}
}

func TestSecretPatchType(t *testing.T) {
	have := platformSecret("ns", "pull", "Opaque", nil)
	want := platformSecret("ns", "pull", "kubernetes.io/dockerconfigjson", map[string][]byte{".dockerconfigjson": []byte("{}")})
	if _, err := secretPatch(have, want); err == nil {
		t.Error("a type change was patched; a Secret's type is immutable")
	}
}

func TestEncodeDecodeSecret(t *testing.T) {
	s := platformSecret("ns", "n", "Opaque", map[string][]byte{"k": []byte("v\x00")})
	b, err := encodeSecret(s)
	if err != nil {
		t.Fatal(err)
	}
	got, err := decodeSecret(b)
	if err != nil {
		t.Fatal(err)
	}
	if got.name != "n" || got.namespace != "ns" || string(got.data["k"]) != "v\x00" || got.labels[managedByLabel] != managedBy || got.annotations[shareRoles] != ownersGrant {
		t.Errorf("round trip: %+v", got)
	}
}

func TestDockerConfig(t *testing.T) {
	a, err := dockerConfig(map[string]dockerAuth{
		"quay.example/kagent":    {Username: "kagent+pull", Password: "p2"},
		"quay.example/substrate": {Username: "substrate+pull", Password: "p1"},
	})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"auths":{"quay.example/kagent":{"username":"kagent+pull","password":"p2","auth":"a2FnZW50K3B1bGw6cDI="},"quay.example/substrate":{"username":"substrate+pull","password":"p1","auth":"c3Vic3RyYXRlK3B1bGw6cDE="}}}`
	if string(a) != want {
		t.Errorf("got  %s\nwant %s", a, want)
	}
}

func TestOrgEmail(t *testing.T) {
	if got := orgEmail("https://quay.bank.internal", "svc-quay-controller", "platform-automation"); got != "svc-quay-controller+platform-automation@bank.internal" {
		t.Errorf("got %q", got)
	}
}
