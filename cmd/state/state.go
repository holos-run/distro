package main

import (
	"bytes"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"
)

const (
	// fileVersion is the state file's format. A restore refuses any other.
	fileVersion = 1

	secretAPIVersion = "v1"
	secretKind       = "Secret"

	rootNamespace = "cert-manager"
	rootName      = "private-ca-root"
)

// app is one run of a verb. kubectl and gnupg implement its interfaces; the
// tests use fakes.
type app struct {
	kube   kube
	gpg    crypter
	stdout io.Writer
	now    func() time.Time
	opts   options
}

// identity is what names a resource, here and in -skip.
type identity struct {
	namespace string
	name      string
}

func (i identity) String() string { return i.namespace + "/" + i.name }

// target is one resource a cluster must carry through a rebuild.
type target struct {
	id identity
	// check refuses a Secret that would not do its job once restored.
	check func(a *app, s *secret) error
	// conflict is added to the refusal when the cluster holds a Secret with
	// different data, and says what that means for this resource.
	conflict string
}

// targets is every resource that is state. Adding one here is all it takes to
// save and restore another Secret. A new kind of state also needs a case in
// decodeResources, and a read and a write in kube.
func targets(platformNamespace string) []target {
	return []target{
		{
			id:    identity{rootNamespace, rootName},
			check: checkRoot,
			conflict: "the cluster already has a different root, so the root Application was applied before " +
				"this restore, and certificates are already signed by the new root. Do not save: tear this " +
				"cluster down without saving and rebuild, restoring this file (holos/README.md, What goes wrong)",
		},
		{
			id:    identity{platformNamespace, "anthropic-api-key"},
			check: checkAnthropic,
			conflict: "someone has already entered a different key. Delete the Secret to restore the saved one, " +
				"or skip this resource to keep the one on the cluster",
		},
	}
}

// checkRoot makes sure the private root is whole, is a root, and is the one
// this cluster's name says it should be. The common name catches a Secret
// holding another cluster's root, such as one restored there by hand or a file
// edited or put together by hand; it is not what proves the kubeconfig is
// right, which is checkCluster's job.
func checkRoot(a *app, s *secret) error {
	for _, k := range []string{"ca.crt", "tls.crt", "tls.key"} {
		if len(s.Data[k]) == 0 {
			return fmt.Errorf("%s: key %s is missing or empty", s.id(), k)
		}
	}
	leaf, err := parseKeyPair(s)
	if err != nil {
		return fmt.Errorf("%s: %w", s.id(), err)
	}
	if !leaf.IsCA {
		return fmt.Errorf("%s: certificate is not a CA", s.id())
	}
	if err := checkCACert(s, leaf); err != nil {
		return err
	}
	now := a.now()
	if now.Before(leaf.NotBefore) || now.After(leaf.NotAfter) {
		return fmt.Errorf("%s: certificate is valid from %s to %s, not now",
			s.id(), leaf.NotBefore.Format(time.RFC3339), leaf.NotAfter.Format(time.RFC3339))
	}
	want := " " + a.opts.cluster + " root CA"
	if !strings.HasSuffix(leaf.Subject.CommonName, want) {
		return fmt.Errorf("%s: common name %q does not end in %q: this is another cluster's root",
			s.id(), leaf.Subject.CommonName, want)
	}
	return nil
}

// checkCACert holds ca.crt to what a self-signed root's Secret has: the root
// itself. ca.crt is what trust-manager copies to every namespace.
func checkCACert(s *secret, leaf *x509.Certificate) error {
	block, _ := pem.Decode(s.Data["ca.crt"])
	if block == nil {
		return fmt.Errorf("%s: ca.crt is not a PEM certificate", s.id())
	}
	ca, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return fmt.Errorf("%s: ca.crt cannot be parsed: %w", s.id(), err)
	}
	if !ca.Equal(leaf) {
		return fmt.Errorf("%s: ca.crt is not the certificate in tls.crt, as a self-signed root's must be", s.id())
	}
	return nil
}

// parseKeyPair returns the certificate after checking the key belongs to it.
// Neither failure repeats any of the data.
func parseKeyPair(s *secret) (*x509.Certificate, error) {
	pair, err := tls.X509KeyPair(s.Data["tls.crt"], s.Data["tls.key"])
	if err != nil {
		return nil, fmt.Errorf("tls.crt and tls.key are not a key pair: %w", err)
	}
	return x509.ParseCertificate(pair.Certificate[0])
}

func checkAnthropic(_ *app, s *secret) error {
	if len(bytes.TrimSpace(s.Data["ANTHROPIC_API_KEY"])) == 0 {
		return fmt.Errorf("%s: key ANTHROPIC_API_KEY is missing or empty", s.id())
	}
	return nil
}

// fingerprint is the certificate's SHA-256, in the form openssl prints it, so
// a reader can compare it with `openssl x509 -fingerprint -sha256`.
func fingerprint(s *secret) (string, error) {
	leaf, err := parseKeyPair(s)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(leaf.Raw)
	parts := make([]string, len(sum))
	for i, b := range sum {
		parts[i] = fmt.Sprintf("%02X", b)
	}
	return strings.Join(parts, ":"), nil
}

// parseSkips turns -skip values into identities. Only the form is checked
// here, since what a restore may skip depends on the file: see checkSkips.
func parseSkips(values []string) (map[identity]bool, error) {
	skips := map[identity]bool{}
	for _, v := range values {
		namespace, name, ok := strings.Cut(v, "/")
		if !ok || namespace == "" || name == "" || strings.Contains(name, "/") {
			return nil, fmt.Errorf("-skip %q: want <namespace>/<name>", v)
		}
		skips[identity{namespace, name}] = true
	}
	return skips, nil
}

// checkSkips refuses a skip that names nothing. A typo would otherwise leave
// the failure it meant to allow, and read as a mistake about something else.
func checkSkips(skips map[identity]bool, known []identity) error {
	names := make([]string, 0, len(known))
	found := map[identity]bool{}
	for _, id := range known {
		found[id] = true
		names = append(names, id.String())
	}
	sort.Strings(names)
	for id := range skips {
		if !found[id] {
			return fmt.Errorf("-skip %s matches nothing: known resources are %s", id, strings.Join(names, ", "))
		}
	}
	return nil
}

func identities(ts []target) []identity {
	ids := make([]identity, len(ts))
	for i, t := range ts {
		ids[i] = t.id
	}
	return ids
}

// stateFile is the plaintext of the file. Each resource is a Kubernetes
// manifest, so a person with gpg and kubectl can recover by hand.
type stateFile struct {
	Version   int               `json:"version"`
	Cluster   string            `json:"cluster"`
	SavedAt   time.Time         `json:"savedAt"`
	Resources []json.RawMessage `json:"resources"`
}

func encodeState(cluster string, at time.Time, secrets []*secret) ([]byte, error) {
	f := stateFile{Version: fileVersion, Cluster: cluster, SavedAt: at.UTC()}
	for _, s := range secrets {
		raw, err := json.Marshal(s)
		if err != nil {
			return nil, err
		}
		f.Resources = append(f.Resources, raw)
	}
	return json.MarshalIndent(f, "", "  ")
}

// decodeState parses and checks the file. It reports where the plaintext goes
// wrong without quoting it.
func decodeState(plaintext []byte, cluster string) (*stateFile, []*secret, error) {
	var f stateFile
	if err := json.Unmarshal(plaintext, &f); err != nil {
		return nil, nil, errors.New("the file's plaintext is not a state file")
	}
	if f.Version != fileVersion {
		return nil, nil, fmt.Errorf("the file has version %d, and this program reads version %d", f.Version, fileVersion)
	}
	if f.Cluster != cluster {
		return nil, nil, fmt.Errorf("the file was saved from cluster %q, not %q", f.Cluster, cluster)
	}
	secrets, err := decodeResources(f.Resources)
	if err != nil {
		return nil, nil, err
	}
	return &f, secrets, nil
}

// decodeResources refuses a kind it does not know, rather than restore part of
// a file written by a later version of this program.
func decodeResources(raw []json.RawMessage) ([]*secret, error) {
	var out []*secret
	seen := map[identity]bool{}
	for i, r := range raw {
		var head struct {
			APIVersion string `json:"apiVersion"`
			Kind       string `json:"kind"`
		}
		if err := json.Unmarshal(r, &head); err != nil {
			return nil, fmt.Errorf("resource %d of the file cannot be read", i)
		}
		if head.APIVersion != secretAPIVersion || head.Kind != secretKind {
			return nil, fmt.Errorf("resource %d of the file is %s %s, which this program cannot restore", i, head.APIVersion, head.Kind)
		}
		var s secret
		if err := json.Unmarshal(r, &s); err != nil {
			return nil, fmt.Errorf("resource %d of the file cannot be read", i)
		}
		if s.Metadata.Namespace == "" || s.Metadata.Name == "" {
			return nil, fmt.Errorf("resource %d of the file has no namespace or no name", i)
		}
		if seen[s.id()] {
			return nil, fmt.Errorf("the file holds %s twice", s.id())
		}
		seen[s.id()] = true
		out = append(out, &s)
	}
	return out, nil
}
