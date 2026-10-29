package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
)

// kagentImages are the kagent images the platform runs from the fork, which
// carries the router dialer change; the sandbox guest and harness images carry
// no fork change and come from kagent's own registry. kagentCharts are
// packaged by make helm-version, kagent-crds first as kagent's release does.
var (
	kagentImages = []kagentImage{
		{name: "controller", target: "build-controller", imgVar: "CONTROLLER_IMG", tagVar: "CONTROLLER_IMAGE_TAG"},
		{name: "ui", target: "build-ui", imgVar: "UI_IMG", tagVar: "UI_IMAGE_TAG"},
	}
	kagentCharts = []string{"kagent-crds", "kagent"}
)

// kagentImage is one image kagent's Makefile builds: its name under
// <registry>/kagent, its make target, and the variables naming its reference
// and its tag.
type kagentImage struct{ name, target, imgVar, tagVar string }

// executor runs the build tools, with their output on stderr so stdout
// carries only the result.
type executor struct {
	stderr io.Writer
}

func (x *executor) command(ctx context.Context, dir string, env []string, stdout io.Writer, name string, args ...string) *exec.Cmd {
	logf(x.stderr, "+ %s %s", name, strings.Join(args, " "))
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	cmd.Env = env
	cmd.Stdout, cmd.Stderr = stdout, x.stderr
	return cmd
}

func (x *executor) run(ctx context.Context, dir string, env []string, name string, args ...string) error {
	if err := x.command(ctx, dir, env, x.stderr, name, args...).Run(); err != nil {
		return fmt.Errorf("%s %s: %w", name, strings.Join(args, " "), err)
	}
	return nil
}

// output returns the command's stdout.
func (x *executor) output(ctx context.Context, dir string, env []string, name string, args ...string) ([]byte, error) {
	var out bytes.Buffer
	if err := x.command(ctx, dir, env, &out, name, args...).Run(); err != nil {
		return nil, fmt.Errorf("%s %s: %w", name, strings.Join(args, " "), err)
	}
	return out.Bytes(), nil
}

// tee returns the command's stdout and copies it to stderr, so it is in the
// log as well.
func (x *executor) tee(ctx context.Context, dir string, env []string, name string, args ...string) ([]byte, error) {
	var out bytes.Buffer
	if err := x.command(ctx, dir, env, io.MultiWriter(&out, x.stderr), name, args...).Run(); err != nil {
		return nil, fmt.Errorf("%s %s: %w", name, strings.Join(args, " "), err)
	}
	return out.Bytes(), nil
}

// forkEnv is the environment the forks' builds run in. actions/setup-go
// exports GOTOOLCHAIN=local, which would hold the forks to this module's Go
// version; auto lets each fork's toolchain directive pick the Go that builds
// it, downloaded and checksum-verified by the go command.
// The workflow's step files and the runner's tokens are withheld from them
// (filterEnv).
func forkEnv(extra ...string) []string {
	return append(append(filterEnv(os.Environ()), "GOTOOLCHAIN=auto"), extra...)
}

// clone checks out sha from the fork at url into dir and returns its committer
// date. GitHub serves any commit in a fork network from any of its forks, so a
// SHA fetched by itself could be someone else's; the commit must instead be
// on one of the fork's holos-* branches, which a ruleset keeps from being
// rewritten (docs/forks.md). The fetch is blobless: every commit and tree on
// those branches, and file contents only for the checkout.
func clone(ctx context.Context, x *executor, url, sha, dir string) (time.Time, error) {
	if err := os.RemoveAll(dir); err != nil {
		return time.Time{}, err
	}
	steps := [][]string{
		{"init", "--quiet", dir},
		{"-C", dir, "remote", "add", "origin", url},
		{"-C", dir, "fetch", "--quiet", "--filter=blob:none", "origin", "+refs/heads/holos-*:refs/remotes/origin/holos-*"},
	}
	for _, args := range steps {
		if err := x.run(ctx, "", nil, "git", args...); err != nil {
			return time.Time{}, err
		}
	}
	// A commit the fetch did not bring is on none of the branches.
	if err := x.command(ctx, "", nil, x.stderr, "git", "-C", dir, "cat-file", "-e", sha+"^{commit}").Run(); err != nil {
		return time.Time{}, fmt.Errorf("%s is not on any holos-* branch of %s", sha, url)
	}
	branches, err := x.output(ctx, "", nil, "git", "-C", dir, "branch", "--remotes", "--list", "origin/holos-*", "--contains", sha)
	if err != nil {
		return time.Time{}, err
	}
	if len(bytes.TrimSpace(branches)) == 0 {
		return time.Time{}, fmt.Errorf("%s is not on any holos-* branch of %s", sha, url)
	}
	logf(x.stderr, "%s is on %s", sha, strings.Join(strings.Fields(string(branches)), ", "))
	if err := x.run(ctx, "", nil, "git", "-C", dir, "-c", "advice.detachedHead=false", "checkout", "--quiet", sha); err != nil {
		return time.Time{}, err
	}
	out, err := x.output(ctx, "", nil, "git", "-C", dir, "show", "--no-patch", "--format=%ct", sha)
	if err != nil {
		return time.Time{}, err
	}
	unix, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
	if err != nil {
		return time.Time{}, fmt.Errorf("reading the commit date of %s: %w", sha, err)
	}
	return time.Unix(unix, 0).UTC(), nil
}

// resolve returns what ref names in its registry, read back after the push
// rather than taken from the build's word. An image must be an index holding
// every wanted platform, or, for a single platform, may be one image, as ko
// pushes then.
func resolve(ctx context.Context, x *executor, ref, kind string, platforms []string) (*manifest, error) {
	out, err := x.output(ctx, "", nil, "docker", "buildx", "imagetools", "inspect", ref, "--format", "{{json .Manifest}}")
	if err != nil {
		return nil, err
	}
	m, err := parseManifest(out)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", ref, err)
	}
	if kind != "image" {
		return m, nil
	}
	if m.isIndex() {
		if missing := m.missingPlatforms(platforms); len(missing) > 0 {
			return nil, fmt.Errorf("%s@%s has no image for %s", ref, m.Digest, strings.Join(missing, ", "))
		}
	} else if len(platforms) > 1 {
		return nil, fmt.Errorf("%s@%s is a single %s, not an index of %s", ref, m.Digest, m.MediaType, strings.Join(platforms, ", "))
	}
	return m, nil
}

// pushed resolves name:tag and checks it names the digest the build reported
// pushing, so what is attested is what this run built.
func pushed(ctx context.Context, x *executor, o *options, fork, kind, name, tag, reported string) (subject, error) {
	if reported == "" {
		return subject{}, fmt.Errorf("the build reported no digest for %s:%s", name, tag)
	}
	m, err := resolve(ctx, x, name+":"+tag, kind, o.platforms)
	if err != nil {
		return subject{}, err
	}
	if reported != m.Digest {
		return subject{}, fmt.Errorf("%s:%s names %s, not the pushed %s", name, tag, m.Digest, reported)
	}
	return subject{Name: name, Digest: m.Digest, Ref: name + ":" + tag + "@" + m.Digest, Kind: kind, Fork: fork}, nil
}

func publishSubstrate(ctx context.Context, x *executor, o *options) (*build, []subject, error) {
	dir := filepath.Join(o.workDir, "substrate")
	start := time.Now()
	committed, err := clone(ctx, x, o.substrateRepo, o.substrateSHA, dir)
	if err != nil {
		return nil, nil, err
	}
	b := &build{Repository: o.substrateRepo, SHA: o.substrateSHA, Version: "v" + version(o.substrateSHA, committed)}
	logf(x.stderr, "substrate %s at %s", b.Version, b.SHA)

	src, err := os.ReadFile(filepath.Join(dir, substrateImagesFile))
	if err != nil {
		return nil, nil, err
	}
	images, err := substrateImages(substrateImagesFile, src)
	if err != nil {
		return nil, nil, err
	}

	repo := o.registry + "/substrate"
	var stdout []byte
	err = retryDenied(ctx, x, "substrate", func(x *executor) error {
		stdout, err = x.tee(ctx, dir, forkEnv(
			"KO_DOCKER_REPO="+repo,
			"KO_DEFAULTPLATFORMS="+strings.Join(o.platforms, ","),
			"VERSION="+b.Version,
			// Build and push every time, even when the registry already holds
			// the tag, so the run reports and attests only what it built. A tag
			// may move to a new digest; the platform pins digests, and a digest
			// pinned earlier stays in the registry.
			"ATE_PUBLISH_OVERWRITE=true",
		), "go", "run", "./cmd/ate-setup", "publish", "release-images")
		return err
	})
	if err != nil {
		return nil, nil, err
	}
	elapsed(x.stderr, start, "substrate build")

	reported, err := releaseRefs(string(stdout), b.Version)
	if err != nil {
		return nil, nil, err
	}
	var got, want []string
	for name := range reported {
		got = append(got, name)
	}
	for _, img := range images {
		want = append(want, repo+"/"+img)
	}
	slices.Sort(got)
	slices.Sort(want)
	if !slices.Equal(got, want) {
		return nil, nil, fmt.Errorf("publish release-images pushed\n  %s\nbut %s lists\n  %s",
			strings.Join(got, "\n  "), substrateImagesFile, strings.Join(want, "\n  "))
	}
	var subjects []subject
	for _, name := range want {
		s, err := pushed(ctx, x, o, "substrate", "image", name, b.Version, reported[name])
		if err != nil {
			return nil, nil, err
		}
		subjects = append(subjects, s)
	}
	return b, subjects, nil
}

func publishKagent(ctx context.Context, x *executor, o *options) (*build, []subject, error) {
	dir := filepath.Join(o.workDir, "kagent")
	start := time.Now()
	committed, err := clone(ctx, x, o.kagentRepo, o.kagentSHA, dir)
	if err != nil {
		return nil, nil, err
	}
	elapsed(x.stderr, start, "kagent clone")
	b := &build{Repository: o.kagentRepo, SHA: o.kagentSHA, Version: version(o.kagentSHA, committed)}
	logf(x.stderr, "kagent %s at %s", b.Version, b.SHA)

	// kagent's Makefile names an image $(DOCKER_REGISTRY)/$(DOCKER_REPO)/<name>.
	host, path, _ := splitRegistry(o.registry)
	dockerRepo := "kagent"
	if path != "" {
		dockerRepo = path + "/kagent"
	}
	// The Makefile's buildx-create target makes a builder of its own and
	// switches to it unless BUILDX_BUILDER_NAME names one that exists. Naming
	// the current builder keeps kagent's build on the one the caller set up.
	inspect, err := x.output(ctx, "", nil, "docker", "buildx", "inspect")
	if err != nil {
		return nil, nil, err
	}
	builder, _ := builderPlatforms(string(inspect))
	if builder == "" {
		return nil, nil, fmt.Errorf("docker buildx inspect named no builder")
	}
	var subjects []subject
	for _, img := range kagentImages {
		name := o.registry + "/kagent/" + img.name
		ref := name + ":" + b.Version
		// buildx writes the pushed digest here. The path goes into
		// DOCKER_BUILD_ARGS, which make splits on spaces.
		metadata := filepath.Join(o.workDir, "kagent-"+img.name+".metadata.json")
		if strings.ContainsAny(metadata, " \t\n") {
			return nil, nil, fmt.Errorf("-work-dir %q must not contain whitespace", o.workDir)
		}
		if err := os.Remove(metadata); err != nil && !os.IsNotExist(err) {
			return nil, nil, err
		}
		// Every variable that names the image is set on the command line,
		// which overrides the Makefile and the environment alike, so nothing
		// inherited can send the push elsewhere.
		start = time.Now()
		if err := retryDenied(ctx, x, "kagent "+img.name, func(x *executor) error {
			return x.run(ctx, dir, forkEnv(), "make", img.target,
				"CONTAINER_RUNTIME=docker",
				"VERSION="+b.Version,
				"DOCKER_REGISTRY="+host,
				"DOCKER_REPO="+dockerRepo,
				img.tagVar+"="+b.Version,
				img.imgVar+"="+ref,
				"BUILDX_BUILDER_NAME="+builder,
				"DOCKER_BUILDER=docker buildx build",
				// Substrate labels its images with the commit; the fork's
				// Dockerfiles label only the version, so the revision is added here.
				"DOCKER_BUILD_ARGS=--push --platform "+strings.Join(o.platforms, ",")+
					" --label org.opencontainers.image.revision="+b.SHA+
					" --metadata-file "+metadata,
			)
		}); err != nil {
			return nil, nil, err
		}
		elapsed(x.stderr, start, "kagent "+img.name+" build")
		raw, err := os.ReadFile(metadata)
		if err != nil {
			return nil, nil, fmt.Errorf("buildx wrote no metadata for %s: %w", ref, err)
		}
		digest, err := metadataDigest(raw, ref)
		if err != nil {
			return nil, nil, err
		}
		s, err := pushed(ctx, x, o, "kagent", "image", name, b.Version, digest)
		if err != nil {
			return nil, nil, err
		}
		subjects = append(subjects, s)
	}

	// helm-version, not helm-publish: kagent's release packaging wants the
	// harness images built in the same run, and the chart does without them.
	start = time.Now()
	if err := x.run(ctx, dir, forkEnv(), "make", "helm-version", "VERSION="+b.Version); err != nil {
		return nil, nil, err
	}
	helmRepo := o.registry + "/kagent/helm"
	for _, chart := range kagentCharts {
		tgz := filepath.Join(dir, "dist", chart+"-"+b.Version+".tgz")
		if _, err := os.Stat(tgz); err != nil {
			return nil, nil, fmt.Errorf("make helm-version packaged no %s: %w", filepath.Base(tgz), err)
		}
		// helm reads docker's credentials when its own registry config has
		// none, which kagent's own release relies on too.
		args := []string{"push", tgz, "oci://" + helmRepo}
		if o.plainHTTP {
			args = append(args, "--plain-http")
		}
		// One writer for both streams, so exec writes to it from one
		// goroutine: helm prints the Pushed and Digest lines to stderr.
		var out bytes.Buffer
		if err := retryDenied(ctx, x, "kagent chart "+chart, func(x *executor) error {
			out.Reset()
			w := io.MultiWriter(&out, x.stderr)
			cmd := x.command(ctx, dir, forkEnv(), w, "helm", args...)
			cmd.Stderr = w
			if err := cmd.Run(); err != nil {
				return fmt.Errorf("helm %s: %w", strings.Join(args, " "), err)
			}
			return nil
		}); err != nil {
			return nil, nil, err
		}
		name := helmRepo + "/" + chart
		digest, err := helmPushDigest(out.String(), name+":"+b.Version)
		if err != nil {
			return nil, nil, err
		}
		s, err := pushed(ctx, x, o, "kagent", "chart", name, b.Version, digest)
		if err != nil {
			return nil, nil, err
		}
		subjects = append(subjects, s)
	}
	elapsed(x.stderr, start, "kagent charts")
	return b, subjects, nil
}
