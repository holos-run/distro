package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// save reads every target, writes the file, and proves the file can be read.
// It runs last before the cluster is destroyed, so every failure stops it with
// no file installed: the operator has to see it before the cluster is gone.
func (a *app) save(ctx context.Context) error {
	o := a.opts
	if err := a.checkCluster(ctx); err != nil {
		return err
	}
	skips, err := parseSkips(o.skips)
	if err != nil {
		return err
	}
	ts := targets(o.platformNamespace)
	if err := checkSkips(skips, identities(ts)); err != nil {
		return err
	}
	replace := false
	if _, err := os.Stat(o.file); err == nil {
		if !o.force {
			return existsError(o.file)
		}
		replace = true
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	recipient := o.recipient
	if recipient == "" {
		if recipient, err = signingKey(ctx); err != nil {
			return err
		}
	}

	// Every target is read before any failure is reported, so one run names
	// everything that is wrong.
	var secrets []*secret
	var problems []string
	for _, t := range ts {
		if skips[t.id] {
			continue
		}
		s, err := a.kube.getSecret(ctx, t.id.namespace, t.id.name)
		if err != nil {
			return err
		}
		if s == nil {
			problems = append(problems, fmt.Sprintf("%s does not exist (-skip %s leaves it out)", t.id, t.id))
			continue
		}
		if err := t.check(a, s); err != nil {
			problems = append(problems, fmt.Sprintf("%v (-skip %s leaves it out)", err, t.id))
			continue
		}
		secrets = append(secrets, s)
	}
	if len(problems) > 0 {
		return fmt.Errorf("nothing written:\n  %s", strings.Join(problems, "\n  "))
	}
	if len(secrets) == 0 {
		return errors.New("nothing written: every resource is skipped")
	}

	if replace {
		if err := a.checkPrior(ctx, secrets); err != nil {
			return err
		}
	}

	plaintext, err := encodeState(o.cluster, a.now(), secrets)
	if err != nil {
		return err
	}
	kept, err := a.writeFile(ctx, recipient, plaintext, replace)
	if err != nil {
		return err
	}

	fmt.Fprintf(a.stdout, "Saved cluster %s to %s, encrypted to %s and checked by decrypting it.\n", o.cluster, o.file, recipient)
	if kept != "" {
		fmt.Fprintf(a.stdout, "  kept     the old file as %s\n", kept)
	}
	for _, s := range secrets {
		fmt.Fprintf(a.stdout, "  saved    %s%s\n", s.id(), a.rootNote(s))
	}
	for _, t := range ts {
		if skips[t.id] {
			fmt.Fprintf(a.stdout, "  skipped  %s\n", t.id)
		}
	}
	fmt.Fprintf(a.stdout, "\nNext: destroy the cluster. This save must be the last step before talosvm destroy -yes:\n"+
		"anything that changes on the cluster from here on is lost.\n"+
		"\nThen restore in Bootstrap Argo CD, after the management namespaces and the Ceph key and\n"+
		"before the root Application. That section runs from the repository's holos/ directory:\n"+
		"  go run ../cmd/state restore%s\n"+
		"holos/README.md, Rebuilding a cluster, walks through the rest.\n", o.restoreFlags())
	return nil
}

// existsError stops a save at a file that is already there, saying when
// replacing it is right, since one case is not.
func existsError(file string) error {
	return fmt.Errorf("%s exists. If this cluster was restored from it, or has been saved to it before, "+
		"-force replaces it and keeps it as %s.<UTC timestamp>. If this cluster was rebuilt without a "+
		"restore, do not save: that file holds the root your clients trust (holos/README.md, What goes wrong)", file, file)
}

// checkPrior guards the file -force is about to replace, which may be the only
// copy of the root every client trusts. Comparing public keys rather than
// certificates lets a renewal in place through, which keeps the key. If either
// side has no root, it was skipped, and there is nothing to compare.
func (a *app) checkPrior(ctx context.Context, secrets []*secret) error {
	file := a.opts.file
	plaintext, err := a.gpg.decrypt(ctx, file)
	if err != nil {
		return fmt.Errorf("%s cannot be decrypted, so -force will not replace it. Run this in an attach-gpg "+
			"tmux pane, which unlocks the key. To give up on the file, move it aside yourself: %w", file, err)
	}
	_, prior, err := decodeState(plaintext, a.opts.cluster)
	if err != nil {
		return fmt.Errorf("%s cannot be read, so -force will not replace it. To give up on the file, move it aside yourself: %w", file, err)
	}
	oldRoot, newRoot := findRoot(prior), findRoot(secrets)
	if oldRoot == nil || newRoot == nil {
		return nil
	}
	oldLeaf, err := parseKeyPair(oldRoot)
	if err != nil {
		return fmt.Errorf("%s: its root: %w", file, err)
	}
	newLeaf, err := parseKeyPair(newRoot)
	if err != nil {
		return fmt.Errorf("the cluster's root: %w", err)
	}
	if !bytes.Equal(oldLeaf.RawSubjectPublicKeyInfo, newLeaf.RawSubjectPublicKeyInfo) {
		return fmt.Errorf("this cluster has a different root from the one saved in %s, so it was probably rebuilt "+
			"without restoring. Do not save: rebuild it and restore that file (holos/README.md, What goes wrong). "+
			"To take this cluster's root on purpose, move the file aside yourself", file)
	}
	return nil
}

func findRoot(secrets []*secret) *secret {
	for _, s := range secrets {
		if s.id() == (identity{rootNamespace, rootName}) {
			return s
		}
	}
	return nil
}

// checkCluster proves the kubeconfig belongs to -cluster before anything else
// happens, since everything after it trusts that the two agree.
func (a *app) checkCluster(ctx context.Context) error {
	name, err := a.kube.clusterName(ctx)
	if err != nil {
		return fmt.Errorf("reading the kubeconfig's cluster: %w", err)
	}
	if name != a.opts.cluster {
		return fmt.Errorf("the kubeconfig selects cluster %q, not %q: nothing read or written", name, a.opts.cluster)
	}
	return nil
}

// restoreFlags is the restore command's flags, carrying what this save was
// given: a restore without them would look in the wrong place. Paths are
// absolute, since the restore runs from another directory.
func (o options) restoreFlags() string {
	args := []string{"-cluster", o.cluster}
	if o.fileSet {
		args = append(args, "-file", absolute(o.file))
	}
	if o.kubeconfigSet {
		args = append(args, "-kubeconfig", absolute(o.kubeconfig))
	}
	if o.platformNamespaceSet {
		args = append(args, "-platform-namespace", o.platformNamespace)
	}
	for _, s := range o.skips {
		args = append(args, "-skip", s)
	}
	var b strings.Builder
	for _, arg := range args {
		b.WriteString(" " + shellQuote(arg))
	}
	return b.String()
}

func absolute(path string) string {
	if abs, err := filepath.Abs(path); err == nil {
		return abs
	}
	return path
}

// shellQuote leaves ordinary words alone, so the usual command reads plainly.
func shellQuote(s string) string {
	if s != "" && strings.IndexFunc(s, func(r rune) bool {
		return !(r == '-' || r == '_' || r == '.' || r == '/' || r == '~' ||
			'0' <= r && r <= '9' || 'a' <= r && r <= 'z' || 'A' <= r && r <= 'Z')
	}) < 0 {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// rootNote is the root's fingerprint, for the one resource that has one.
func (a *app) rootNote(s *secret) string {
	if s.id() != (identity{rootNamespace, rootName}) {
		return ""
	}
	fp, err := fingerprint(s)
	if err != nil {
		return ""
	}
	return "  root SHA-256 " + fp
}

// writeFile encrypts beside the target, proves the temporary file decrypts to
// exactly the plaintext, and only then puts it in place. The check needs the
// secret key, which encrypting does not: without it a save could pass and
// leave a file nobody can open, found out once the cluster is gone.
//
// It returns the name the old file was kept under, when it replaced one.
func (a *app) writeFile(ctx context.Context, recipient string, plaintext []byte, replace bool) (string, error) {
	file := a.opts.file
	dir := filepath.Dir(file)
	// CreateTemp makes it 0600, and it holds only ciphertext.
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(file)+".tmp-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp.Name())
	defer tmp.Close()

	if err := a.gpg.encrypt(ctx, recipient, plaintext, tmp); err != nil {
		return "", err
	}
	if err := tmp.Sync(); err != nil {
		return "", err
	}
	got, err := a.gpg.decrypt(ctx, tmp.Name())
	if err != nil {
		return "", fmt.Errorf("nothing written: the file could not be decrypted, so it could not be restored. "+
			"Run this in an attach-gpg tmux pane, which unlocks the key, and check that %s is yours: %w", recipient, err)
	}
	if !bytes.Equal(got, plaintext) {
		return "", errors.New("nothing written: the file decrypted to something other than what was saved")
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	kept := ""
	if replace {
		if kept, err = keepGeneration(file, a.now().UTC().Format("20060102T150405Z")); err != nil {
			return "", err
		}
		err = os.Rename(tmp.Name(), file)
	} else {
		err = install(tmp.Name(), file)
	}
	if err != nil {
		return "", err
	}
	return kept, syncDir(dir)
}

// keepGeneration links file to a name of its own, so no save ever deletes one.
// The target never goes missing: the link comes first, and the rename after
// it replaces the name atomically. Two saves in one second get different names.
func keepGeneration(file, stamp string) (string, error) {
	for i := 0; ; i++ {
		name := file + "." + stamp
		if i > 0 {
			name = fmt.Sprintf("%s-%d", name, i)
		}
		err := os.Link(file, name)
		if err == nil {
			return name, nil
		}
		if !errors.Is(err, fs.ErrExist) {
			return "", err
		}
	}
}

// install links the finished file into place, which fails if the target
// exists, so a save cannot overwrite a file that appeared after the first
// check.
func install(tmp, file string) error {
	if err := os.Link(tmp, file); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return existsError(file)
		}
		return err
	}
	return nil
}

func syncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
