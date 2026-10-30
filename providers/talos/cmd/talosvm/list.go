package main

import (
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"
	"text/tabwriter"

	"go.holos.run/distro/providers/infra"
	"go.holos.run/distro/providers/talos"
)

// row is one row of list output, whose columns and JSON keys are the
// program's interface to scripts such as cluster.sh. Region and Zone are the
// Proxmox cluster and node, which the Talos patches turn into the node's
// topology.kubernetes.io/region and zone labels. Cores and MemoryMiB are what
// the VM runs with; PendingCores and PendingMemoryMiB, when set, are a new
// size resize gave it that takes effect when it is next started. A VM whose
// pending size could not be read has neither, and shows ? in the table.
type row struct {
	Name      string `json:"name"`
	VMID      int    `json:"vmid"`
	Region    string `json:"region"`
	Zone      string `json:"zone"`
	Role      string `json:"role"`
	Pool      string `json:"pool,omitempty"`
	Address   string `json:"address"`
	Status    string `json:"status"`
	Cores     int    `json:"cores"`
	MemoryMiB int    `json:"memoryMiB"`

	PendingCores     int `json:"pendingCores,omitempty"`
	PendingMemoryMiB int `json:"pendingMemoryMiB,omitempty"`
	pendingUnknown   bool
}

// list prints the cluster's VMs as a table, or as JSON for scripts such as
// the Talos patch step. The address is blank when the provider could not
// read it, which it cannot without the snippets mount. One VM's pending
// size that cannot be read does not keep the rest of the list, which scripts
// depend on, away: it is a warning on stderr.
func list(vms []infra.VM, asJSON bool, stdout, stderr io.Writer) error {
	rows := []row{}
	for _, v := range vms {
		// The VMID is the Proxmox provider's, the only one wired in.
		vmid, _ := strconv.Atoi(v.ID.Value)
		r := row{
			Name: v.Name, VMID: vmid, Region: v.Region, Zone: v.Zone,
			Role: v.Label(talos.LabelRole), Pool: v.Label(talos.LabelPool), Status: v.Status,
			Cores: v.Size.Cores, MemoryMiB: v.Size.MemoryMiB,
		}
		if v.NIC.Address.IsValid() {
			r.Address = v.NIC.Address.Addr().String()
		}
		switch g := v.Sizing; {
		case v.SizingErr != nil:
			r.pendingUnknown = true
			fmt.Fprintf(stderr, "talosvm: warning: reading the pending size of %s: %v\n", v.Name, v.SizingErr)
		default:
			if g.Next.Cores != g.Now.Cores {
				r.PendingCores = g.Next.Cores
			}
			if g.Next.MemoryMiB != g.Now.MemoryMiB {
				r.PendingMemoryMiB = g.Next.MemoryMiB
			}
		}
		rows = append(rows, r)
	}
	if asJSON {
		enc := json.NewEncoder(stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(rows)
	}
	tw := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(tw, "NAME\tVMID\tREGION\tNODE\tROLE\tPOOL\tADDRESS\tSTATUS\tCORES\tMEMORY\tPENDING")
	for _, v := range rows {
		pool := v.Pool
		if pool == "" {
			pool = "-"
		}
		var pending []string
		if v.PendingCores != 0 {
			pending = append(pending, fmt.Sprintf("%d cores", v.PendingCores))
		}
		if v.PendingMemoryMiB != 0 {
			pending = append(pending, fmt.Sprintf("%dMiB", v.PendingMemoryMiB))
		}
		switch {
		case v.pendingUnknown:
			pending = []string{"?"}
		case len(pending) == 0:
			pending = []string{"-"}
		}
		fmt.Fprintf(tw, "%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%dMiB\t%s\n",
			v.Name, v.VMID, v.Region, v.Zone, v.Role, pool, v.Address, v.Status, v.Cores, v.MemoryMiB, strings.Join(pending, ", "))
	}
	return tw.Flush()
}
