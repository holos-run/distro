package main

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"path"
	"slices"
	"strconv"
	"strings"
)

// substrateImagesFile is where Substrate lists the images its release
// publishes, relative to the fork's root.
const substrateImagesFile = "cmd/ate-setup/internal/images/images.go"

// substrateImages reads the names of the images Substrate's publish
// release-images pushes from the fork's own source, so the set always matches
// the commit being built: the import paths in the released variable, each
// named by its last element as images.ImageName names it, and the Name of each
// DockerfileImage in releasedDockerfiles, written inline or as a package-level
// variable in the same file. Anything else in those lists is an error, since
// it means the file changed shape and this program must be updated.
func substrateImages(filename string, src []byte) ([]string, error) {
	f, err := parser.ParseFile(token.NewFileSet(), filename, src, parser.SkipObjectResolution)
	if err != nil {
		return nil, err
	}
	vars := map[string]ast.Expr{}
	for _, decl := range f.Decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok || gen.Tok != token.VAR {
			continue
		}
		for _, spec := range gen.Specs {
			vs := spec.(*ast.ValueSpec)
			for i, name := range vs.Names {
				if i < len(vs.Values) {
					vars[name.Name] = vs.Values[i]
				}
			}
		}
	}
	list := func(name string) ([]ast.Expr, error) {
		lit, ok := vars[name].(*ast.CompositeLit)
		if !ok {
			return nil, fmt.Errorf("%s: no var %s = <composite literal>", filename, name)
		}
		return lit.Elts, nil
	}
	str := func(e ast.Expr, what string) (string, error) {
		lit, ok := e.(*ast.BasicLit)
		if !ok || lit.Kind != token.STRING {
			return "", fmt.Errorf("%s: %s is not a string literal", filename, what)
		}
		return strconv.Unquote(lit.Value)
	}

	var names []string
	released, err := list("released")
	if err != nil {
		return nil, err
	}
	for i, e := range released {
		pkg, err := str(e, fmt.Sprintf("released[%d]", i))
		if err != nil {
			return nil, err
		}
		names = append(names, path.Base(pkg))
	}
	dockerfiles, err := list("releasedDockerfiles")
	if err != nil {
		return nil, err
	}
	for i, e := range dockerfiles {
		what := fmt.Sprintf("releasedDockerfiles[%d]", i)
		if id, ok := e.(*ast.Ident); ok {
			what, e = id.Name, vars[id.Name]
		}
		lit, ok := e.(*ast.CompositeLit)
		if !ok {
			return nil, fmt.Errorf("%s: %s is not a DockerfileImage literal", filename, what)
		}
		name := ""
		for _, elt := range lit.Elts {
			kv, ok := elt.(*ast.KeyValueExpr)
			if !ok {
				return nil, fmt.Errorf("%s: %s is not a keyed DockerfileImage literal", filename, what)
			}
			if key, ok := kv.Key.(*ast.Ident); ok && key.Name == "Name" {
				if name, err = str(kv.Value, what+".Name"); err != nil {
					return nil, err
				}
			}
		}
		if name == "" {
			return nil, fmt.Errorf("%s: %s has no Name", filename, what)
		}
		names = append(names, name)
	}
	seen := map[string]bool{}
	for _, n := range names {
		if n == "" || n == "." || n == "/" || seen[n] {
			return nil, fmt.Errorf("%s: image name %q is empty or repeated", filename, n)
		}
		seen[n] = true
	}
	if len(names) == 0 {
		return nil, fmt.Errorf("%s lists no released images", filename)
	}
	return names, nil
}

// withheld are the variables the forks' builds do not inherit. The GITHUB_*
// ones are files a step writes to set outputs, the summary, the environment
// and the path of later steps, and the ACTIONS_* ones carry the runner's
// tokens; a fork's build has no business with either.
var withheld = []string{"GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY", "GITHUB_ENV", "GITHUB_PATH", "GITHUB_STATE"}

// filterEnv returns env without the withheld variables and any ACTIONS_*
// variable.
func filterEnv(env []string) []string {
	var out []string
	for _, kv := range env {
		key, _, _ := strings.Cut(kv, "=")
		if strings.HasPrefix(key, "ACTIONS_") || slices.Contains(withheld, key) {
			continue
		}
		out = append(out, kv)
	}
	return out
}

// metadataDigest reads the digest buildx reports for a pushed image from the
// file --metadata-file writes, and checks the image name it reports.
func metadataDigest(metadata []byte, want string) (string, error) {
	var m struct {
		Digest string `json:"containerimage.digest"`
		Name   string `json:"image.name"`
	}
	if err := json.Unmarshal(metadata, &m); err != nil {
		return "", fmt.Errorf("decoding the buildx metadata for %s: %w", want, err)
	}
	if m.Name != want {
		return "", fmt.Errorf("buildx reported pushing %q, want %q", m.Name, want)
	}
	if !reDigest.MatchString(m.Digest) {
		return "", fmt.Errorf("the buildx metadata for %s has no sha256 containerimage.digest (got %q)", want, m.Digest)
	}
	return m.Digest, nil
}
