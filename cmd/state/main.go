// Command state saves what a cluster holds that a rebuild cannot make again,
// so the cluster can be destroyed, and restores it to the cluster that
// replaces it.
//
//	go run ./cmd/state save -cluster <cluster> [flags]
//	go run ./cmd/state restore -cluster <cluster> [flags]
//
// save is the last step before destroying the cluster. It runs after
// everything else in Tearing a cluster down and right before talosvm destroy
// -yes, since anything that changes on the cluster after it is lost.
//
// restore runs in Bootstrap Argo CD, after the management namespaces and the
// Ceph key and before the root Application. The API answers by then and
// cert-manager does not exist yet, so nothing has issued a competing root.
// Once the root Application is applied, cert-manager generates a new root and
// signs certificates from it, and a restore finds a different Secret and
// refuses. holos/README.md, Rebuilding a cluster, walks through the whole
// rebuild and what to do when a step goes wrong, and each verb prints the next
// step when it finishes.
//
// State today is two Secrets, the private root's and the Anthropic key's
// (targets, in state.go). Other kinds of state are future work: the file
// holds each object as a manifest, and a kind this program does not know is
// an error rather than something silently dropped.
//
// Every resource is required. A missing one fails the verb and writes
// nothing, and -skip <namespace>/<name>, repeatable, is the only way past
// that. A cluster that does not take kagent has no Anthropic key, so
// cartography runs both verbs with -skip
// seabank-prj-platform/anthropic-api-key. A rebuild that changes the cluster's
// domain or the brand wants a new root, and restores with -skip
// cert-manager/private-ca-root.
//
// The file is ~/<cluster>-state.json.gpg, encrypted to the key that signs
// commits, git config user.signingkey, unless -recipient names another.
// Plaintext stays in memory: it reaches gpg and kubectl on stdin, never in
// their arguments or in a file. save decrypts what it wrote and compares it
// before installing the file, since the cluster is destroyed next, so both
// verbs need the secret key unlocked, which attach-gpg does.
//
// A save never deletes a file. -force keeps the old one as
// <file>.<UTC timestamp>, and refuses if the file cannot be decrypted or holds
// a different root from the cluster's: a cluster rebuilt without a restore has
// a new root, and saving it over the good one would lose the root every client
// trusts. To take a new root on purpose, move the file aside by hand.
//
// The program talks to the cluster through kubectl, always with
// -kubeconfig, whose default is the cluster's own admin kubeconfig. The shell's
// KUBECONFIG is never read, and both verbs start by checking that the
// kubeconfig's selected cluster is named -cluster, so neither can act on
// another cluster. -platform-namespace defaults to Bank
// of the Salish Sea's, the brand's default (holos/brand.cue); a distribution
// with another brand passes its own.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

// defaultPlatformNamespace is the management project's namespace,
// <slug>-prj-platform, where platform secrets live.
const defaultPlatformNamespace = "seabank-prj-platform"

const usage = `state saves what a cluster holds that a rebuild cannot make again, and
restores it to the cluster that replaces it.

  go run ./cmd/state save -cluster <cluster> [flags]
  go run ./cmd/state restore -cluster <cluster> [flags]

save is the LAST step before destroying the cluster: run it right before
talosvm destroy -yes. Anything that changes on the cluster after it is lost.

restore runs in Bootstrap Argo CD, AFTER the management namespaces and the Ceph
key and BEFORE the root Application. Once the root Application is applied,
cert-manager generates a new root, and restore refuses.

holos/README.md, Rebuilding a cluster, walks through the whole rebuild. Run
both verbs in an attach-gpg tmux pane: they need the secret key unlocked.

Every resource is required, and a missing one fails the verb and writes nothing.
-skip <namespace>/<name> is the only way past that.
`

// options are the flags both verbs take.
type options struct {
	cluster           string
	kubeconfig        string
	file              string
	recipient         string
	platformNamespace string
	force             bool
	skips             []string

	// The flags the operator gave, which the restore command a save prints
	// has to carry along.
	fileSet, kubeconfigSet, platformNamespaceSet bool
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err := run(ctx, os.Args[1:], os.Stdout, os.Stderr)
	stop()
	if errors.Is(err, flag.ErrHelp) {
		return
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "state:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return errors.New("a verb is required: save or restore")
	}
	verb := args[0]
	switch verb {
	case "save", "restore":
	case "-h", "-help", "--help", "help":
		fmt.Fprint(stdout, usage)
		return nil
	default:
		fmt.Fprint(stderr, usage)
		return fmt.Errorf("unknown verb %q: want save or restore", verb)
	}

	var o options
	fs := flag.NewFlagSet(verb, flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.Usage = func() {
		fmt.Fprint(stderr, usage)
		fmt.Fprintf(stderr, "\nFlags of %s:\n", verb)
		fs.PrintDefaults()
	}
	fs.StringVar(&o.cluster, "cluster", "", "the cluster, as named in clusters.cue (required)")
	fs.StringVar(&o.kubeconfig, "kubeconfig", "", "admin kubeconfig (default ${HOLOS_TALOS_DIR:-~/.config/holos/talos}/<cluster>/kubeconfig)")
	fs.StringVar(&o.file, "file", "", "the state file (default ~/<cluster>-state.json.gpg)")
	fs.StringVar(&o.platformNamespace, "platform-namespace", defaultPlatformNamespace, "the management project's namespace, the brand's default")
	if verb == "save" {
		fs.StringVar(&o.recipient, "recipient", "", "gpg key to encrypt to (default git config user.signingkey)")
		fs.BoolVar(&o.force, "force", false, "replace an existing file with the same root, keeping it as <file>.<UTC timestamp>")
	} else {
		fs.BoolVar(&o.force, "force", false, "replace a Secret that holds different data")
	}
	fs.Func("skip", "`namespace/name` of a resource to leave out, repeatable", func(v string) error {
		o.skips = append(o.skips, v)
		return nil
	})
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return fmt.Errorf("unexpected argument %q", fs.Arg(0))
	}
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "file":
			o.fileSet = true
		case "kubeconfig":
			o.kubeconfigSet = true
		case "platform-namespace":
			o.platformNamespaceSet = true
		}
	})
	if err := o.fill(); err != nil {
		return err
	}

	a := &app{
		kube:   &kubectl{kubeconfig: o.kubeconfig},
		gpg:    gnupg{},
		stdout: stdout,
		now:    time.Now,
		opts:   o,
	}
	if verb == "save" {
		return a.save(ctx)
	}
	return a.restore(ctx)
}

var clusterName = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`)

// fill checks the flags and works out the defaults that follow from
// -cluster. The kubeconfig has to exist, since kubectl given a missing one
// reports nothing a reader would connect with a mistyped cluster.
func (o *options) fill() error {
	if o.cluster == "" {
		return errors.New("-cluster is required: there is no default, since a default could name the wrong cluster")
	}
	if !clusterName.MatchString(o.cluster) {
		return fmt.Errorf("-cluster %q is not a cluster name", o.cluster)
	}
	if o.platformNamespace == "" {
		return errors.New("-platform-namespace must not be empty")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	if o.file == "" {
		o.file = filepath.Join(home, o.cluster+"-state.json.gpg")
	}
	if o.kubeconfig == "" {
		dir := os.Getenv("HOLOS_TALOS_DIR")
		if dir == "" {
			dir = filepath.Join(home, ".config", "holos", "talos")
		}
		o.kubeconfig = filepath.Join(dir, o.cluster, "kubeconfig")
	}
	if _, err := os.Stat(o.kubeconfig); err != nil {
		return fmt.Errorf("kubeconfig for cluster %s: %w", o.cluster, err)
	}
	return nil
}

// signingKey is the key that signs commits, the default recipient.
func signingKey(ctx context.Context) (string, error) {
	out, err := exec.CommandContext(ctx, "git", "config", "--get", "user.signingkey").Output()
	key := strings.TrimSpace(string(out))
	if err != nil || key == "" {
		return "", errors.New("git config user.signingkey is not set: pass -recipient")
	}
	return key, nil
}
