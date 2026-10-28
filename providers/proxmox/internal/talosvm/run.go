package talosvm

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"slices"
	"strings"
	"text/tabwriter"

	"go.holos.run/distro/providers/proxmox/internal/pve"
	"go.holos.run/distro/providers/proxmox/preflight"
)

// Runner carries what the subcommands share.
type Runner struct {
	PVE     *pve.Client
	Factory Factory
	Config  Config
	Out     io.Writer
	// Err, when set, takes warnings that must stay out of Out, such as
	// list's when Out is JSON for a script.
	Err io.Writer
	// DryRun makes create, resize and destroy print the calls they would
	// send and send none of them, and restart print every node's steps and take
	// none. Everything before that, reading Proxmox and the cluster and
	// posting the schematic to Image Factory, still happens, since none of
	// it changes anything and the printed calls are only exact because of
	// it.
	DryRun bool
	// SnippetsDir is the local mount of SnippetStorage's snippets directory.
	SnippetsDir string
}

func (r *Runner) logf(format string, a ...any) {
	fmt.Fprintf(r.Out, format+"\n", a...)
}

func (r *Runner) warnf(format string, a ...any) {
	if r.Err != nil {
		fmt.Fprintf(r.Err, "talosvm: warning: "+format+"\n", a...)
	}
}

// Check fails unless the token holds every privilege in the preflight list on
// /, where preflight.sh grants the role. It runs before create, resize,
// restart and destroy change anything, so a role that has drifted from the list fails with the
// names of what is missing instead of a 403 halfway through.
func (r *Runner) Check(ctx context.Context) error {
	have, err := r.PVE.Permissions(ctx, "/")
	if err != nil {
		return fmt.Errorf("reading the token's permissions: %w", err)
	}
	return preflight.Check("/", have)
}

// Nodes returns the nodes VMs are placed on: the configured list, checked to
// be online, or every online node sorted by name.
func (r *Runner) Nodes(ctx context.Context) ([]string, error) {
	all, err := r.PVE.Nodes(ctx)
	if err != nil {
		return nil, err
	}
	online := map[string]bool{}
	var names []string
	for _, n := range all {
		if n.Status == "online" {
			online[n.Node] = true
			names = append(names, n.Node)
		}
	}
	slices.Sort(names)
	want := slices.Clone(r.Config.Nodes)
	want = append(want, r.Config.ControlPlane.Nodes...)
	for _, p := range r.Config.Pools {
		want = append(want, p.Nodes...)
	}
	for _, n := range want {
		if !online[n] {
			return nil, fmt.Errorf("proxmox node %q is not an online cluster node (online: %v)", n, names)
		}
	}
	if len(r.Config.Nodes) > 0 {
		return r.Config.Nodes, nil
	}
	if len(names) == 0 {
		return nil, fmt.Errorf("no online proxmox nodes")
	}
	return names, nil
}

// guestNets reads every guest's config and returns the addresses and MACs
// each has. Every guest, whoever owns it, so a node address can never land
// on a tenant's VM; reading a config needs only VM.Audit. A guest whose
// cicustom network snippet is in the snippets storage has that file read
// from the mount too, since VMs on the k8s vnet set their addresses there; a
// snippet elsewhere, or one that cannot be read, is skipped.
func (r *Runner) guestNets(ctx context.Context, guests []pve.Resource) (map[int]GuestNet, error) {
	nets := map[int]GuestNet{}
	for _, g := range guests {
		conf, err := r.PVE.GuestConfig(ctx, g)
		if err != nil {
			return nil, fmt.Errorf("reading the config of vmid %d to check its address: %w", g.VMID, err)
		}
		n := GuestNet{Addresses: GuestAddresses(conf), MACs: GuestMACs(conf), Net0MAC: Net0MAC(conf)}
		if path, ok := SnippetFileForVolume(r.SnippetsDir, r.Config.SnippetStorage, CustomNetworkVolume(conf)); ok {
			if text, found, err := readSnippet(path); err == nil && found {
				n.Addresses = append(n.Addresses, SnippetAddresses(text)...)
			}
		}
		nets[g.VMID] = n
	}
	return nets, nil
}

// Create makes every VM the config asks for that does not exist yet, and
// starts the cluster's existing VMs that are stopped. It checks everything
// it can before it changes anything: the config, the snippets directory, the
// token's privileges, the node list, the storages, the schematic, name,
// address and MAC conflicts, and that no existing VM's address would change. It then builds the full list of calls,
// prints it, and unless this is a dry run sends the calls one at a time,
// waiting for each task.
func (r *Runner) Create(ctx context.Context) error {
	if err := r.Config.Validate(); err != nil {
		return err
	}
	if err := CheckSnippetsDir(r.SnippetsDir, r.DryRun); err != nil {
		return err
	}
	if err := r.Check(ctx); err != nil {
		return err
	}
	nodes, err := r.Nodes(ctx)
	if err != nil {
		return err
	}
	specs, err := Specs(r.Config, nodes)
	if err != nil {
		return err
	}
	guests, err := r.PVE.VMs(ctx)
	if err != nil {
		return err
	}
	create, skip, err := Reconcile(specs, guests, r.Config.Cluster)
	if err != nil {
		return err
	}
	for _, a := range skip {
		r.logf("exists   %-24s vmid %d on %s", a.Spec.Name, a.Existing.VMID, a.Existing.Node)
		// Proxmox reports the size the VM runs with, not a pending one,
		// so this is only a pointer; resize reads the config itself.
		if v := a.Existing; int(v.MaxCPU) != a.Spec.Cores || int(v.MaxMem>>20) != a.Spec.MemoryMiB {
			r.logf("         runs with %d cores and %d MiB, the config asks for %d and %d: talosvm resize -cluster %s sets it",
				int(v.MaxCPU), v.MaxMem>>20, a.Spec.Cores, a.Spec.MemoryMiB, r.Config.Cluster)
		}
	}
	nets, err := r.guestNets(ctx, guests)
	if err != nil {
		return err
	}

	id, err := r.Factory.SchematicID(ctx)
	if err != nil {
		return err
	}
	img := Image{FactoryURL: r.Factory.BaseURL, SchematicID: id, TalosVersion: r.Config.TalosVersion}
	r.logf("schematic %s", id)
	r.logf("installer %s", img.Installer())

	var calls []Call
	var vmids []int
	if len(create) > 0 {
		var targets []string
		for _, a := range create {
			if !slices.Contains(targets, a.Spec.Node) {
				targets = append(targets, a.Spec.Node)
			}
		}
		storages, err := r.PVE.Storages(ctx)
		if err != nil {
			return err
		}
		shared, err := CheckStorages(r.Config, targets, storages)
		if err != nil {
			return err
		}
		// A shared storage shows a file fetched through one node on every
		// node, so it needs one download; a local one needs one per node.
		fetchVia := targets
		if shared {
			fetchVia = targets[:1]
		}
		for _, node := range fetchVia {
			present, err := r.isoPresent(ctx, node, img)
			if err != nil {
				return err
			}
			if present {
				r.logf("iso      %s present on %s", img.VolID(r.Config.ISOStorage), node)
				continue
			}
			calls = append(calls, DownloadCall(r.Config, node, img))
		}
		next, err := r.PVE.NextID(ctx)
		if err != nil {
			return err
		}
		vmids = AllocateVMIDs(next, len(create), guests)
	}
	plan := VMPlan{
		Config: r.Config, Create: create, Existing: skip, Guests: guests, Nets: nets,
		Dir: r.SnippetsDir, VMIDs: vmids, Image: img, SchematicID: id, Read: readOwnedSnippet,
	}
	vmCalls, err := plan.Calls()
	if err != nil {
		return err
	}
	calls = append(calls, vmCalls...)
	if len(calls) == 0 {
		r.logf("nothing to do")
		return nil
	}
	return r.send(ctx, calls)
}

func (r *Runner) isoPresent(ctx context.Context, node string, img Image) (bool, error) {
	content, err := r.PVE.Content(ctx, node, r.Config.ISOStorage, "iso")
	if err != nil {
		return false, err
	}
	volid := img.VolID(r.Config.ISOStorage)
	return slices.ContainsFunc(content, func(c pve.StorageContent) bool { return c.VolID == volid }), nil
}

// send prints every call, then sends them in order unless this is a dry
// run. Printing the whole list first means a failure halfway leaves a record
// of what was meant to follow.
func (r *Runner) send(ctx context.Context, calls []Call) error {
	for i, c := range calls {
		r.logf("# %d/%d %s", i+1, len(calls), c.What)
		r.logf("%s", c)
	}
	if r.DryRun {
		r.logf("dry run: sent none of these %d calls", len(calls))
		return nil
	}
	for i, c := range calls {
		switch c.Method {
		case WriteFile, RemoveFile:
			// Check again: the directory is shared, and the plan was made
			// a while ago.
			_, _, err := readOwnedSnippet(c.Path, c.Header)
			if err != nil {
				return fmt.Errorf("step %d/%d, %s: %w", i+1, len(calls), c.What, err)
			}
			if c.Method == WriteFile {
				err = writeFileAtomic(c.Path, c.Content)
			} else if err = os.Remove(c.Path); errors.Is(err, fs.ErrNotExist) {
				err = nil
			}
			if err != nil {
				return fmt.Errorf("step %d/%d, %s: %w", i+1, len(calls), c.What, err)
			}
			r.logf("done %d/%d %s", i+1, len(calls), c.What)
			continue
		}
		if err := r.call(ctx, c); err != nil {
			return fmt.Errorf("call %d/%d, %s: %w", i+1, len(calls), c.What, err)
		}
		r.logf("done %d/%d %s", i+1, len(calls), c.What)
	}
	return nil
}

// call sends one API call and waits, for at most its timeout, for the task
// it starts. A PUT of a VM's config starts no task: it is done when it
// returns.
func (r *Runner) call(ctx context.Context, c Call) error {
	if c.Method == http.MethodPut {
		return r.PVE.Put(ctx, c.Path, c.Params)
	}
	var upid string
	if err := r.PVE.Do(ctx, c.Method, c.Path, c.Params, &upid); err != nil {
		return err
	}
	wctx, cancel := context.WithTimeout(ctx, c.Timeout)
	defer cancel()
	return r.PVE.WaitTask(wctx, upid)
}

// vmAddress returns a VM's node address, or "" when it has none in the
// node subnet. The address is in the VM's network snippet, so it is found
// only while the snippets mount is there to read.
func (r *Runner) vmAddress(ctx context.Context, v pve.Resource) (string, error) {
	conf, err := r.PVE.GuestConfig(ctx, v)
	if err != nil {
		return "", err
	}
	as := GuestAddresses(conf)
	if path, ok := SnippetFileForVolume(r.SnippetsDir, r.Config.SnippetStorage, CustomNetworkVolume(conf)); ok {
		if text, found, err := readSnippet(path); err == nil && found {
			as = append(as, SnippetAddresses(text)...)
		}
	}
	for _, a := range as {
		if NodeSubnet.Contains(a) && a != Gateway {
			return a.String(), nil
		}
	}
	return "", nil
}

// VM is one row of list output. Region and Zone are the Proxmox cluster and
// node, which the Talos patches later turn into the worker's
// topology.kubernetes.io/region and zone labels. Cores and MemoryMiB are
// what the VM runs with; PendingCores and PendingMemoryMiB, when set, are a
// new size resize gave it that takes effect when it is next started. A VM
// whose pending size could not be read has neither, and shows ? in the
// table.
type VM struct {
	Name      string `json:"name"`
	VMID      int    `json:"vmid"`
	Region    string `json:"region"`
	Zone      string `json:"zone"`
	Role      string `json:"role"`
	Pool      string `json:"pool,omitempty"`
	Address   string `json:"address"`
	Status    string `json:"status"`
	Cores     int    `json:"cores"`
	MemoryMiB int64  `json:"memoryMiB"`

	PendingCores     int `json:"pendingCores,omitempty"`
	PendingMemoryMiB int `json:"pendingMemoryMiB,omitempty"`
	pendingUnknown   bool
}

// List prints the cluster's VMs as a table, or as JSON for scripts such as
// the Talos patch step.
func (r *Runner) List(ctx context.Context, asJSON bool) error {
	if r.Config.Cluster == "" {
		return fmt.Errorf("cluster is required: name the cluster with -cluster or in the config")
	}
	guests, err := r.PVE.VMs(ctx)
	if err != nil {
		return err
	}
	region, err := r.PVE.ClusterName(ctx)
	if err != nil {
		return err
	}
	rows := []VM{}
	for _, v := range OwnedVMs(guests, r.Config.Cluster) {
		// The list leaves the address blank when the snippets mount is
		// not there to read.
		addr, err := r.vmAddress(ctx, v)
		if err != nil {
			return err
		}
		row := VM{
			Name: v.Name, VMID: v.VMID, Region: region, Zone: v.Node,
			Role: RoleOf(v), Pool: PoolOf(v), Address: addr, Status: v.Status,
			Cores: int(v.MaxCPU), MemoryMiB: v.MaxMem >> 20,
		}
		// The pending size is extra; one VM's that cannot be read does
		// not keep the rest of the list, which scripts depend on, away.
		switch size, err := r.guestSize(ctx, v); {
		case err != nil:
			row.pendingUnknown = true
			r.warnf("reading the pending size of %s: %v", v.Name, err)
		default:
			if size.NextCores != size.Cores {
				row.PendingCores = size.NextCores
			}
			if size.NextMemoryMiB != size.MemoryMiB {
				row.PendingMemoryMiB = size.NextMemoryMiB
			}
		}
		rows = append(rows, row)
	}
	if asJSON {
		enc := json.NewEncoder(r.Out)
		enc.SetIndent("", "  ")
		return enc.Encode(rows)
	}
	tw := tabwriter.NewWriter(r.Out, 0, 4, 2, ' ', 0)
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

// Destroy stops and deletes the cluster's VMs and their disks. It touches
// only VMs Owned selects. A dry run prints the calls and sends none, and the
// command line makes the dry run the default, so the destructive run is
// always a second, deliberate command.
func (r *Runner) Destroy(ctx context.Context) error {
	if r.Config.Cluster == "" || !label.MatchString(r.Config.Cluster) {
		return fmt.Errorf("cluster %q: name the cluster to destroy with -cluster", r.Config.Cluster)
	}
	if err := CheckSnippetsDir(r.SnippetsDir, r.DryRun); err != nil {
		return err
	}
	if err := r.Check(ctx); err != nil {
		return err
	}
	guests, err := r.PVE.VMs(ctx)
	if err != nil {
		return err
	}
	calls, err := DestroyCalls(guests, r.Config.Cluster, r.SnippetsDir, readOwnedSnippet)
	if err != nil {
		return err
	}
	if len(calls) == 0 {
		r.logf("no talosvm VMs for cluster %s", r.Config.Cluster)
		return nil
	}
	return r.send(ctx, calls)
}
