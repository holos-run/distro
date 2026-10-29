package main

import (
	"fmt"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"
)

const (
	substratePin = "475f49b023352b47b8504ffead596953f28d7e7f"
	kagentPin    = "fa2cb2361ee45da4b3e757a618128c298680d458"
)

func TestCheckSHA(t *testing.T) {
	if err := checkSHA("substrate-sha", substratePin); err != nil {
		t.Errorf("the Substrate pin was refused: %v", err)
	}
	for _, bad := range []string{
		"",
		"475f49b", // abbreviated
		"475F49B023352B47B8504FFEAD596953F28D7E7F",  // uppercase
		substratePin + "0",                          // 41 characters
		"holos-2026-10-28",                          // a branch
		"475f49b023352b47b8504ffead596953f28d7e7g",  // not hex
		"475f49b023352b47b8504ffead596953f28d7e7f ", // trailing space
	} {
		if err := checkSHA("substrate-sha", bad); err == nil {
			t.Errorf("%q was accepted", bad)
		}
	}
}

func TestVersion(t *testing.T) {
	// The forks' pins on 2026-10-28. kagent's commit date is 14:12 in -07:00,
	// 21:12 UTC; the date is the UTC one.
	substrateDate := time.Date(2026, 10, 28, 19, 50, 31, 0, time.UTC)
	kagentDate := time.Date(2026, 10, 28, 14, 12, 31, 0, time.FixedZone("PDT", -7*3600))
	late := time.Date(2026, 10, 28, 20, 0, 0, 0, time.FixedZone("PDT", -7*3600)) // 03:00 UTC the next day
	for _, tc := range []struct {
		sha  string
		date time.Time
		want string
	}{
		{substratePin, substrateDate, "0.0.0-holos.20261028.475f49b"},
		{kagentPin, kagentDate, "0.0.0-holos.20261028.fa2cb23"},
		{kagentPin, late, "0.0.0-holos.20261029.fa2cb23"},
		// All digits without a leading zero is a valid numeric identifier.
		{"1234567" + substratePin[7:], substrateDate, "0.0.0-holos.20261028.1234567"},
		// With one, SemVer and Helm refuse it.
		{"0412345" + substratePin[7:], substrateDate, "0.0.0-holos.20261028.g0412345"},
		// A leading zero is fine in an identifier holding a letter.
		{"0a12345" + substratePin[7:], substrateDate, "0.0.0-holos.20261028.0a12345"},
	} {
		got := version(tc.sha, tc.date)
		if got != tc.want {
			t.Errorf("version(%s, %s) = %q, want %q", tc.sha[:7], tc.date, got, tc.want)
		}
		// Substrate's release-tag check, images.CheckReleaseVersion.
		if !releaseTag.MatchString("v" + got) {
			t.Errorf("v%s fails Substrate's release-tag check", got)
		}
		if err := checkSemVer(got); err != nil {
			t.Errorf("%s is not a SemVer version: %v", got, err)
		}
	}
}

// releaseTag is Substrate's own pattern, from
// cmd/ate-setup/internal/images/release.go at the pin.
var releaseTag = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$`)

// checkSemVer applies the SemVer 2 prerelease rules Helm enforces on a chart
// version: no empty identifier, and no leading zero in a numeric one.
func checkSemVer(v string) error {
	_, pre, ok := strings.Cut(v, "-")
	if !ok {
		return nil
	}
	for _, id := range strings.Split(pre, ".") {
		if id == "" {
			return fmt.Errorf("empty identifier")
		}
		if strings.Trim(id, "0123456789") == "" && len(id) > 1 && id[0] == '0' {
			return fmt.Errorf("numeric identifier %s has a leading zero", id)
		}
	}
	return nil
}

func TestSplitRegistry(t *testing.T) {
	for _, tc := range []struct{ in, host, path string }{
		{"ghcr.io/holos-run", "ghcr.io", "holos-run"},
		{"localhost:5000/holos-run", "localhost:5000", "holos-run"},
		{"localhost:5000", "localhost:5000", ""},
		{"registry.example/a/b", "registry.example", "a/b"},
	} {
		host, path, err := splitRegistry(tc.in)
		if err != nil || host != tc.host || path != tc.path {
			t.Errorf("splitRegistry(%q) = %q, %q, %v", tc.in, host, path, err)
		}
	}
	for _, bad := range []string{"", "oci://ghcr.io/holos-run", "ghcr.io/holos-run/", "ghcr.io/holos run"} {
		if _, _, err := splitRegistry(bad); err == nil {
			t.Errorf("%q was accepted", bad)
		}
	}
}

func TestRepository(t *testing.T) {
	for in, want := range map[string]string{
		"ghcr.io/holos-run/substrate/ateapi:v0.0.0-holos.20261028.475f49b@sha256:" + strings.Repeat("a", 64): "ghcr.io/holos-run/substrate/ateapi",
		"ghcr.io/holos-run/substrate/ateapi@sha256:" + strings.Repeat("a", 64):                               "ghcr.io/holos-run/substrate/ateapi",
		"localhost:5000/holos-run/kagent/ui:0.0.0-holos.20261028.fa2cb23":                                    "localhost:5000/holos-run/kagent/ui",
		"localhost:5000/holos-run/kagent/ui":                                                                 "localhost:5000/holos-run/kagent/ui",
	} {
		if got := repository(in); got != want {
			t.Errorf("repository(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestReleaseRefs(t *testing.T) {
	const tag = "v0.0.0-holos.20261028.475f49b"
	a, b := "sha256:"+strings.Repeat("a", 64), "sha256:"+strings.Repeat("b", 64)
	// The shape of publish release-images' stdout: buildx's reference for the
	// Dockerfile image first, then ko's.
	stdout := "\nRelease images for " + tag + ":\n" +
		"localhost:5000/holos-run/substrate/envoy-dataplane@" + a + "\n" +
		"localhost:5000/holos-run/substrate/ateapi:" + tag + "@" + b + "\n"
	got, err := releaseRefs(stdout, tag)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"localhost:5000/holos-run/substrate/envoy-dataplane": a,
		"localhost:5000/holos-run/substrate/ateapi":          b,
	}
	if len(got) != len(want) || got["localhost:5000/holos-run/substrate/envoy-dataplane"] != a || got["localhost:5000/holos-run/substrate/ateapi"] != b {
		t.Errorf("got %v, want %v", got, want)
	}

	// The command always builds, so no block is an error.
	if _, err := releaseRefs("", tag); err == nil {
		t.Error("stdout without the block was accepted")
	}
	// Another tag's block is not this one's.
	if _, err := releaseRefs(strings.ReplaceAll(stdout, "for "+tag, "for v1.0.0"), tag); err == nil {
		t.Error("another tag's block was accepted")
	}
	for name, bad := range map[string]string{
		"no digest":  "\nRelease images for " + tag + ":\nlocalhost:5000/holos-run/substrate/ateapi:" + tag + "\n",
		"short":      "\nRelease images for " + tag + ":\nlocalhost:5000/holos-run/substrate/ateapi@sha256:abc\n",
		"duplicate":  stdout + "localhost:5000/holos-run/substrate/ateapi@" + a + "\n",
		"empty list": "\nRelease images for " + tag + ":\n\n",
	} {
		if _, err := releaseRefs(bad, tag); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestHelmPushDigest(t *testing.T) {
	const ref = "localhost:5000/holos-run/kagent/helm/kagent:0.0.0-holos.20261028.fa2cb23"
	d := "sha256:" + strings.Repeat("c", 64)
	out := "Pushed: " + ref + "\nDigest: " + d + "\n"
	if got, err := helmPushDigest(out, ref); err != nil || got != d {
		t.Errorf("got %q, %v", got, err)
	}
	if _, err := helmPushDigest(out, strings.Replace(ref, "kagent:", "kagent-crds:", 1)); err == nil {
		t.Error("a push of another chart was accepted")
	}
	if _, err := helmPushDigest("Pushed: "+ref+"\n", ref); err == nil {
		t.Error("output without a digest was accepted")
	}
}

func TestParseManifest(t *testing.T) {
	// The shape of imagetools inspect --format '{{json .Manifest}}' for an
	// index buildx pushed with its attestation manifests.
	index := `{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "digest": "sha256:3b843e06eeb6a70d3248cd0d222d0a23d48f14836974f9d6faa5b2030fa33082",
  "size": 1607,
  "manifests": [
    {"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:5ed4a40817bbcca3c06cb09458f9b37e4500accb6b83d7428d66344927cf084a", "size": 475, "platform": {"architecture": "amd64", "os": "linux"}},
    {"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:90c880cdccaa8ee855f469e845cff8f43870a087cc2006f1fcd2394b86a779f7", "size": 475, "platform": {"architecture": "arm64", "os": "linux", "variant": "v8"}},
    {"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:5c07dc6ca763069e38831375207a187bc66431b5995a3eae987bfc2f40f3244f", "size": 835, "platform": {"architecture": "unknown", "os": "unknown"}}
  ]
}`
	m, err := parseManifest([]byte(index))
	if err != nil {
		t.Fatal(err)
	}
	if !m.isIndex() || m.Digest != "sha256:3b843e06eeb6a70d3248cd0d222d0a23d48f14836974f9d6faa5b2030fa33082" {
		t.Errorf("got %+v", m)
	}
	if missing := m.missingPlatforms([]string{"linux/amd64", "linux/arm64"}); len(missing) != 0 {
		t.Errorf("missing %v", missing)
	}
	if missing := m.missingPlatforms([]string{"linux/arm64/v8", "linux/s390x"}); !slices.Equal(missing, []string{"linux/s390x"}) {
		t.Errorf("missing %v, want linux/s390x", missing)
	}

	// A chart: one manifest, no platforms.
	chart := `{"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:4d2119d22becade968d58bf4d2872ba6bad7e7622d7d151bb632f58a49d8efa0", "size": 587}`
	if m, err := parseManifest([]byte(chart)); err != nil || m.isIndex() {
		t.Errorf("chart: %+v, %v", m, err)
	}
	if _, err := parseManifest([]byte(`{"mediaType": "application/vnd.oci.image.manifest.v1+json"}`)); err == nil {
		t.Error("a manifest without a digest was accepted")
	}
}

func TestBuilderPlatforms(t *testing.T) {
	// docker buildx inspect --bootstrap of a docker-container builder with
	// QEMU, abridged. The node has a Name line of its own.
	inspect := `Name:          builder-3f2c
Driver:        docker-container
Last Activity: 2026-10-28 22:17:23 +0000 UTC

Nodes:
Name:                  builder-3f2c0
Endpoint:              unix:///var/run/docker.sock
Status:                running
BuildKit version:      v0.33.1
Platforms:             linux/amd64*, linux/arm64*, linux/amd64/v2, linux/386, linux/arm/v7
Labels:
 org.mobyproject.buildkit.worker.executor:         oci
`
	name, have := builderPlatforms(inspect)
	if name != "builder-3f2c" {
		t.Errorf("name %q", name)
	}
	if want := []string{"linux/amd64", "linux/arm64", "linux/amd64/v2", "linux/386", "linux/arm/v7"}; !slices.Equal(have, want) {
		t.Errorf("platforms %q, want %q", have, want)
	}
	if missing := unsupported([]string{"linux/amd64", "linux/arm64"}, have); len(missing) != 0 {
		t.Errorf("missing %v", missing)
	}
	if missing := unsupported([]string{"linux/arm64", "linux/arm"}, []string{"linux/amd64", "linux/amd64/v2", "linux/arm/v7"}); !slices.Equal(missing, []string{"linux/arm64"}) {
		t.Errorf("missing %v, want linux/arm64", missing)
	}
}
