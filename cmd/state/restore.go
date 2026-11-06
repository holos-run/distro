package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"sort"
	"strings"
)

// step is what restore will do with one Secret.
type step struct {
	secret  *secret
	replace bool
	keep    bool
}

// restore checks everything against the cluster before it writes anything, so
// a refusal leaves the cluster as it found it. It runs before the root
// Application, when the cert-manager namespace does not exist yet: a namespace
// missing here is the normal case, and Argo CD's sync adds its labels later.
func (a *app) restore(ctx context.Context) error {
	o := a.opts
	if err := a.checkCluster(ctx); err != nil {
		return err
	}
	skips, err := parseSkips(o.skips)
	if err != nil {
		return err
	}
	if _, err := os.Stat(o.file); errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("%s does not exist: save writes it before the cluster is destroyed (holos/README.md, Rebuilding a cluster)", o.file)
	} else if err != nil {
		return err
	}
	plaintext, err := a.gpg.decrypt(ctx, o.file)
	if err != nil {
		return fmt.Errorf("run this in an attach-gpg tmux pane, which unlocks the key: %w", err)
	}
	f, saved, err := decodeState(plaintext, o.cluster)
	if err != nil {
		return err
	}

	ts := targets(o.platformNamespace)
	known := identities(ts)
	inFile := map[identity]*secret{}
	for _, s := range saved {
		inFile[s.id()] = s
		known = append(known, s.id())
	}
	if err := checkSkips(skips, known); err != nil {
		return err
	}

	var problems []string
	for _, t := range ts {
		if skips[t.id] {
			continue
		}
		s, ok := inFile[t.id]
		if !ok {
			problems = append(problems, fmt.Sprintf("%s is not in the file (-skip %s leaves it out)", t.id, t.id))
			continue
		}
		if err := t.check(a, s); err != nil {
			problems = append(problems, fmt.Sprintf("%v (-skip %s leaves it out)", err, t.id))
		}
	}

	// The preflight: nothing below it writes until all of it has passed.
	var steps []step
	var missing []string
	phases := map[string]string{}
	for _, s := range saved {
		if skips[s.id()] {
			continue
		}
		ns := s.Metadata.Namespace
		phase, seen := phases[ns]
		if !seen {
			if phase, err = a.kube.namespacePhase(ctx, ns); err != nil {
				return err
			}
			phases[ns] = phase
			if phase == "" {
				missing = append(missing, ns)
			}
		}
		if phase == "Terminating" {
			problems = append(problems, fmt.Sprintf("namespace %s is Terminating: wait for it to go, then run this again", ns))
			continue
		}
		st := step{secret: s}
		if phase != "" {
			have, err := a.kube.getSecret(ctx, ns, s.Metadata.Name)
			if err != nil {
				return err
			}
			switch {
			case have == nil:
			case sameContent(have, s):
				st.keep = true
			case o.force:
				st.replace = true
			default:
				problems = append(problems, fmt.Sprintf("%s holds different data: %s", s.id(), conflictNote(ts, s.id())))
				continue
			}
		}
		steps = append(steps, st)
	}
	if len(problems) > 0 {
		return fmt.Errorf("nothing restored:\n  %s", strings.Join(problems, "\n  "))
	}

	for _, ns := range missing {
		// Lost to whatever made the namespace between the check and here,
		// which is fine: the namespace exists, and that was the point.
		if err := a.kube.createNamespace(ctx, ns); err != nil && !errors.Is(err, errAlreadyExists) {
			return fmt.Errorf("creating namespace %s: %w", ns, err)
		}
	}
	for _, st := range steps {
		switch {
		case st.keep:
		case st.replace:
			if err := a.kube.replaceSecret(ctx, st.secret); err != nil {
				return err
			}
		default:
			if err := a.kube.createSecret(ctx, st.secret); err != nil {
				return fmt.Errorf("%w: run this again once the cause is fixed", err)
			}
		}
	}

	if len(steps) == 0 {
		fmt.Fprintf(a.stdout, "Nothing restored to cluster %s: every resource is skipped.\n", o.cluster)
	} else {
		fmt.Fprintf(a.stdout, "Restored cluster %s from %s, saved %s.\n", o.cluster, o.file, f.SavedAt.Format("2006-01-02 15:04 MST"))
	}
	for _, ns := range missing {
		fmt.Fprintf(a.stdout, "  %-10s  namespace %s\n", "created", ns)
	}
	root := false
	for _, st := range steps {
		verb := "created"
		switch {
		case st.keep:
			verb = "left as is"
		case st.replace:
			verb = "REPLACED"
		}
		fmt.Fprintf(a.stdout, "  %-10s  %s%s\n", verb, st.secret.id(), a.rootNote(st.secret))
		root = root || st.secret.id() == identity{rootNamespace, rootName}
	}
	skipped := make([]string, 0, len(skips))
	for id := range skips {
		skipped = append(skipped, id.String())
	}
	sort.Strings(skipped)
	for _, id := range skipped {
		fmt.Fprintf(a.stdout, "  %-10s  %s\n", "skipped", id)
	}
	fmt.Fprintln(a.stdout, "\nNext: apply the AppProject and the root Application (holos/README.md, Bootstrap Argo CD).")
	if root {
		fmt.Fprintln(a.stdout, "Once private-ca-bundle is Healthy, check that the root's fingerprint is the one above.")
	}
	fmt.Fprintln(a.stdout, "holos/README.md, Rebuilding a cluster, walks through the rest.")
	return nil
}

// conflictNote says what a difference means for a known resource.
func conflictNote(ts []target, id identity) string {
	for _, t := range ts {
		if t.id == id {
			return t.conflict
		}
	}
	return "pass -force to replace it"
}
