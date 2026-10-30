package proxmox

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"go.holos.run/distro/providers/infra"
	"go.holos.run/distro/providers/proxmox/internal/pve"
)

// SizingOf reads cores and memory from a VM's pending list: what its config
// holds now, and what it will hold after its next start. The two differ while
// Proxmox holds a change to a running VM as pending, which is how every
// resize of a running VM ends: the VMs have no CPU or memory hotplug, so new
// cores and memory take effect only when the VM is stopped and started. The
// provider sets both on every VM it creates, so a VM without one, or with its
// deletion pending, is an error rather than a guess at Proxmox's default.
func SizingOf(items []pve.PendingItem) (infra.Sizing, error) {
	var g infra.Sizing
	seen := map[string]bool{}
	for _, it := range items {
		var now, next *int
		parse := strconv.Atoi
		switch it.Key {
		case "cores":
			now, next = &g.Now.Cores, &g.Next.Cores
		case "memory":
			now, next, parse = &g.Now.MemoryMiB, &g.Next.MemoryMiB, parseMemory
		default:
			continue
		}
		if it.Delete != 0 {
			return g, fmt.Errorf("its %s is pending deletion", it.Key)
		}
		v, err := parse(it.Value)
		if err != nil {
			return g, fmt.Errorf("its %s %q: %w", it.Key, it.Value, err)
		}
		*now, *next = v, v
		if it.HasPending {
			if *next, err = parse(it.Pending); err != nil {
				return g, fmt.Errorf("its pending %s %q: %w", it.Key, it.Pending, err)
			}
		}
		seen[it.Key] = true
	}
	for _, k := range []string{"cores", "memory"} {
		if !seen[k] {
			return g, fmt.Errorf("its config has no %s", k)
		}
	}
	return g, nil
}

// parseMemory reads a memory value in MiB. Proxmox 8.1 made memory a
// property string, [current=]<MiB>, which it writes as the bare number when
// nothing else is set; both forms are read.
func parseMemory(s string) (int, error) {
	first, _, _ := strings.Cut(s, ",")
	return strconv.Atoi(strings.TrimPrefix(first, "current="))
}

// sizing reads one VM's Sizing.
func (c *Compute) sizing(ctx context.Context, v pve.Resource) (infra.Sizing, error) {
	items, err := c.pve.GuestPending(ctx, v)
	if err != nil {
		return infra.Sizing{}, err
	}
	g, err := SizingOf(items)
	if err != nil {
		return infra.Sizing{}, fmt.Errorf("VM %s vmid %d: %w", v.Name, v.VMID, err)
	}
	return g, nil
}
