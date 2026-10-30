package proxmox

import (
	"strings"
	"testing"

	"go.holos.run/distro/providers/infra"
	"go.holos.run/distro/providers/proxmox/internal/pve"
)

func TestSizingOf(t *testing.T) {
	for _, tc := range []struct {
		name  string
		items []pve.PendingItem
		want  infra.Sizing
		err   string
	}{
		{"at size", []pve.PendingItem{{Key: "cores", Value: "4"}, {Key: "memory", Value: "16384"}, {Key: "balloon", Value: "0"}},
			infra.Sizing{Now: infra.Size{Cores: 4, MemoryMiB: 16384}, Next: infra.Size{Cores: 4, MemoryMiB: 16384}}, ""},
		{"memory pending", []pve.PendingItem{{Key: "cores", Value: "4"}, {Key: "memory", Value: "8192", Pending: "16384", HasPending: true}},
			infra.Sizing{Now: infra.Size{Cores: 4, MemoryMiB: 8192}, Next: infra.Size{Cores: 4, MemoryMiB: 16384}}, ""},
		{"property string", []pve.PendingItem{{Key: "cores", Value: "2", Pending: "4", HasPending: true}, {Key: "memory", Value: "current=6144"}},
			infra.Sizing{Now: infra.Size{Cores: 2, MemoryMiB: 6144}, Next: infra.Size{Cores: 4, MemoryMiB: 6144}}, ""},
		{"no memory", []pve.PendingItem{{Key: "cores", Value: "4"}}, infra.Sizing{}, "no memory"},
		{"memory deleted", []pve.PendingItem{{Key: "cores", Value: "4"}, {Key: "memory", Value: "8192", Delete: 1}}, infra.Sizing{}, "pending deletion"},
		{"garbage", []pve.PendingItem{{Key: "cores", Value: "four"}, {Key: "memory", Value: "8192"}}, infra.Sizing{}, `cores "four"`},
	} {
		got, err := SizingOf(tc.items)
		switch {
		case tc.err != "":
			if err == nil || !strings.Contains(err.Error(), tc.err) {
				t.Errorf("%s: err = %v, want %q", tc.name, err, tc.err)
			}
		case err != nil || got != tc.want:
			t.Errorf("%s: SizingOf = %+v, %v, want %+v", tc.name, got, err, tc.want)
		}
	}
}
