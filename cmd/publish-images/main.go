// Command publish-images builds the Substrate and kagent images and kagent's
// charts from the holos-run forks at two pinned commits, pushes them under one
// registry prefix, and reports the digest of everything it pushed. It is what
// .github/workflows/publish-images.yaml runs, and it runs the same way on a
// workstation against a local registry.
//
//	go run ./cmd/publish-images -substrate-sha <sha> -kagent-sha <sha> [flags]
//
// Each fork is cloned at its SHA, which must be on one of the fork's holos-*
// branches (docs/forks.md), and is tagged with
// 0.0.0-holos.<YYYYMMDD>.<7-character SHA>, from the commit's date; Substrate's
// tag carries a v as its release-tag check requires.
//
// Substrate is built by its own `ate-setup publish release-images`, with
// KO_DOCKER_REPO=<registry>/substrate: the ko images and the envoy-dataplane
// image, every one for every -platforms entry. ko is the fork's pinned Go
// tool, so nothing needs installing beyond Go and docker. The command runs
// with overwrite on, so it builds and pushes every time, and what it reports
// pushing must be exactly the images the fork's
// cmd/ate-setup/internal/images/images.go lists for a release.
//
// kagent is built by its own Makefile: `make build-controller` and `make
// build-ui` push <registry>/kagent/controller and <registry>/kagent/ui, each
// with its reference set on the command line and buildx's metadata file giving
// the digest it pushed, and `make helm-version` packages the kagent and
// kagent-crds charts, which helm push sends to oci://<registry>/kagent/helm. The harness images kagent's release
// packaging wants are not built; the platform takes them from kagent's own
// registry. The CLI is not built either.
//
// Both builds use the current buildx builder, so the caller decides how images
// are built: the workflow sets up QEMU and a docker-container builder, which
// kagent's controller image needs for arm64. Registry credentials are docker's,
// which ko, buildx, imagetools and helm all read.
//
// Every pushed tag is then resolved in the registry with `docker buildx
// imagetools inspect`, checked to hold every platform, and checked against the
// digest the build reported pushing: ko's and buildx's for Substrate, buildx's
// metadata for kagent's images, and helm push's for the charts. The result is printed to stdout, one digest
// reference per line, and written to -out as JSON for the workflow's
// attestation job. A subject without a digest fails the run.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

type options struct {
	substrateSHA  string
	kagentSHA     string
	substrateRepo string
	kagentRepo    string
	registry      string
	platforms     []string
	out           string
	workDir       string
	plainHTTP     bool
}

// build is one fork's part of the result.
type build struct {
	Repository string `json:"repository"`
	SHA        string `json:"sha"`
	Version    string `json:"version"`
}

// subject is one pushed image or chart: what an attestation names and what
// the platform pins.
type subject struct {
	// Name is the repository without a tag, e.g. ghcr.io/holos-run/kagent/ui,
	// the attestation's subject-name.
	Name string `json:"name"`
	// Digest is the manifest or index digest the tag named after the push.
	Digest string `json:"digest"`
	// Ref is Name:tag@Digest.
	Ref string `json:"ref"`
	// Kind is image or chart.
	Kind string `json:"kind"`
	// Fork is substrate or kagent.
	Fork string `json:"fork"`
}

type result struct {
	Registry  string    `json:"registry"`
	Platforms []string  `json:"platforms"`
	Substrate *build    `json:"substrate,omitempty"`
	Kagent    *build    `json:"kagent,omitempty"`
	Subjects  []subject `json:"subjects"`
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err := run(ctx, os.Args[1:], os.Stdout, os.Stderr)
	stop()
	if errors.Is(err, flag.ErrHelp) {
		return
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "publish-images:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	o := &options{}
	var platforms string
	fs := flag.NewFlagSet("publish-images", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&o.substrateSHA, "substrate-sha", "", "full commit SHA to build in the Substrate fork; empty skips Substrate")
	fs.StringVar(&o.kagentSHA, "kagent-sha", "", "full commit SHA to build in the kagent fork; empty skips kagent")
	fs.StringVar(&o.substrateRepo, "substrate-repo", "https://github.com/holos-run/substrate.git", "Substrate fork to clone")
	fs.StringVar(&o.kagentRepo, "kagent-repo", "https://github.com/holos-run/kagent.git", "kagent fork to clone")
	fs.StringVar(&o.registry, "registry", "ghcr.io/holos-run", "registry prefix the images and charts are pushed under")
	fs.StringVar(&platforms, "platforms", "linux/amd64,linux/arm64", "platforms every image is built for, comma separated")
	fs.StringVar(&o.out, "out", "", "file to write the result to as JSON (default: none)")
	fs.StringVar(&o.workDir, "work-dir", "", "directory to clone the forks into, kept afterwards (default: a temporary directory, removed afterwards)")
	fs.BoolVar(&o.plainHTTP, "plain-http", false, "push charts over plain HTTP, for a local test registry; buildx, ko and imagetools already use HTTP for localhost")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return fmt.Errorf("unexpected argument %q", fs.Arg(0))
	}
	if o.substrateSHA == "" && o.kagentSHA == "" {
		fs.Usage()
		return errors.New("nothing to build: give -substrate-sha, -kagent-sha or both")
	}
	if o.substrateSHA != "" {
		if err := checkSHA("substrate-sha", o.substrateSHA); err != nil {
			return err
		}
	}
	if o.kagentSHA != "" {
		if err := checkSHA("kagent-sha", o.kagentSHA); err != nil {
			return err
		}
	}
	if _, _, err := splitRegistry(o.registry); err != nil {
		return err
	}
	for _, p := range strings.Split(platforms, ",") {
		if p = strings.TrimSpace(p); p != "" {
			o.platforms = append(o.platforms, p)
		}
	}
	if len(o.platforms) == 0 {
		return errors.New("-platforms is empty")
	}

	x := &executor{stderr: stderr}
	if err := preflight(ctx, x, o); err != nil {
		return err
	}

	if o.workDir == "" {
		dir, err := os.MkdirTemp("", "publish-images-")
		if err != nil {
			return err
		}
		defer os.RemoveAll(dir)
		o.workDir = dir
	} else if err := os.MkdirAll(o.workDir, 0o755); err != nil {
		return err
	}

	res := &result{Registry: o.registry, Platforms: o.platforms}
	if o.substrateSHA != "" {
		b, subjects, err := publishSubstrate(ctx, x, o)
		if err != nil {
			return fmt.Errorf("substrate: %w", err)
		}
		res.Substrate = b
		res.Subjects = append(res.Subjects, subjects...)
	}
	if o.kagentSHA != "" {
		b, subjects, err := publishKagent(ctx, x, o)
		if err != nil {
			return fmt.Errorf("kagent: %w", err)
		}
		res.Kagent = b
		res.Subjects = append(res.Subjects, subjects...)
	}
	return report(res, o.out, stdout)
}

// preflight fails before anything is cloned or built if a tool is missing or
// the builder cannot build kagent's images for every platform, so a mistake
// in the workflow costs seconds rather than a Substrate build.
func preflight(ctx context.Context, x *executor, o *options) error {
	tools := []string{"git", "go", "docker"}
	if o.kagentSHA != "" {
		// kagent's helm-version target renders Chart.yaml with envsubst.
		tools = append(tools, "make", "helm", "envsubst")
	}
	for _, tool := range tools {
		if _, err := exec.LookPath(tool); err != nil {
			return fmt.Errorf("%s is not installed: %w", tool, err)
		}
	}
	if o.kagentSHA == "" {
		return nil
	}
	// Substrate cross-compiles every image, Rust included, so it needs no
	// emulation. kagent's controller image runs apk in its target stage, so
	// arm64 on an amd64 runner needs QEMU, which shows as a builder platform.
	inspect, err := x.output(ctx, "", nil, "docker", "buildx", "inspect", "--bootstrap")
	if err != nil {
		return err
	}
	name, have := builderPlatforms(string(inspect))
	if missing := unsupported(o.platforms, have); len(missing) > 0 {
		return fmt.Errorf("buildx builder %s cannot build %s for kagent (it has %s); set up QEMU, as docker/setup-qemu-action does",
			name, strings.Join(missing, ", "), strings.Join(have, ", "))
	}
	return nil
}

func report(res *result, out string, stdout io.Writer) error {
	if len(res.Subjects) == 0 {
		return errors.New("nothing was published")
	}
	for _, b := range []struct {
		fork string
		b    *build
	}{{"substrate", res.Substrate}, {"kagent", res.Kagent}} {
		if b.b == nil {
			continue
		}
		fmt.Fprintf(stdout, "%s %s at %s\n", b.fork, b.b.Version, b.b.SHA)
		for _, s := range res.Subjects {
			if s.Fork == b.fork {
				fmt.Fprintf(stdout, "  %s\n", s.Ref)
			}
		}
	}
	if out == "" {
		return nil
	}
	data, err := json.MarshalIndent(res, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(out, append(data, '\n'), 0o644)
}

func logf(w io.Writer, format string, args ...any) {
	fmt.Fprintf(w, "publish-images: "+format+"\n", args...)
}

// elapsed logs how long a step took, for the workflow's log and for sizing
// its timeout.
func elapsed(w io.Writer, start time.Time, what string) {
	logf(w, "%s took %s", what, time.Since(start).Round(time.Second))
}
