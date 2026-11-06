package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

const (
	testCluster  = "treasury"
	testKeyValue = "sk-ant-not-a-real-key"
)

var (
	rootID      = identity{rootNamespace, rootName}
	anthropicID = identity{defaultPlatformNamespace, "anthropic-api-key"}
	testNow     = time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)
)

// fakeKube is a cluster in memory. writes records every change, so a test can
// say nothing was written.
type fakeKube struct {
	// cluster is the kubeconfig's cluster, testCluster unless set.
	cluster string
	secrets map[identity]*secret
	phases  map[string]string
	// lostRace makes createNamespace report that it lost a race.
	lostRace bool
	// getErr fails every read, and secretErr only getSecret.
	getErr, secretErr error
	reads             int
	writes            []string
}

func (f *fakeKube) clusterName(context.Context) (string, error) {
	if f.cluster != "" {
		return f.cluster, nil
	}
	return testCluster, nil
}

func (f *fakeKube) getSecret(_ context.Context, namespace, name string) (*secret, error) {
	f.reads++
	if f.getErr != nil {
		return nil, f.getErr
	}
	if f.secretErr != nil {
		return nil, f.secretErr
	}
	return f.secrets[identity{namespace, name}], nil
}

func (f *fakeKube) namespacePhase(_ context.Context, name string) (string, error) {
	f.reads++
	if f.getErr != nil {
		return "", f.getErr
	}
	return f.phases[name], nil
}

func (f *fakeKube) createNamespace(_ context.Context, name string) error {
	if f.lostRace {
		f.writes = append(f.writes, "lost race "+name)
		f.phases[name] = "Active"
		return errAlreadyExists
	}
	f.writes = append(f.writes, "create namespace "+name)
	f.phases[name] = "Active"
	return nil
}

func (f *fakeKube) createSecret(_ context.Context, s *secret) error {
	if f.phases[s.Metadata.Namespace] == "" {
		return errors.New("namespace does not exist")
	}
	f.writes = append(f.writes, "create "+s.id().String())
	f.secrets[s.id()] = s
	return nil
}

func (f *fakeKube) replaceSecret(_ context.Context, s *secret) error {
	f.writes = append(f.writes, "replace "+s.id().String())
	f.secrets[s.id()] = s
	return nil
}

// fakeGPG is not encryption: it stores the plaintext reversed, so a test can
// tell the file from the plaintext. decryptFails fails a decrypt of a file
// whose name contains it.
type fakeGPG struct {
	recipient    string
	decryptErr   error
	decryptFails string
	corrupt      bool
	// corruptTemp corrupts the decrypt of the temporary file alone.
	corruptTemp bool
}

func reversed(b []byte) []byte {
	out := make([]byte, len(b))
	for i, c := range b {
		out[len(b)-1-i] = c
	}
	return out
}

func (f *fakeGPG) encrypt(_ context.Context, recipient string, plaintext []byte, out *os.File) error {
	f.recipient = recipient
	_, err := out.Write(reversed(plaintext))
	return err
}

func (f *fakeGPG) decrypt(_ context.Context, path string) ([]byte, error) {
	if f.decryptErr != nil {
		return nil, f.decryptErr
	}
	if f.decryptFails != "" && strings.Contains(path, f.decryptFails) {
		return nil, errors.New("no secret key")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if f.corrupt || f.corruptTemp && strings.Contains(path, ".tmp-") {
		return []byte("something else"), nil
	}
	return reversed(b), nil
}

// rootSecret is a real root, in the shape cert-manager writes it.
func rootSecret(t *testing.T, cluster string) *secret {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return rootWith(t, key, cluster, nil)
}

// rootWith makes a root with this key, so two can share one, and change
// adjusts its certificate.
func rootWith(t *testing.T, key *ecdsa.PrivateKey, cluster string, change func(*x509.Certificate)) *secret {
	t.Helper()
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Bank of the Salish Sea " + cluster + " root CA"},
		NotBefore:             testNow.Add(-time.Hour),
		NotAfter:              testNow.Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	if change != nil {
		change(tmpl)
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	crt := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return &secret{
		APIVersion: secretAPIVersion,
		Kind:       secretKind,
		Metadata: metadata{
			Name:      rootName,
			Namespace: rootNamespace,
			Labels:    map[string]string{"controller.cert-manager.io/fao": "true"},
		},
		Type: "kubernetes.io/tls",
		Data: map[string][]byte{
			"ca.crt":  crt,
			"tls.crt": crt,
			"tls.key": pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}),
		},
	}
}

func anthropicSecret(value string) *secret {
	return &secret{
		APIVersion: secretAPIVersion,
		Kind:       secretKind,
		Metadata: metadata{
			Name:        anthropicID.name,
			Namespace:   anthropicID.namespace,
			Labels:      map[string]string{"app.kubernetes.io/managed-by": "holos.run"},
			Annotations: map[string]string{"holos.run/share-roles": `[{"principal":"/platform/owners","role":"owner"}]`},
		},
		Type: "Opaque",
		Data: map[string][]byte{"ANTHROPIC_API_KEY": []byte(value)},
	}
}

// liveCluster has both resources, as a cluster about to be destroyed does.
func liveCluster(t *testing.T) *fakeKube {
	t.Helper()
	return &fakeKube{
		secrets: map[identity]*secret{
			rootID:      rootSecret(t, testCluster),
			anthropicID: anthropicSecret(testKeyValue),
		},
		phases: map[string]string{rootNamespace: "Active", defaultPlatformNamespace: "Active"},
	}
}

// emptyCluster is one at the restore step: the management namespace exists
// and cert-manager's does not.
func emptyCluster() *fakeKube {
	return &fakeKube{
		secrets: map[identity]*secret{},
		phases:  map[string]string{defaultPlatformNamespace: "Active"},
	}
}

func newApp(t *testing.T, k kube, g crypter, opts ...func(*options)) (*app, *bytes.Buffer) {
	t.Helper()
	o := options{
		cluster:           testCluster,
		file:              filepath.Join(t.TempDir(), "treasury-state.json.gpg"),
		recipient:         "ABCD",
		platformNamespace: defaultPlatformNamespace,
	}
	for _, opt := range opts {
		opt(&o)
	}
	var out bytes.Buffer
	return &app{kube: k, gpg: g, stdout: &out, now: func() time.Time { return testNow }, opts: o}, &out
}

func skip(ids ...string) func(*options) {
	return func(o *options) { o.skips = append(o.skips, ids...) }
}

func force(o *options) { o.force = true }

func onFile(path string) func(*options) {
	return func(o *options) { o.file = path }
}

// savedFile saves live to a file and returns its path.
func savedFile(t *testing.T, live *fakeKube, opts ...func(*options)) string {
	t.Helper()
	a, _ := newApp(t, live, &fakeGPG{}, opts...)
	if err := a.save(context.Background()); err != nil {
		t.Fatal(err)
	}
	return a.opts.file
}

func dirEntries(t *testing.T, path string) []string {
	t.Helper()
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	return names
}

func wantError(t *testing.T, err error, parts ...string) {
	t.Helper()
	if err == nil {
		t.Fatalf("want an error containing %q, got none", parts)
	}
	for _, p := range parts {
		if !strings.Contains(err.Error(), p) {
			t.Errorf("error %q does not contain %q", err, p)
		}
	}
}

func TestSaveWritesAFileThatReadsBack(t *testing.T) {
	live := liveCluster(t)
	g := &fakeGPG{}
	a, out := newApp(t, live, g)
	if err := a.save(context.Background()); err != nil {
		t.Fatal(err)
	}
	if g.recipient != "ABCD" {
		t.Errorf("recipient %q", g.recipient)
	}
	if names := dirEntries(t, a.opts.file); len(names) != 1 || names[0] != "treasury-state.json.gpg" {
		t.Errorf("directory holds %v, want only the file", names)
	}
	if strings.Contains(out.String(), testKeyValue) {
		t.Error("the output carries the key")
	}
	for _, want := range []string{"last step before talosvm destroy -yes", "before the root Application", "root SHA-256",
		"holos/ directory", "go run ../cmd/state restore -cluster treasury\n"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("output does not say %q:\n%s", want, out)
		}
	}
	raw, err := os.ReadFile(a.opts.file)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte(testKeyValue)) {
		t.Error("the file carries the key in the clear")
	}
	_, saved, err := decodeState(reversed(raw), testCluster)
	if err != nil {
		t.Fatal(err)
	}
	if len(saved) != 2 {
		t.Fatalf("saved %d resources", len(saved))
	}
}

func TestSaveFailsHardOnAMissingResource(t *testing.T) {
	live := liveCluster(t)
	delete(live.secrets, anthropicID)
	a, _ := newApp(t, live, &fakeGPG{})
	err := a.save(context.Background())
	wantError(t, err, "nothing written", anthropicID.String(), "-skip "+anthropicID.String())
	if _, statErr := os.Stat(a.opts.file); statErr == nil {
		t.Error("a file was written")
	}
	if names := dirEntries(t, a.opts.file); len(names) != 0 {
		t.Errorf("left %v behind", names)
	}
}

func TestSaveNamesEverythingMissingAtOnce(t *testing.T) {
	live := liveCluster(t)
	live.secrets = map[identity]*secret{}
	a, _ := newApp(t, live, &fakeGPG{})
	wantError(t, a.save(context.Background()), rootID.String(), anthropicID.String())
}

func TestSaveSkipByIdentity(t *testing.T) {
	live := liveCluster(t)
	delete(live.secrets, anthropicID)
	a, out := newApp(t, live, &fakeGPG{}, skip(anthropicID.String()))
	if err := a.save(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "skipped  "+anthropicID.String()) {
		t.Errorf("output does not name the skip:\n%s", out)
	}
	if !strings.Contains(out.String(), "-skip "+anthropicID.String()) {
		t.Errorf("the restore command it prints drops the skip:\n%s", out)
	}
	raw, _ := os.ReadFile(a.opts.file)
	_, saved, err := decodeState(reversed(raw), testCluster)
	if err != nil {
		t.Fatal(err)
	}
	if len(saved) != 1 || saved[0].id() != rootID {
		t.Fatalf("saved %v", saved)
	}
}

func TestBadSkips(t *testing.T) {
	for _, bad := range []string{"anthropic-api-key", "/name", "namespace/", "a/b/c", ""} {
		a, _ := newApp(t, liveCluster(t), &fakeGPG{}, skip(bad))
		wantError(t, a.save(context.Background()), "want <namespace>/<name>")
	}
	a, _ := newApp(t, liveCluster(t), &fakeGPG{}, skip("kagent/anthropic-api-key"))
	wantError(t, a.save(context.Background()), "matches nothing", "known resources are")
}

func TestSaveRefusesWhenEverythingIsSkipped(t *testing.T) {
	a, _ := newApp(t, liveCluster(t), &fakeGPG{}, skip(rootID.String(), anthropicID.String()))
	wantError(t, a.save(context.Background()), "every resource is skipped")
}

func TestSaveDoesNotReadUnreachableAsMissing(t *testing.T) {
	live := liveCluster(t)
	live.getErr = errors.New("connection refused")
	a, _ := newApp(t, live, &fakeGPG{}, skip(anthropicID.String()))
	wantError(t, a.save(context.Background()), "connection refused")
}

func TestSaveDecryptFailureInstallsNothing(t *testing.T) {
	a, _ := newApp(t, liveCluster(t), &fakeGPG{decryptErr: errors.New("no secret key")})
	wantError(t, a.save(context.Background()), "nothing written", "attach-gpg")
	if names := dirEntries(t, a.opts.file); len(names) != 0 {
		t.Errorf("left %v behind", names)
	}
}

func TestSaveCorruptReadBackInstallsNothing(t *testing.T) {
	a, _ := newApp(t, liveCluster(t), &fakeGPG{corrupt: true})
	wantError(t, a.save(context.Background()), "nothing written")
	if names := dirEntries(t, a.opts.file); len(names) != 0 {
		t.Errorf("left %v behind", names)
	}
}

func TestSecondSaveRefusesAndSaysWhenForceIsRight(t *testing.T) {
	live := liveCluster(t)
	file := savedFile(t, live)
	first, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	a, _ := newApp(t, live, &fakeGPG{}, onFile(file))
	wantError(t, a.save(context.Background()), "exists", "restored from it", "-force", "rebuilt without a restore, do not save")
	if got, _ := os.ReadFile(file); !bytes.Equal(got, first) {
		t.Error("the refusal changed the file")
	}
}

func TestForceKeepsEveryGeneration(t *testing.T) {
	live := liveCluster(t)
	file := savedFile(t, live)
	contents := map[string]bool{}
	read := func(path string) string {
		t.Helper()
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	contents[read(file)] = true

	// The same second each time, the fake's clock being fixed.
	for i, value := range []string{"sk-ant-second", "sk-ant-third", "sk-ant-fourth"} {
		live.secrets[anthropicID] = anthropicSecret(value)
		a, out := newApp(t, live, &fakeGPG{}, onFile(file), force)
		if err := a.save(context.Background()); err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(out.String(), "kept") {
			t.Errorf("run %d does not say where the old file went:\n%s", i, out)
		}
		contents[read(file)] = true
	}

	names := dirEntries(t, file)
	if len(names) != 4 {
		t.Fatalf("directory holds %v, want the file and three generations", names)
	}
	found := map[string]bool{}
	stamp := "treasury-state.json.gpg." + testNow.Format("20060102T150405Z")
	for _, name := range names {
		if name != "treasury-state.json.gpg" && !strings.HasPrefix(name, stamp) {
			t.Errorf("unexpected name %s", name)
		}
		found[read(filepath.Join(filepath.Dir(file), name))] = true
	}
	if !reflect.DeepEqual(found, contents) {
		t.Error("a generation was lost")
	}
}

// snapshot is every file in the directory, so a test can say a refusal moved
// nothing.
func snapshot(t *testing.T, file string) map[string]string {
	t.Helper()
	out := map[string]string{}
	for _, name := range dirEntries(t, file) {
		b, err := os.ReadFile(filepath.Join(filepath.Dir(file), name))
		if err != nil {
			t.Fatal(err)
		}
		out[name] = string(b)
	}
	return out
}

func TestForceRefusesADifferentRoot(t *testing.T) {
	live := liveCluster(t)
	file := savedFile(t, live)
	before := snapshot(t, file)

	// A cluster rebuilt without a restore has a new root.
	live.secrets[rootID] = rootSecret(t, testCluster)
	a, _ := newApp(t, live, &fakeGPG{}, onFile(file), force)
	wantError(t, a.save(context.Background()), "different root", "probably rebuilt without restoring",
		"Do not save", "restore that file", "move the file aside yourself")
	if !reflect.DeepEqual(snapshot(t, file), before) {
		t.Error("the refusal changed the directory")
	}
}

func TestForceAllowsARenewalWithTheSameKey(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	live := liveCluster(t)
	live.secrets[rootID] = rootWith(t, key, testCluster, nil)
	file := savedFile(t, live)

	live.secrets[rootID] = rootWith(t, key, testCluster, func(c *x509.Certificate) { c.SerialNumber = big.NewInt(7) })
	a, _ := newApp(t, live, &fakeGPG{}, onFile(file), force)
	if err := a.save(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestForceRefusesAFileItCannotDecrypt(t *testing.T) {
	live := liveCluster(t)
	file := savedFile(t, live)
	before := snapshot(t, file)
	// Only the existing file fails: the temporary one has a dot in front.
	a, _ := newApp(t, live, &fakeGPG{decryptFails: "/treasury-state"}, onFile(file), force)
	wantError(t, a.save(context.Background()), "cannot be decrypted", "move it aside yourself", "attach-gpg")
	if !reflect.DeepEqual(snapshot(t, file), before) {
		t.Error("the refusal changed the directory")
	}
}

func TestForceRefusesAFileThatIsNotAStateFile(t *testing.T) {
	live := liveCluster(t)
	file := savedFile(t, live)
	if err := os.WriteFile(file, reversed([]byte("not json")), 0o600); err != nil {
		t.Fatal(err)
	}
	before := snapshot(t, file)
	a, _ := newApp(t, live, &fakeGPG{}, onFile(file), force)
	wantError(t, a.save(context.Background()), "cannot be read", "move it aside yourself")
	if !reflect.DeepEqual(snapshot(t, file), before) {
		t.Error("the refusal changed the directory")
	}
}

func TestForceComparesNoRootWhenEitherSideSkipsIt(t *testing.T) {
	// The file has no root.
	live := liveCluster(t)
	file := savedFile(t, live, skip(rootID.String()))
	a, _ := newApp(t, live, &fakeGPG{}, onFile(file), force)
	if err := a.save(context.Background()); err != nil {
		t.Fatalf("file without a root: %v", err)
	}

	// The save skips it, though the cluster's differs from the file's.
	live = liveCluster(t)
	file = savedFile(t, live)
	live.secrets[rootID] = rootSecret(t, testCluster)
	a, _ = newApp(t, live, &fakeGPG{}, onFile(file), force, skip(rootID.String()))
	if err := a.save(context.Background()); err != nil {
		t.Fatalf("save without a root: %v", err)
	}
}

func TestForceMovesNothingBeforeTheChecksPass(t *testing.T) {
	cases := map[string]func(*fakeKube, *fakeGPG){
		"a resource is missing":         func(k *fakeKube, _ *fakeGPG) { delete(k.secrets, anthropicID) },
		"the API fails":                 func(k *fakeKube, _ *fakeGPG) { k.secretErr = errors.New("forbidden") },
		"the new file does not decrypt": func(_ *fakeKube, g *fakeGPG) { g.decryptFails = ".tmp-" },
		"the new file decrypts wrong":   func(_ *fakeKube, g *fakeGPG) { g.corruptTemp = true },
	}
	for name, breakIt := range cases {
		t.Run(name, func(t *testing.T) {
			live := liveCluster(t)
			file := savedFile(t, live)
			before := snapshot(t, file)
			g := &fakeGPG{}
			breakIt(live, g)
			a, _ := newApp(t, live, g, onFile(file), force)
			if err := a.save(context.Background()); err == nil {
				t.Fatal("want an error")
			}
			if !reflect.DeepEqual(snapshot(t, file), before) {
				t.Errorf("the directory changed: %v", dirEntries(t, file))
			}
		})
	}
}

func TestInstallRefusesAFileThatAppearedLate(t *testing.T) {
	dir := t.TempDir()
	tmp, file := filepath.Join(dir, "tmp"), filepath.Join(dir, "file")
	for _, p := range []string{tmp, file} {
		if err := os.WriteFile(p, []byte(p), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	wantError(t, install(tmp, file), "exists", "-force")
}

func TestBothVerbsRefuseAKubeconfigForAnotherCluster(t *testing.T) {
	live := liveCluster(t)
	file := savedFile(t, live)

	wrong := liveCluster(t)
	wrong.cluster = "cartography"
	a, _ := newApp(t, wrong, &fakeGPG{})
	wantError(t, a.save(context.Background()), `selects cluster "cartography", not "treasury"`)
	if wrong.reads != 0 {
		t.Errorf("save read the cluster %d times", wrong.reads)
	}

	// The restore refuses before it decrypts, and writes nothing.
	wrong = emptyCluster()
	wrong.cluster = "cartography"
	g := &fakeGPG{decryptErr: errors.New("decrypted anyway")}
	a, _ = newApp(t, wrong, g, onFile(file))
	wantError(t, a.restore(context.Background()), `selects cluster "cartography", not "treasury"`)
	if wrong.reads != 0 || len(wrong.writes) != 0 {
		t.Errorf("restore touched the cluster: %d reads, %v", wrong.reads, wrong.writes)
	}
}

func TestSaveRefusesAnotherClustersRoot(t *testing.T) {
	live := liveCluster(t)
	live.secrets[rootID] = rootSecret(t, "cartography")
	a, _ := newApp(t, live, &fakeGPG{})
	wantError(t, a.save(context.Background()), "another cluster's root")
	if _, err := os.Stat(a.opts.file); err == nil {
		t.Error("a file was written")
	}
}

func TestCheckRoot(t *testing.T) {
	a, _ := newApp(t, nil, nil)
	if err := checkRoot(a, rootSecret(t, testCluster)); err != nil {
		t.Fatal(err)
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	notCA := rootWith(t, key, testCluster, func(c *x509.Certificate) { c.IsCA = false; c.KeyUsage = x509.KeyUsageDigitalSignature })
	wantError(t, checkRoot(a, notCA), "not a CA")
	notYet := rootWith(t, key, testCluster, func(c *x509.Certificate) { c.NotBefore = testNow.Add(time.Minute) })
	wantError(t, checkRoot(a, notYet), "not now")

	garbage := rootSecret(t, testCluster)
	garbage.Data["ca.crt"] = []byte("not a certificate")
	wantError(t, checkRoot(a, garbage), "ca.crt is not a PEM certificate")
	corrupt := rootSecret(t, testCluster)
	corrupt.Data["ca.crt"] = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: []byte("nonsense")})
	wantError(t, checkRoot(a, corrupt), "ca.crt cannot be parsed")
	other := rootSecret(t, testCluster)
	other.Data["ca.crt"] = rootSecret(t, testCluster).Data["tls.crt"]
	wantError(t, checkRoot(a, other), "ca.crt is not the certificate in tls.crt")

	mismatched := rootSecret(t, testCluster)
	mismatched.Data["tls.key"] = rootSecret(t, testCluster).Data["tls.key"]
	wantError(t, checkRoot(a, mismatched), "not a key pair")
	missing := rootSecret(t, testCluster)
	delete(missing.Data, "ca.crt")
	wantError(t, checkRoot(a, missing), "ca.crt")
	expired, _ := newApp(t, nil, nil)
	expired.now = func() time.Time { return testNow.Add(2 * time.Hour) }
	wantError(t, checkRoot(expired, rootSecret(t, testCluster)), "not now")
}

func TestSaveRefusesAnEmptyKey(t *testing.T) {
	live := liveCluster(t)
	live.secrets[anthropicID] = anthropicSecret("  \n")
	a, _ := newApp(t, live, &fakeGPG{})
	wantError(t, a.save(context.Background()), "ANTHROPIC_API_KEY")
}

func TestRestoreCreatesMissingNamespaces(t *testing.T) {
	file := savedFile(t, liveCluster(t))
	k := emptyCluster()
	a, out := newApp(t, k, &fakeGPG{}, onFile(file))
	if err := a.restore(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := []string{"create namespace cert-manager", "create " + rootID.String(), "create " + anthropicID.String()}
	if !reflect.DeepEqual(k.writes, want) {
		t.Errorf("writes %v, want %v", k.writes, want)
	}
	if !strings.Contains(out.String(), "root SHA-256") {
		t.Errorf("output has no fingerprint:\n%s", out)
	}
	if strings.Contains(out.String(), testKeyValue) {
		t.Error("the output carries the key")
	}
	got := k.secrets[rootID]
	if got.Metadata.Labels["controller.cert-manager.io/fao"] != "true" {
		t.Error("the root lost the label cert-manager finds it by")
	}
	if k.secrets[anthropicID].Metadata.Annotations["holos.run/share-roles"] == "" {
		t.Error("the key lost the Secrets Manager's grant")
	}
}

func TestRestoreSurvivesANamespaceCreatedAfterTheCheck(t *testing.T) {
	file := savedFile(t, liveCluster(t))
	k := emptyCluster()
	k.lostRace = true
	a, _ := newApp(t, k, &fakeGPG{}, onFile(file))
	if err := a.restore(context.Background()); err != nil {
		t.Fatal(err)
	}
	if k.secrets[rootID] == nil {
		t.Error("the root was not restored")
	}
}

func TestRestoreRefusesATerminatingNamespace(t *testing.T) {
	file := savedFile(t, liveCluster(t))
	k := emptyCluster()
	k.phases[rootNamespace] = "Terminating"
	a, _ := newApp(t, k, &fakeGPG{}, onFile(file))
	wantError(t, a.restore(context.Background()), "nothing restored", "Terminating")
	if len(k.writes) != 0 {
		t.Errorf("wrote %v", k.writes)
	}
}

func TestRestoreLeavesIdenticalDataAlone(t *testing.T) {
	live := liveCluster(t)
	file := savedFile(t, live)
	// The same data under other metadata, as a key entered again by hand.
	again := anthropicSecret(testKeyValue)
	again.Metadata.Labels = nil
	live.secrets[anthropicID] = again
	a, out := newApp(t, live, &fakeGPG{}, onFile(file))
	if err := a.restore(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(live.writes) != 0 {
		t.Errorf("wrote %v", live.writes)
	}
	if !strings.Contains(out.String(), "left as is") {
		t.Errorf("output:\n%s", out)
	}
}

func TestRestoreRefusesDifferentDataThenForceReplaces(t *testing.T) {
	saved := liveCluster(t)
	file := savedFile(t, saved)

	// A cluster on which cert-manager has already issued a new root.
	k := emptyCluster()
	k.phases[rootNamespace] = "Active"
	k.secrets[rootID] = rootSecret(t, testCluster)
	a, _ := newApp(t, k, &fakeGPG{}, onFile(file))
	wantError(t, a.restore(context.Background()), "nothing restored", rootID.String(), "root Application was applied before")
	if len(k.writes) != 0 {
		t.Fatalf("wrote %v", k.writes)
	}

	a, out := newApp(t, k, &fakeGPG{}, onFile(file), force)
	if err := a.restore(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !sameContent(k.secrets[rootID], saved.secrets[rootID]) {
		t.Error("-force did not put the saved root back")
	}
	if !strings.Contains(out.String(), "REPLACED") {
		t.Errorf("output does not call out the replace:\n%s", out)
	}
}

func TestRestorePreflightWritesNothingOnAnyFailure(t *testing.T) {
	file := savedFile(t, liveCluster(t))
	// The root could be created, and the key conflicts: nothing may be
	// written, namespaces included.
	k := emptyCluster()
	k.secrets[anthropicID] = anthropicSecret("sk-ant-a-different-key")
	a, _ := newApp(t, k, &fakeGPG{}, onFile(file))
	wantError(t, a.restore(context.Background()), "nothing restored", anthropicID.String())
	if len(k.writes) != 0 {
		t.Errorf("wrote %v", k.writes)
	}
}

func TestRestoreFailsHardOnAResourceNotInTheFile(t *testing.T) {
	live := liveCluster(t)
	delete(live.secrets, anthropicID)
	file := savedFile(t, live, skip(anthropicID.String()))

	k := emptyCluster()
	a, _ := newApp(t, k, &fakeGPG{}, onFile(file))
	wantError(t, a.restore(context.Background()), "not in the file", "-skip "+anthropicID.String())
	if len(k.writes) != 0 {
		t.Errorf("wrote %v", k.writes)
	}

	a, out := newApp(t, k, &fakeGPG{}, onFile(file), skip(anthropicID.String()))
	if err := a.restore(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "skipped     "+anthropicID.String()) {
		t.Errorf("output:\n%s", out)
	}
}

func TestRestoreBadCACertInTheFileIsRefused(t *testing.T) {
	bad := rootSecret(t, testCluster)
	bad.Data["ca.crt"] = rootSecret(t, testCluster).Data["tls.crt"]
	plaintext, err := encodeState(testCluster, testNow, []*secret{bad, anthropicSecret(testKeyValue)})
	if err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(t.TempDir(), "f")
	if err := os.WriteFile(file, reversed(plaintext), 0o600); err != nil {
		t.Fatal(err)
	}
	k := emptyCluster()
	a, _ := newApp(t, k, &fakeGPG{}, onFile(file))
	wantError(t, a.restore(context.Background()), "ca.crt is not the certificate")
	if len(k.writes) != 0 {
		t.Errorf("wrote %v", k.writes)
	}
}

func TestRestoreChecksItsSkips(t *testing.T) {
	file := savedFile(t, liveCluster(t))
	k := emptyCluster()
	a, _ := newApp(t, k, &fakeGPG{}, onFile(file), skip("kagent/anthropic-api-key"))
	wantError(t, a.restore(context.Background()), "matches nothing")
	if len(k.writes) != 0 {
		t.Errorf("wrote %v", k.writes)
	}
	a, _ = newApp(t, k, &fakeGPG{}, onFile(file), skip("anthropic-api-key"))
	wantError(t, a.restore(context.Background()), "want <namespace>/<name>")
}

func TestRestoreDoesNotReadAPIErrorsAsMissing(t *testing.T) {
	file := savedFile(t, liveCluster(t))

	k := emptyCluster()
	k.getErr = errors.New("connection refused")
	a, _ := newApp(t, k, &fakeGPG{}, onFile(file))
	wantError(t, a.restore(context.Background()), "connection refused")
	if len(k.writes) != 0 {
		t.Errorf("namespace error: wrote %v", k.writes)
	}

	k = emptyCluster()
	k.phases[rootNamespace] = "Active"
	k.secretErr = errors.New("secrets is forbidden")
	a, _ = newApp(t, k, &fakeGPG{}, onFile(file))
	wantError(t, a.restore(context.Background()), "forbidden")
	if len(k.writes) != 0 {
		t.Errorf("Secret error: wrote %v", k.writes)
	}
}

func TestRestoreForceReplacesThroughReplace(t *testing.T) {
	saved := liveCluster(t)
	file := savedFile(t, saved)
	k := emptyCluster()
	k.phases[rootNamespace] = "Active"
	k.secrets[anthropicID] = anthropicSecret("sk-ant-a-different-key")
	a, _ := newApp(t, k, &fakeGPG{}, onFile(file), force)
	if err := a.restore(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := []string{"create " + rootID.String(), "replace " + anthropicID.String()}
	if !reflect.DeepEqual(k.writes, want) {
		t.Errorf("writes %v, want %v", k.writes, want)
	}
}

func TestRestoreSkippingEverythingIsNotAnError(t *testing.T) {
	file := savedFile(t, liveCluster(t))
	k := emptyCluster()
	a, out := newApp(t, k, &fakeGPG{}, onFile(file), skip(rootID.String(), anthropicID.String()))
	if err := a.restore(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(k.writes) != 0 {
		t.Errorf("wrote %v", k.writes)
	}
	if !strings.HasPrefix(out.String(), "Nothing restored") {
		t.Errorf("output:\n%s", out)
	}
	if strings.Contains(out.String(), "fingerprint") {
		t.Errorf("no root was restored, so there is no fingerprint to check:\n%s", out)
	}
}

func TestSameContentComparesTypeAndData(t *testing.T) {
	a, b := anthropicSecret("x"), anthropicSecret("x")
	if !sameContent(a, b) {
		t.Error("identical Secrets differ")
	}
	b.Metadata.Labels = nil
	if !sameContent(a, b) {
		t.Error("metadata counted")
	}
	b.Type = "kubernetes.io/tls"
	if sameContent(a, b) {
		t.Error("Type did not count")
	}
	if sameContent(a, anthropicSecret("y")) {
		t.Error("data did not count")
	}
}

func TestSaveCarriesItsFlagsToTheRestoreCommand(t *testing.T) {
	dir := t.TempDir()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	rel, err := filepath.Rel(wd, filepath.Join(dir, "a b.gpg"))
	if err != nil {
		t.Fatal(err)
	}
	live := liveCluster(t)
	live.phases["other-ns"] = "Active"
	live.secrets[identity{"other-ns", "anthropic-api-key"}] = anthropicSecret(testKeyValue)
	a, out := newApp(t, live, &fakeGPG{}, onFile(rel), func(o *options) {
		o.fileSet, o.kubeconfigSet, o.platformNamespaceSet = true, true, true
		o.kubeconfig = filepath.Join(dir, "kc")
		o.platformNamespace = "other-ns"
		o.skips = []string{rootID.String()}
	})
	if err := a.save(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := "go run ../cmd/state restore -cluster treasury -file '" + filepath.Join(dir, "a b.gpg") + "' -kubeconfig " +
		filepath.Join(dir, "kc") + " -platform-namespace other-ns -skip " + rootID.String() + "\n"
	if !strings.Contains(out.String(), want) {
		t.Errorf("output does not hold %q:\n%s", want, out)
	}
}

func TestRestoreSkipKeepsAResourceOut(t *testing.T) {
	file := savedFile(t, liveCluster(t))
	k := emptyCluster()
	a, _ := newApp(t, k, &fakeGPG{}, onFile(file), skip(rootID.String()))
	if err := a.restore(context.Background()); err != nil {
		t.Fatal(err)
	}
	if k.secrets[rootID] != nil {
		t.Error("a skipped root was restored")
	}
	want := []string{"create " + anthropicID.String()}
	if !reflect.DeepEqual(k.writes, want) {
		t.Errorf("writes %v, want %v", k.writes, want)
	}
}

func TestRestoreRefusesAnotherClustersFile(t *testing.T) {
	file := savedFile(t, liveCluster(t))
	k := emptyCluster()
	k.cluster = "cartography"
	a, _ := newApp(t, k, &fakeGPG{}, onFile(file), func(o *options) { o.cluster = "cartography" })
	wantError(t, a.restore(context.Background()), `saved from cluster "treasury"`)
	if len(k.writes) != 0 {
		t.Errorf("wrote %v", k.writes)
	}
}

func TestRestoreRefusesAnotherClustersRootInTheRightEnvelope(t *testing.T) {
	plaintext, err := encodeState(testCluster, testNow, []*secret{rootSecret(t, "cartography"), anthropicSecret(testKeyValue)})
	if err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(t.TempDir(), "f")
	if err := os.WriteFile(file, reversed(plaintext), 0o600); err != nil {
		t.Fatal(err)
	}
	k := emptyCluster()
	a, _ := newApp(t, k, &fakeGPG{}, onFile(file))
	wantError(t, a.restore(context.Background()), "another cluster's root")
	if len(k.writes) != 0 {
		t.Errorf("wrote %v", k.writes)
	}
}

func TestRestoreRefusesAnUnknownKindAndVersion(t *testing.T) {
	cluster := []byte(`{"version":1,"cluster":"treasury","resources":[{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"a","namespace":"b"}}]}`)
	if _, _, err := decodeState(cluster, testCluster); err == nil || !strings.Contains(err.Error(), "ConfigMap") {
		t.Errorf("got %v", err)
	}
	if _, _, err := decodeState([]byte(`{"version":2,"cluster":"treasury"}`), testCluster); err == nil || !strings.Contains(err.Error(), "version 2") {
		t.Errorf("got %v", err)
	}
}

func TestRestoreCarriesAResourceItDoesNotKnow(t *testing.T) {
	root := rootSecret(t, testCluster)
	extra := anthropicSecret(testKeyValue)
	extra.Metadata.Namespace, extra.Metadata.Name = "other", "extra"
	plaintext, err := encodeState(testCluster, testNow, []*secret{root, anthropicSecret(testKeyValue), extra})
	if err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(t.TempDir(), "f")
	if err := os.WriteFile(file, reversed(plaintext), 0o600); err != nil {
		t.Fatal(err)
	}
	k := emptyCluster()
	a, _ := newApp(t, k, &fakeGPG{}, onFile(file))
	if err := a.restore(context.Background()); err != nil {
		t.Fatal(err)
	}
	if k.secrets[identity{"other", "extra"}] == nil {
		t.Error("the resource was dropped")
	}
	// And -skip reaches it, by what the file names.
	k = emptyCluster()
	a, _ = newApp(t, k, &fakeGPG{}, onFile(file), skip("other/extra"))
	if err := a.restore(context.Background()); err != nil {
		t.Fatal(err)
	}
	if k.secrets[identity{"other", "extra"}] != nil {
		t.Error("a skipped resource was restored")
	}
}

func TestRestoreNamesAttachGPGWhenItCannotDecrypt(t *testing.T) {
	file := savedFile(t, liveCluster(t))
	a, _ := newApp(t, emptyCluster(), &fakeGPG{decryptErr: errors.New("no secret key")}, onFile(file))
	wantError(t, a.restore(context.Background()), "attach-gpg")
}

func TestRestoreSaysHowToGetAFile(t *testing.T) {
	a, _ := newApp(t, emptyCluster(), &fakeGPG{})
	wantError(t, a.restore(context.Background()), "does not exist", "Rebuilding a cluster")
}

// A Secret as kubectl prints it: everything outside the allow-list has to stay
// behind, and the labels and annotations that mean something have to survive.
const kubectlSecret = `{
  "apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/tls",
  "metadata": {
    "name": "private-ca-root", "namespace": "cert-manager",
    "uid": "d12e5398", "resourceVersion": "2673", "generation": 3,
    "creationTimestamp": "2026-11-05T22:08:08Z", "selfLink": "/x",
    "managedFields": [{"manager": "cert-manager"}],
    "ownerReferences": [{"kind": "Certificate"}],
    "finalizers": ["x"],
    "labels": {"controller.cert-manager.io/fao": "true"},
    "annotations": {"holos.run/share-roles": "[]", "kubectl.kubernetes.io/last-applied-configuration": "{}"}
  },
  "data": {"tls.crt": "eA=="}
}`

func TestAllowListThroughKubectl(t *testing.T) {
	dir := t.TempDir()
	script := "#!/bin/sh\ncat <<'EOF'\n" + kubectlSecret + "\nEOF\n"
	if err := os.WriteFile(filepath.Join(dir, "kubectl"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	s, err := (&kubectl{kubeconfig: "k"}).getSecret(context.Background(), "cert-manager", "private-ca-root")
	if err != nil {
		t.Fatal(err)
	}
	plaintext, err := encodeState(testCluster, testNow, []*secret{s})
	if err != nil {
		t.Fatal(err)
	}
	var f stateFile
	if err := json.Unmarshal(plaintext, &f); err != nil {
		t.Fatal(err)
	}
	out := string(f.Resources[0])
	for _, gone := range []string{"uid", "resourceVersion", "generation", "creationTimestamp", "selfLink", "managedFields", "ownerReferences", "finalizers", "last-applied"} {
		if strings.Contains(out, gone) {
			t.Errorf("%s came through: %s", gone, out)
		}
	}
	for _, kept := range []string{"controller.cert-manager.io/fao", "holos.run/share-roles", "kubernetes.io/tls", `"tls.crt": "eA=="`} {
		if !strings.Contains(out, kept) {
			t.Errorf("%s was lost: %s", kept, out)
		}
	}
}

// fakeKubectl installs a kubectl that records its arguments and stdin.
func fakeKubectl(t *testing.T, body string) (args, stdin string) {
	t.Helper()
	dir := t.TempDir()
	args, stdin = filepath.Join(dir, "args"), filepath.Join(dir, "stdin")
	script := "#!/bin/sh\necho \"$@\" >> " + args + "\ncat > " + stdin + "\n" + body + "\n"
	if err := os.WriteFile(filepath.Join(dir, "kubectl"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("KUBECONFIG", "/the/shells/kubeconfig")
	return args, stdin
}

func TestKubectlReadsTheClusterName(t *testing.T) {
	args, _ := fakeKubectl(t, "printf treasury")
	k := &kubectl{kubeconfig: "/the/clusters/kubeconfig"}
	name, err := k.clusterName(context.Background())
	if err != nil || name != "treasury" {
		t.Fatalf("got %q, %v", name, err)
	}
	got, err := os.ReadFile(args)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(got), "config view --minify") {
		t.Errorf("args: %s", got)
	}
	fakeKubectl(t, `echo 'error: current-context must exist in order to minify' >&2; exit 1`)
	if _, err := k.clusterName(context.Background()); err == nil {
		t.Error("want an error")
	}
}

func TestKubectlTellsNotFoundFromOtherFailures(t *testing.T) {
	k := &kubectl{kubeconfig: "/the/clusters/kubeconfig"}
	ctx := context.Background()

	fakeKubectl(t, `echo 'Error from server (NotFound): secrets "x" not found' >&2; exit 1`)
	if s, err := k.getSecret(ctx, "n", "x"); s != nil || err != nil {
		t.Errorf("NotFound: got %v, %v", s, err)
	}
	if p, err := k.namespacePhase(ctx, "n"); p != "" || err != nil {
		t.Errorf("NotFound: got %q, %v", p, err)
	}

	fakeKubectl(t, `echo 'Unable to connect to the server: dial tcp: connection refused' >&2; exit 1`)
	if _, err := k.getSecret(ctx, "n", "x"); err == nil || !strings.Contains(err.Error(), "connection refused") {
		t.Errorf("unreachable: got %v", err)
	}
	if _, err := k.namespacePhase(ctx, "n"); err == nil {
		t.Error("unreachable read as a missing namespace")
	}

	fakeKubectl(t, `echo 'Error from server (Forbidden): secrets "x" is forbidden: User "u" cannot get resource' >&2; exit 1`)
	if s, err := k.getSecret(ctx, "n", "x"); s != nil || err == nil || !strings.Contains(err.Error(), "Forbidden") {
		t.Errorf("Forbidden read as missing: %v, %v", s, err)
	}
	if p, err := k.namespacePhase(ctx, "n"); p != "" || err == nil || !strings.Contains(err.Error(), "Forbidden") {
		t.Errorf("Forbidden read as missing: %q, %v", p, err)
	}

	fakeKubectl(t, `echo 'Error from server (AlreadyExists): namespaces "n" already exists' >&2; exit 1`)
	if err := k.createNamespace(ctx, "n"); !errors.Is(err, errAlreadyExists) {
		t.Errorf("AlreadyExists: got %v", err)
	}
}

func TestKubectlReplaceUsesReplace(t *testing.T) {
	args, _ := fakeKubectl(t, "")
	k := &kubectl{kubeconfig: "k"}
	if err := k.replaceSecret(context.Background(), anthropicSecret(testKeyValue)); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(args)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(got), " replace -f -") || strings.Contains(string(got), " create ") {
		t.Errorf("args: %s", got)
	}
}

func TestSigningKey(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not on PATH")
	}
	dir := t.TempDir()
	t.Chdir(dir)
	config := filepath.Join(dir, "gitconfig")
	t.Setenv("GIT_CONFIG_GLOBAL", config)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	if _, err := signingKey(context.Background()); err == nil || !strings.Contains(err.Error(), "-recipient") {
		t.Errorf("no key set: got %v", err)
	}
	if err := os.WriteFile(config, []byte("[user]\n\tsigningkey = ABC123\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	key, err := signingKey(context.Background())
	if err != nil || key != "ABC123" {
		t.Errorf("got %q, %v", key, err)
	}
}

// TestRealGPG runs gnupg against a real gpg with a throwaway key.
func TestRealGPG(t *testing.T) {
	for _, tool := range []string{"gpg", "gpg-agent", "gpgconf"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s is not on PATH", tool)
		}
	}
	// Short, since a socket's path has a limit, and t.TempDir's can pass it.
	home, err := os.MkdirTemp("", "gpg")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("GNUPGHOME", home)
	if err := os.Chmod(home, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = exec.Command("gpgconf", "--kill", "gpg-agent").Run()
		os.RemoveAll(home)
	})
	gen := exec.Command("gpg", "--batch", "--passphrase", "", "--quick-generate-key", "state-test@example.invalid", "default", "default", "1d")
	if out, err := gen.CombinedOutput(); err != nil {
		t.Fatalf("generating a key: %v: %s", err, out)
	}

	ctx := context.Background()
	g := gnupg{}
	file := filepath.Join(t.TempDir(), "f.gpg")
	out, err := os.Create(file)
	if err != nil {
		t.Fatal(err)
	}
	plaintext := []byte(testKeyValue)
	if err := g.encrypt(ctx, "state-test@example.invalid", plaintext, out); err != nil {
		t.Fatal(err)
	}
	out.Close()
	raw, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, plaintext) {
		t.Error("the file holds the plaintext")
	}
	got, err := g.decrypt(ctx, file)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, plaintext) {
		t.Error("decrypted something else")
	}

	out2, err := os.Create(file + "2")
	if err != nil {
		t.Fatal(err)
	}
	defer out2.Close()
	if err := g.encrypt(ctx, "nobody@example.invalid", plaintext, out2); err == nil {
		t.Error("encrypted to a key that does not exist")
	}
	if err := os.WriteFile(file, []byte("not gpg"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := g.decrypt(ctx, file); err == nil {
		t.Error("decrypted garbage")
	}
}

func TestKubectlKeepsValuesOutOfArgumentsAndUsesItsOwnKubeconfig(t *testing.T) {
	args, stdin := fakeKubectl(t, "")
	k := &kubectl{kubeconfig: "/the/clusters/kubeconfig"}
	if err := k.createSecret(context.Background(), anthropicSecret(testKeyValue)); err != nil {
		t.Fatal(err)
	}
	gotArgs, err := os.ReadFile(args)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(gotArgs), "--kubeconfig /the/clusters/kubeconfig") {
		t.Errorf("args: %s", gotArgs)
	}
	gotStdin, err := os.ReadFile(stdin)
	if err != nil {
		t.Fatal(err)
	}
	var s secret
	if err := json.Unmarshal(gotStdin, &s); err != nil {
		t.Fatal(err)
	}
	if string(s.Data["ANTHROPIC_API_KEY"]) != testKeyValue {
		t.Error("the value did not reach kubectl on stdin")
	}
	encoded, _ := json.Marshal(s.Data["ANTHROPIC_API_KEY"])
	if strings.Contains(string(gotArgs), testKeyValue) || strings.Contains(string(gotArgs), strings.Trim(string(encoded), `"`)) {
		t.Error("the value reached kubectl's arguments")
	}
}

func TestErrorsCarryNoValues(t *testing.T) {
	live := liveCluster(t)
	live.secrets[rootID] = rootSecret(t, "cartography")
	a, _ := newApp(t, live, &fakeGPG{})
	err := a.save(context.Background())
	if err == nil {
		t.Fatal("want an error")
	}
	if strings.Contains(err.Error(), testKeyValue) || strings.Contains(err.Error(), "BEGIN") {
		t.Errorf("error carries data: %v", err)
	}
	if _, _, err := decodeState([]byte(testKeyValue+`{"not json`), testCluster); err == nil || strings.Contains(err.Error(), testKeyValue) {
		t.Errorf("error carries data: %v", err)
	}
}

func TestRunRefusesBadInvocations(t *testing.T) {
	ctx := context.Background()
	var out, errOut bytes.Buffer
	wantError(t, run(ctx, nil, &out, &errOut), "a verb is required")
	wantError(t, run(ctx, []string{"backup"}, &out, &errOut), "unknown verb")
	wantError(t, run(ctx, []string{"save"}, &out, &errOut), "-cluster is required")
	wantError(t, run(ctx, []string{"save", "-cluster", "../x"}, &out, &errOut), "not a cluster name")
	t.Setenv("HOME", t.TempDir())
	t.Setenv("HOLOS_TALOS_DIR", "")
	wantError(t, run(ctx, []string{"restore", "-cluster", "nope"}, &out, &errOut), "kubeconfig for cluster nope")
}

func TestHelpSaysWhenEachVerbRuns(t *testing.T) {
	var out, errOut bytes.Buffer
	if err := run(context.Background(), []string{"-h"}, &out, &errOut); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"LAST step before destroying the cluster", "BEFORE the root Application", "Rebuilding a cluster"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("help does not say %q", want)
		}
	}
}
