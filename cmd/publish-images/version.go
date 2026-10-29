package main

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"
)

// reSHA is a full commit SHA as git prints it. A pin is always one: a branch
// moves and a tag can be moved, so neither says what was built.
var reSHA = regexp.MustCompile(`^[0-9a-f]{40}$`)

func checkSHA(flag, sha string) error {
	if !reSHA.MatchString(sha) {
		return fmt.Errorf("-%s %q is not a full 40-character lowercase commit SHA", flag, sha)
	}
	return nil
}

// reDigest is the only digest form this program accepts from a registry.
var reDigest = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

// version is the version a fork's images and charts are tagged with,
// 0.0.0-holos.<YYYYMMDD>.<7-character SHA>, without the v that Substrate's
// release-tag check wants and Helm's chart version does not. It makes no claim
// about an upstream release the fork does not correspond to, sorts by date,
// and is new for every pin, so Substrate's already-published check never
// skips a new pin. The platform deploys the digest, never the tag.
//
// The date is the commit's committer date in UTC, not the time of the run, so
// a rebuild of one pin, on any day, gets the same tag.
//
// SemVer forbids a leading zero in an all-digit prerelease identifier, and
// Helm enforces it, so an abbreviation such as 0412345 is written g0412345,
// as git describe writes every abbreviation. Any other is written as is.
func version(sha string, committed time.Time) string {
	short := sha[:7]
	if short[0] == '0' && strings.Trim(short, "0123456789") == "" {
		short = "g" + short
	}
	return fmt.Sprintf("0.0.0-holos.%s.%s", committed.UTC().Format("20060102"), short)
}

// splitRegistry splits the -registry prefix into the host kagent's Makefile
// calls DOCKER_REGISTRY and the path under it, which may be empty.
func splitRegistry(prefix string) (host, path string, err error) {
	if prefix == "" || strings.Contains(prefix, "://") || strings.HasSuffix(prefix, "/") || strings.ContainsAny(prefix, " @") {
		return "", "", fmt.Errorf("-registry %q is not a registry prefix such as ghcr.io/holos-run", prefix)
	}
	host, path, _ = strings.Cut(prefix, "/")
	return host, path, nil
}

// repository returns ref without its tag or digest: the name an attestation's
// subject-name wants. A colon before the last slash is a registry port, not a
// tag.
func repository(ref string) string {
	ref, _, _ = strings.Cut(ref, "@")
	slash := strings.LastIndex(ref, "/")
	if colon := strings.LastIndex(ref, ":"); colon > slash {
		ref = ref[:colon]
	}
	return ref
}

// releaseRefs reads the digest references Substrate's publish release-images
// prints to stdout after building, below a "Release images for <tag>:" line,
// one per image, as ko and buildx print them: repo/name:tag@sha256:... or
// repo/name@sha256:.... The program runs the command with overwrite on, so
// it always builds and always prints the block; a missing block is an error.
func releaseRefs(stdout, tag string) (map[string]string, error) {
	lines := strings.Split(stdout, "\n")
	header := "Release images for " + tag + ":"
	start := -1
	for i, line := range lines {
		if strings.TrimSpace(line) == header {
			start = i + 1
		}
	}
	if start < 0 {
		return nil, fmt.Errorf("publish release-images printed no %q block", header)
	}
	refs := map[string]string{}
	for _, line := range lines[start:] {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		_, digest, ok := strings.Cut(line, "@")
		if !ok || !reDigest.MatchString(digest) {
			return nil, fmt.Errorf("publish release-images printed %q, not a digest reference", line)
		}
		name := repository(line)
		if _, dup := refs[name]; dup {
			return nil, fmt.Errorf("publish release-images printed %s twice", name)
		}
		refs[name] = digest
	}
	if len(refs) == 0 {
		return nil, fmt.Errorf("publish release-images printed %q and no image after it", header)
	}
	return refs, nil
}

// helmPushDigest reads the digest from helm push's output, which ends with
//
//	Pushed: <registry>/<path>/<chart>:<version>
//	Digest: sha256:...
func helmPushDigest(out, want string) (string, error) {
	var pushed, digest string
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if v, ok := strings.CutPrefix(line, "Pushed:"); ok {
			pushed = strings.TrimSpace(v)
		}
		if v, ok := strings.CutPrefix(line, "Digest:"); ok {
			digest = strings.TrimSpace(v)
		}
	}
	if pushed != want {
		return "", fmt.Errorf("helm push reported pushing %q, want %q", pushed, want)
	}
	if !reDigest.MatchString(digest) {
		return "", fmt.Errorf("helm push reported no sha256 digest for %s (got %q)", want, digest)
	}
	return digest, nil
}

// manifest is the part of `docker buildx imagetools inspect --format
// '{{json .Manifest}}'` this program reads: the descriptor of what the tag
// names in the registry and, for an index, the platforms it holds.
type manifest struct {
	MediaType string `json:"mediaType"`
	Digest    string `json:"digest"`
	Manifests []struct {
		Platform *struct {
			OS           string `json:"os"`
			Architecture string `json:"architecture"`
			Variant      string `json:"variant"`
		} `json:"platform"`
	} `json:"manifests"`
}

func parseManifest(b []byte) (*manifest, error) {
	var m manifest
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, fmt.Errorf("decoding imagetools output: %w", err)
	}
	if !reDigest.MatchString(m.Digest) {
		return nil, fmt.Errorf("imagetools reported no sha256 digest (got %q)", m.Digest)
	}
	return &m, nil
}

func (m *manifest) isIndex() bool {
	return m.MediaType == "application/vnd.oci.image.index.v1+json" ||
		m.MediaType == "application/vnd.docker.distribution.manifest.list.v2+json"
}

// missingPlatforms returns the wanted platforms, such as linux/arm64, that an
// index holds no image for. A wanted platform without a variant accepts any
// variant. buildx's attestation manifests, unknown/unknown, match nothing.
func (m *manifest) missingPlatforms(want []string) []string {
	var missing []string
	for _, w := range want {
		found := false
		for _, d := range m.Manifests {
			if d.Platform == nil {
				continue
			}
			p := d.Platform.OS + "/" + d.Platform.Architecture
			if p == w || (d.Platform.Variant != "" && p+"/"+d.Platform.Variant == w) {
				found = true
				break
			}
		}
		if !found {
			missing = append(missing, w)
		}
	}
	return missing
}

// builderPlatforms reads the platforms a buildx builder can build from
// `docker buildx inspect --bootstrap`, the comma separated list on its
// Platforms line, such as "linux/amd64, linux/amd64/v2, linux/arm64*".
// buildx marks with * the platforms the builder was configured with.
func builderPlatforms(inspect string) (name string, platforms []string) {
	for _, line := range strings.Split(inspect, "\n") {
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		switch strings.TrimSpace(key) {
		case "Name":
			if name == "" {
				name = strings.TrimSpace(value)
			}
		case "Platforms":
			for _, p := range strings.Split(value, ",") {
				if p = strings.TrimSuffix(strings.TrimSpace(p), "*"); p != "" {
					platforms = append(platforms, p)
				}
			}
		}
	}
	return name, platforms
}

// unsupported returns the wanted platforms none of have can build, matching
// linux/arm64 against linux/arm64 or any variant of it.
func unsupported(want, have []string) []string {
	var missing []string
	for _, w := range want {
		found := false
		for _, h := range have {
			if h == w || strings.HasPrefix(h, w+"/") {
				found = true
				break
			}
		}
		if !found {
			missing = append(missing, w)
		}
	}
	return missing
}
