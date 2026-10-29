package main

import (
	"slices"
	"strings"
	"testing"
)

// imagesGo is the shape of Substrate's cmd/ate-setup/internal/images/images.go
// at the pin, abridged: the released import paths and the Dockerfile images,
// one of them by a package-level variable.
const imagesGo = `package images

import "slices"

var Components = []string{"cmd/ateapi", "demos/counter"}

// released is a comment.
var released = []string{
	"cmd/ateapi",
	"cmd/credential-provider/kubernetes-secrets",
}

func ReleaseComponents() []string { return slices.Clone(released) }

type DockerfileImage struct {
	Name    string
	Context string
}

var EnvoyDataplane = DockerfileImage{Name: "envoy-dataplane", Context: "cmd/dataplane/envoy"}

var releasedDockerfiles = []DockerfileImage{EnvoyDataplane, {Name: "other", Context: "cmd/other"}}
`

func TestSubstrateImages(t *testing.T) {
	got, err := substrateImages("images.go", []byte(imagesGo))
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"ateapi", "kubernetes-secrets", "envoy-dataplane", "other"}; !slices.Equal(got, want) {
		t.Errorf("got %q, want %q", got, want)
	}
	for name, src := range map[string]string{
		"no released":     strings.Replace(imagesGo, "var released =", "var unreleased =", 1),
		"no dockerfiles":  strings.Replace(imagesGo, "var releasedDockerfiles =", "var dockerfiles =", 1),
		"computed path":   strings.Replace(imagesGo, `"cmd/ateapi",`+"\n", `"cmd/" + "ateapi",`+"\n", 1),
		"unknown var":     strings.Replace(imagesGo, "{EnvoyDataplane,", "{Envoy,", 1),
		"unkeyed literal": strings.Replace(imagesGo, `{Name: "other", Context: "cmd/other"}`, `{"other", "cmd/other"}`, 1),
		"repeated name":   strings.Replace(imagesGo, `Name: "other"`, `Name: "ateapi"`, 1),
		"not Go":          "package images\nvar released = ",
	} {
		if got, err := substrateImages("images.go", []byte(src)); err == nil {
			t.Errorf("%s: accepted, got %q", name, got)
		}
	}
}

func TestFilterEnv(t *testing.T) {
	got := filterEnv([]string{
		"PATH=/usr/bin",
		"GITHUB_OUTPUT=/home/runner/work/_temp/_runner_file_commands/set_output_1",
		"GITHUB_STEP_SUMMARY=/s",
		"GITHUB_ENV=/e",
		"GITHUB_PATH=/p",
		"GITHUB_STATE=/st",
		"ACTIONS_RUNTIME_TOKEN=tok",
		"ACTIONS_ID_TOKEN_REQUEST_URL=https://example",
		"GITHUB_SHA=abc",
		"HOME=/home/runner",
	})
	if want := []string{"PATH=/usr/bin", "GITHUB_SHA=abc", "HOME=/home/runner"}; !slices.Equal(got, want) {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestMetadataDigest(t *testing.T) {
	const ref = "localhost:5000/holos-run/kagent/ui:0.0.0-holos.20261028.fa2cb23"
	d := "sha256:" + strings.Repeat("d", 64)
	// The shape buildx --metadata-file writes for a pushed multi-platform build.
	metadata := `{
  "buildx.build.ref": "publish-images-test/publish-images-test0/abc",
  "containerimage.descriptor": {"mediaType": "application/vnd.oci.image.index.v1+json", "digest": "` + d + `", "size": 1609},
  "containerimage.digest": "` + d + `",
  "image.name": "` + ref + `"
}`
	if got, err := metadataDigest([]byte(metadata), ref); err != nil || got != d {
		t.Errorf("got %q, %v", got, err)
	}
	if _, err := metadataDigest([]byte(metadata), strings.Replace(ref, "/ui:", "/controller:", 1)); err == nil {
		t.Error("metadata for another image was accepted")
	}
	if _, err := metadataDigest([]byte(`{"image.name": "`+ref+`"}`), ref); err == nil {
		t.Error("metadata without a digest was accepted")
	}
}
