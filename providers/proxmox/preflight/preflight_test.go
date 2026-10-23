package preflight

import (
	"errors"
	"slices"
	"strings"
	"testing"
)

// The embedded file is the role; it must parse, and it must hold the
// privileges the program's calls are known to need, so an accidental deletion
// fails here rather than as a 403 on the first real run.
func TestEmbeddedListParses(t *testing.T) {
	ps, err := Parse(privilegesFile)
	if err != nil {
		t.Fatal(err)
	}
	names := Names(ps)
	for _, want := range []string{"VM.Allocate", "VM.Audit", "VM.Config.Cloudinit", "Sys.AccessNetwork", "SDN.Use", "Datastore.AllocateSpace"} {
		if !slices.Contains(names, want) {
			t.Errorf("privileges.txt lacks %s", want)
		}
	}
	// These were in the first hand-made role and nothing the program calls
	// needs them; Sys.Modify in particular is far broader than the ISO
	// download it was granted for.
	for _, gone := range []string{"Sys.Modify", "VM.Console", "VM.GuestAgent.Audit", "VM.Config.CDROM", "Datastore.Allocate", "Pool.Audit"} {
		if slices.Contains(names, gone) {
			t.Errorf("privileges.txt lists %s, which no call needs", gone)
		}
	}
}

func TestParseRejects(t *testing.T) {
	for _, tc := range []struct{ text, want string }{
		{"VM.Audit\n", "needs a comment"},
		{"VM.Audit #\n", "needs a comment"},
		{"vm.audit # x\n", "not a privilege name"},
		{"VM.Audit # x\nVM.Audit # y\n", "listed twice"},
		{"# only comments\n", "no privileges"},
	} {
		if _, err := Parse(tc.text); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("Parse(%q) = %v, want %q", tc.text, err, tc.want)
		}
	}
}

func TestCheckReportsMissing(t *testing.T) {
	have := map[string]bool{}
	for _, n := range Names(Required()) {
		have[n] = true
	}
	if err := Check("/", have); err != nil {
		t.Fatalf("Check with every privilege: %v", err)
	}
	delete(have, "VM.Config.Cloudinit")
	delete(have, "SDN.Use")
	have["Sys.Modify"] = true // extras are not an error here; preflight.sh removes them
	err := Check("/", have)
	var me *MissingError
	if !errors.As(err, &me) {
		t.Fatalf("Check = %v, want *MissingError", err)
	}
	if got := Names(me.Missing); !slices.Equal(got, []string{"SDN.Use", "VM.Config.Cloudinit"}) {
		t.Errorf("missing = %v", got)
	}
	for _, want := range []string{"VM.Config.Cloudinit", "cicustom", Script} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error does not mention %q:\n%v", want, err)
		}
	}
}
