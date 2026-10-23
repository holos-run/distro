// Package preflight holds the Proxmox privileges the provider's programs need.
//
// privileges.txt is the one list. preflight.sh, run as root on a Proxmox
// node, sets the HolosProvisioner role to exactly that list, and talosvm
// embeds the same file through this package and checks the token against it
// before it changes anything. Keeping both on one file means the role a host
// grants and the role the program expects cannot drift apart.
package preflight

import (
	_ "embed"
	"fmt"
	"regexp"
	"slices"
	"strings"
)

//go:embed privileges.txt
var privilegesFile string

// Script is where the setup script lives, for error messages that tell the
// operator what to run.
const Script = "providers/proxmox/preflight/preflight.sh"

// Privilege is one line of privileges.txt.
type Privilege struct {
	Name string
	// Why names the API calls that need the privilege.
	Why string
}

// privilegeName is a Proxmox privilege such as VM.Config.CPU.
var privilegeName = regexp.MustCompile(`^[A-Z][A-Za-z]*(\.[A-Z][A-Za-z]*)+$`)

// Parse reads a privileges file. Blank lines and lines that start with # are
// skipped. Every other line is a privilege name followed by a # comment, and
// the comment is required, so the file keeps saying why each privilege is
// there.
func Parse(text string) ([]Privilege, error) {
	var out []Privilege
	seen := map[string]bool{}
	for i, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		name, why, ok := strings.Cut(line, "#")
		name, why = strings.TrimSpace(name), strings.TrimSpace(why)
		switch {
		case !privilegeName.MatchString(name):
			return nil, fmt.Errorf("privileges.txt line %d: %q is not a privilege name", i+1, name)
		case !ok || why == "":
			return nil, fmt.Errorf("privileges.txt line %d: %s needs a comment naming the calls that need it", i+1, name)
		case seen[name]:
			return nil, fmt.Errorf("privileges.txt line %d: %s is listed twice", i+1, name)
		}
		seen[name] = true
		out = append(out, Privilege{Name: name, Why: why})
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("privileges.txt lists no privileges")
	}
	return out, nil
}

// Required returns the embedded list. The file is checked by a test, so a
// parse error here is a broken build and panics.
func Required() []Privilege {
	ps, err := Parse(privilegesFile)
	if err != nil {
		panic(err)
	}
	return ps
}

// Names returns the privilege names, sorted.
func Names(ps []Privilege) []string {
	names := make([]string, len(ps))
	for i, p := range ps {
		names[i] = p.Name
	}
	slices.Sort(names)
	return names
}

// Missing returns the required privileges not in have.
func Missing(required []Privilege, have map[string]bool) []Privilege {
	var out []Privilege
	for _, p := range required {
		if !have[p.Name] {
			out = append(out, p)
		}
	}
	return out
}

// MissingError describes privileges a token lacks.
type MissingError struct {
	Path    string
	Missing []Privilege
}

func (e *MissingError) Error() string {
	var b strings.Builder
	fmt.Fprintf(&b, "the Proxmox token lacks %d privilege(s) on %s that talosvm needs:\n", len(e.Missing), e.Path)
	for _, p := range e.Missing {
		fmt.Fprintf(&b, "  %-26s %s\n", p.Name, p.Why)
	}
	fmt.Fprintf(&b, "run %s as root on a Proxmox node to set the HolosProvisioner role (see providers/proxmox/README.md)", Script)
	return b.String()
}

// Check returns a *MissingError when have lacks any required privilege.
func Check(path string, have map[string]bool) error {
	if m := Missing(Required(), have); len(m) > 0 {
		return &MissingError{Path: path, Missing: m}
	}
	return nil
}
