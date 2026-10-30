package proxmox

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/netip"
	"os"
	"slices"
	"strconv"
	"time"

	"go.holos.run/distro/providers/infra"
	"go.holos.run/distro/providers/proxmox/internal/pve"
	"go.holos.run/distro/providers/proxmox/preflight"
)

// Compute is the infra.Compute of one Proxmox VE cluster. A group of the
// contract is a cluster here, recorded in each VM's cluster tag.
type Compute struct {
	pve    *pve.Client
	Config Config
	// SnippetsDir is the local mount of SnippetStorage's snippets directory.
	SnippetsDir string
	Out         io.Writer
	// Err, when set, takes warnings.
	Err io.Writer
	// DryRun makes Create, Resize and Destroy print the calls they would
	// send and send none of them. Everything before that, reading Proxmox
	// and the snippets, still happens, since none of it changes anything
	// and the printed calls are only exact because of it.
	DryRun bool
}

var _ infra.Compute = (*Compute)(nil)

// New returns a Compute for the Proxmox API at endpoint, any node of the
// cluster, with the garage's config. Plain http is accepted for tests; the
// talosvm command only accepts https. None of the errors quote the endpoint
// or the token ID, which come from the environment and could hold a secret
// in the wrong variable.
func New(endpoint, tokenID, secret string, hc *http.Client) (*Compute, error) {
	client, err := pve.New(endpoint, tokenID, secret, hc)
	if err != nil {
		return nil, err
	}
	return &Compute{pve: client, Config: Default(), SnippetsDir: DefaultSnippetsDir, Out: io.Discard}, nil
}

// NewHTTPClient returns an HTTP client that verifies the Proxmox
// certificate against the PEM bundle in caFile, or skips verification when
// insecure, which is never the default; see pve.NewHTTPClient.
func NewHTTPClient(caFile string, insecure bool) (*http.Client, error) {
	return pve.NewHTTPClient(caFile, insecure)
}

// String names the provider in the Kubernetes layer's messages.
func (c *Compute) String() string { return "Proxmox" }

func (c *Compute) logf(format string, a ...any) {
	fmt.Fprintf(c.Out, format+"\n", a...)
}

// Check fails unless the token holds every privilege in the preflight list on
// /, where preflight.sh grants the role. It runs before create, resize,
// restart and destroy change anything, so a role that has drifted from the
// list fails with the names of what is missing instead of a 403 halfway
// through.
func (c *Compute) Check(ctx context.Context) error {
	have, err := c.pve.Permissions(ctx, "/")
	if err != nil {
		return fmt.Errorf("reading the token's permissions: %w", err)
	}
	return preflight.Check("/", have)
}

// CheckAddress refuses an address a node may not have on the garage's node
// network.
func (c *Compute) CheckAddress(a netip.Addr) error { return CheckNodeAddress(a) }

// nodes returns the nodes VMs are placed on: the configured list, checked to
// be online, or every online node sorted by name. A spec's zones must be
// online too.
func (c *Compute) nodes(ctx context.Context, specs []infra.VMSpec) ([]string, error) {
	all, err := c.pve.Nodes(ctx)
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
	want := slices.Clone(c.Config.Nodes)
	for _, s := range specs {
		want = append(want, s.Zones...)
	}
	for _, n := range want {
		if !online[n] {
			return nil, fmt.Errorf("proxmox node %q is not an online cluster node (online: %v)", n, names)
		}
	}
	if len(c.Config.Nodes) > 0 {
		return c.Config.Nodes, nil
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
func (c *Compute) guestNets(ctx context.Context, guests []pve.Resource) (map[int]GuestNet, error) {
	nets := map[int]GuestNet{}
	for _, g := range guests {
		conf, err := c.pve.GuestConfig(ctx, g)
		if err != nil {
			return nil, fmt.Errorf("reading the config of vmid %d to check its address: %w", g.VMID, err)
		}
		n := GuestNet{Addresses: GuestAddresses(conf), MACs: GuestMACs(conf), Net0MAC: Net0MAC(conf)}
		if path, ok := SnippetFileForVolume(c.SnippetsDir, c.Config.SnippetStorage, CustomNetworkVolume(conf)); ok {
			if text, found, err := readSnippet(path); err == nil && found {
				n.Addresses = append(n.Addresses, SnippetAddresses(text)...)
			}
		}
		nets[g.VMID] = n
	}
	return nets, nil
}

// nic is a NIC on the node network, with addr its address when known.
func (c *Compute) nic(network, mac string, addr netip.Addr) infra.NIC {
	n := infra.NIC{
		Network: network, MAC: mac, Subnet: NodeSubnet, Gateway: Gateway, MTU: VnetMTU,
		SearchDomains: []string{c.Config.SearchDomain},
	}
	if ns, err := netip.ParseAddr(c.Config.Nameserver); err == nil {
		n.Nameservers = []netip.Addr{ns}
	}
	if addr.IsValid() {
		// Every node address on the vnet is a /32.
		n.Address = netip.PrefixFrom(addr, 32)
	}
	return n
}

// report is one of the cluster's VMs as the contract reports it, with its
// size read from its pending list.
func (c *Compute) report(ctx context.Context, v pve.Resource, region string, nic infra.NIC) infra.VM {
	vm := infra.VM{
		Name: v.Name, ID: vmID(v.VMID), Labels: Labels(v), Region: region, Zone: v.Node, Status: v.Status, NIC: nic,
		Size: infra.Size{Cores: int(v.MaxCPU), MemoryMiB: int(v.MaxMem >> 20)},
	}
	vm.Sizing, vm.SizingErr = c.sizing(ctx, v)
	return vm
}

// Plan reads Proxmox and works out what Create does with specs. It checks
// everything it can before anything changes: its config, the specs, the snippets
// directory, the token's privileges, the node list, name, address and MAC
// conflicts, and that no existing VM's address would change. A VM that
// exists is reported as it is, with its size; a new one with the node, MAC
// and address it gets.
func (c *Compute) Plan(ctx context.Context, cluster string, specs []infra.VMSpec) (infra.Plan, error) {
	// The config is checked here too, since a Compute need not come from
	// talosvm, which checks it first: a bad nameserver would otherwise go
	// missing from every NIC.
	if err := c.Config.Validate(); err != nil {
		return nil, err
	}
	if err := checkSpecs(cluster, specs); err != nil {
		return nil, err
	}
	if err := CheckSnippetsDir(c.SnippetsDir, c.DryRun); err != nil {
		return nil, err
	}
	if err := c.Check(ctx); err != nil {
		return nil, err
	}
	nodes, err := c.nodes(ctx, specs)
	if err != nil {
		return nil, err
	}
	zones, err := place(specs, nodes)
	if err != nil {
		return nil, err
	}
	guests, err := c.pve.VMs(ctx)
	if err != nil {
		return nil, err
	}
	create, existing, err := Reconcile(specs, guests, cluster)
	if err != nil {
		return nil, err
	}
	region, err := c.pve.ClusterName(ctx)
	if err != nil {
		return nil, err
	}
	nets, err := c.guestNets(ctx, guests)
	if err != nil {
		return nil, err
	}
	p := &createPlan{
		config: c.Config, cluster: cluster, specs: specs, vms: make([]infra.VM, len(specs)),
		create: create, existing: existing, guests: guests, dir: c.SnippetsDir, read: readOwnedSnippet,
	}
	for _, i := range create {
		s := specs[i]
		p.vms[i] = infra.VM{Name: s.Name, Labels: s.Labels, Region: region, Zone: zones[i], NIC: c.nic(s.Network, "", s.Address)}
	}
	for _, a := range existing {
		// The VM is on the bridge its spec names, since create never
		// changes an existing VM's net0.
		p.vms[a.i] = c.report(ctx, a.vm, region, c.nic(specs[a.i].Network, "", specs[a.i].Address))
	}
	if err := p.allocate(nets); err != nil {
		return nil, err
	}
	return p, nil
}

// Create carries out a plan Plan made. It checks the storages on the nodes
// new VMs go to, looks for the ISO there, and gives the new VMs their VMIDs,
// then builds the full list of calls: the ISO download where it is missing,
// each snippet with the VM's config, and the create and start calls. It
// prints the list, and unless this is a dry run sends the calls one at a
// time, waiting for each task.
func (c *Compute) Create(ctx context.Context, plan infra.Plan, configs map[string]string) error {
	p, ok := plan.(*createPlan)
	if !ok {
		return fmt.Errorf("proxmox: create was given a plan it did not make (%T)", plan)
	}
	var calls []Call
	var vmids []int
	if len(p.create) > 0 {
		var targets []string
		for _, i := range p.create {
			if z := p.vms[i].Zone; !slices.Contains(targets, z) {
				targets = append(targets, z)
			}
		}
		storages, err := c.pve.Storages(ctx)
		if err != nil {
			return err
		}
		shared, err := CheckStorages(c.Config, targets, storages)
		if err != nil {
			return err
		}
		// Each image once per node its new VMs go to. A shared storage
		// shows a file fetched through one node on every node, so it
		// needs one download; a local one needs one per node.
		var images []infra.Image
		via := map[infra.Image][]string{}
		for _, i := range p.create {
			img, z := p.specs[i].Image, p.vms[i].Zone
			if _, ok := via[img]; !ok {
				images = append(images, img)
			}
			if !slices.Contains(via[img], z) {
				via[img] = append(via[img], z)
			}
		}
		for _, img := range images {
			fetchVia := via[img]
			if shared {
				fetchVia = fetchVia[:1]
			}
			for _, node := range fetchVia {
				present, err := c.isoPresent(ctx, node, img)
				if err != nil {
					return err
				}
				if present {
					c.logf("iso      %s present on %s", isoVolID(c.Config.ISOStorage, img), node)
					continue
				}
				calls = append(calls, DownloadCall(c.Config, node, img))
			}
		}
		next, err := c.pve.NextID(ctx)
		if err != nil {
			return err
		}
		vmids = AllocateVMIDs(next, len(p.create), p.guests)
	}
	vmCalls, err := p.Calls(configs, vmids)
	if err != nil {
		return err
	}
	calls = append(calls, vmCalls...)
	if len(calls) == 0 {
		c.logf("nothing to do")
		return nil
	}
	return c.send(ctx, calls)
}

func (c *Compute) isoPresent(ctx context.Context, node string, img infra.Image) (bool, error) {
	content, err := c.pve.Content(ctx, node, c.Config.ISOStorage, "iso")
	if err != nil {
		return false, err
	}
	volid := isoVolID(c.Config.ISOStorage, img)
	return slices.ContainsFunc(content, func(s pve.StorageContent) bool { return s.VolID == volid }), nil
}

// send prints every call, then sends them in order unless this is a dry
// run. Printing the whole list first means a failure halfway leaves a record
// of what was meant to follow.
func (c *Compute) send(ctx context.Context, calls []Call) error {
	for i, call := range calls {
		c.logf("# %d/%d %s", i+1, len(calls), call.What)
		c.logf("%s", call)
	}
	if c.DryRun {
		c.logf("dry run: sent none of these %d calls", len(calls))
		return nil
	}
	for i, call := range calls {
		switch call.Method {
		case WriteFile, RemoveFile:
			// Check again: the directory is shared, and the plan was made
			// a while ago.
			_, _, err := readOwnedSnippet(call.Path, call.Header)
			if err != nil {
				return fmt.Errorf("step %d/%d, %s: %w", i+1, len(calls), call.What, err)
			}
			if call.Method == WriteFile {
				err = writeFileAtomic(call.Path, call.Content)
			} else if err = os.Remove(call.Path); errors.Is(err, fs.ErrNotExist) {
				err = nil
			}
			if err != nil {
				return fmt.Errorf("step %d/%d, %s: %w", i+1, len(calls), call.What, err)
			}
			c.logf("done %d/%d %s", i+1, len(calls), call.What)
			continue
		}
		if err := c.call(ctx, call); err != nil {
			return fmt.Errorf("call %d/%d, %s: %w", i+1, len(calls), call.What, err)
		}
		c.logf("done %d/%d %s", i+1, len(calls), call.What)
	}
	return nil
}

// call sends one API call and waits, for at most its timeout, for the task
// it starts. A PUT of a VM's config starts no task: it is done when it
// returns.
func (c *Compute) call(ctx context.Context, call Call) error {
	if call.Method == http.MethodPut {
		return c.pve.Put(ctx, call.Path, call.Params)
	}
	var upid string
	if err := c.pve.Do(ctx, call.Method, call.Path, call.Params, &upid); err != nil {
		return err
	}
	wctx, cancel := context.WithTimeout(ctx, call.Timeout)
	defer cancel()
	return c.pve.WaitTask(wctx, upid)
}

// vmNet returns what a VM's config says about its NIC: its bridge, net0's
// MAC, and its node address, or the zero address when it has none in the
// node subnet. The address is in the VM's network snippet, so it is found
// only while the snippets mount is there to read.
func (c *Compute) vmNet(ctx context.Context, v pve.Resource) (bridge, mac string, addr netip.Addr, err error) {
	conf, err := c.pve.GuestConfig(ctx, v)
	if err != nil {
		return "", "", netip.Addr{}, err
	}
	as := GuestAddresses(conf)
	if path, ok := SnippetFileForVolume(c.SnippetsDir, c.Config.SnippetStorage, CustomNetworkVolume(conf)); ok {
		if text, found, err := readSnippet(path); err == nil && found {
			as = append(as, SnippetAddresses(text)...)
		}
	}
	for _, a := range as {
		if NodeSubnet.Contains(a) && a != Gateway {
			addr = a
			break
		}
	}
	return netProp(conf["net0"], "bridge"), Net0MAC(conf), addr, nil
}

// List returns the cluster's VMs, by name. Region and Zone are the Proxmox
// cluster and node. A VM's address is left out when the snippets mount is
// not there to read, and its Sizing when its pending list cannot be read,
// which one VM's failure does not stop the rest of the list for.
func (c *Compute) List(ctx context.Context, cluster string) ([]infra.VM, error) {
	if cluster == "" {
		return nil, fmt.Errorf("cluster is required: name the cluster with -cluster or in the config")
	}
	guests, err := c.pve.VMs(ctx)
	if err != nil {
		return nil, err
	}
	region, err := c.pve.ClusterName(ctx)
	if err != nil {
		return nil, err
	}
	vms := []infra.VM{}
	for _, v := range OwnedVMs(guests, cluster) {
		bridge, mac, addr, err := c.vmNet(ctx, v)
		if err != nil {
			return nil, err
		}
		vms = append(vms, c.report(ctx, v, region, c.nic(bridge, mac, addr)))
	}
	return vms, nil
}

// Resize sets the cores and memory of each VM with PUT
// /nodes/{node}/qemu/{vmid}/config, printing the calls first, as create
// does. The call carries only what differs from what the VM's config holds
// for its next start; a VM that already holds its new size gets none. Every
// VM must be the cluster's, as Proxmox lists it now, or nothing is sent.
func (c *Compute) Resize(ctx context.Context, cluster string, resizes []infra.Resize) error {
	vms := make([]infra.VM, len(resizes))
	for i, z := range resizes {
		vms[i] = z.VM
	}
	rs, err := c.owned(ctx, cluster, vms)
	if err != nil {
		return err
	}
	var calls []Call
	for i, z := range resizes {
		if call, ok := resizeCall(rs[i], z); ok {
			calls = append(calls, call)
		}
	}
	if len(calls) == 0 {
		return nil
	}
	return c.send(ctx, calls)
}

// owned reads the guests again and returns each VM as Proxmox lists it now.
// It refuses, before anything changes, a VM that is not one of the
// cluster's: one with another ID than a VMID, one whose VMID belongs to a
// guest without both the managed and the cluster tag, such as another
// cluster's VM or a hand-made one, and one whose VMID now names another VM.
// The ownership check sits beside the call, as it does for destroy, so a VM
// a caller built by hand is no way around it.
func (c *Compute) owned(ctx context.Context, cluster string, vms []infra.VM) ([]pve.Resource, error) {
	if cluster == "" || !label.MatchString(cluster) {
		return nil, fmt.Errorf("cluster %q: want the cluster the VMs belong to", cluster)
	}
	guests, err := c.pve.VMs(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]pve.Resource, len(vms))
	var errs []error
	for i, vm := range vms {
		vmid, err := strconv.Atoi(vm.ID.Value)
		if vm.ID.Kind != "vmid" || err != nil {
			errs = append(errs, fmt.Errorf("VM %s: not a Proxmox VM (%s)", vm.Name, vm.ID))
			continue
		}
		k := slices.IndexFunc(guests, func(g pve.Resource) bool { return g.VMID == vmid })
		if k < 0 || !Owned(guests[k], cluster) || guests[k].Name != vm.Name {
			errs = append(errs, fmt.Errorf("VM %s (%s) is not a VM of cluster %s", vm.Name, vm.ID, cluster))
			continue
		}
		out[i] = guests[k]
	}
	if len(errs) > 0 {
		return nil, fmt.Errorf("refusing to change: %w", errors.Join(errs...))
	}
	return out, nil
}

// PowerCycle shuts the VM down and starts it again through the Proxmox API,
// which starts a new QEMU process: a changed VM config, such as new memory,
// applies only this way, since a reboot inside the guest keeps the running
// process and the hardware it was started with. It prints nothing; the
// caller prints PowerCycleCalls. The VM must be the cluster's, as Proxmox
// lists it now. A dry run checks that and sends nothing.
func (c *Compute) PowerCycle(ctx context.Context, cluster string, vm infra.VM, timeout time.Duration) error {
	rs, err := c.owned(ctx, cluster, []infra.VM{vm})
	if err != nil {
		return err
	}
	if c.DryRun {
		return nil
	}
	r := rs[0]
	shutdown, start := powerCycleCalls(r.Name, strconv.Itoa(r.VMID), r.Node, timeout)
	// A rerun of restart refuses a stopped VM, so either failure says to
	// start it by hand.
	if err := c.call(ctx, shutdown); err != nil {
		return fmt.Errorf("%w; the VM may still be shutting down: once it is stopped, start it in Proxmox", err)
	}
	if err := c.call(ctx, start); err != nil {
		return fmt.Errorf("%w; the VM is stopped: start it in Proxmox", err)
	}
	return nil
}

// PowerCycleCalls returns PowerCycle's two calls as a dry run prints them.
func (c *Compute) PowerCycleCalls(vm infra.VM, timeout time.Duration) []string {
	shutdown, start := powerCycleCalls(vm.Name, vm.ID.Value, vm.Zone, timeout)
	return []string{shutdown.String(), start.String()}
}

// Destroy stops and deletes the cluster's VMs and their disks, and removes
// their snippets. It touches only VMs Owned selects. A dry run prints the
// calls and sends none, and the command line makes the dry run the default,
// so the destructive run is always a second, deliberate command.
func (c *Compute) Destroy(ctx context.Context, cluster string) error {
	if cluster == "" || !label.MatchString(cluster) {
		return fmt.Errorf("cluster %q: name the cluster to destroy with -cluster", cluster)
	}
	if err := CheckSnippetsDir(c.SnippetsDir, c.DryRun); err != nil {
		return err
	}
	if err := c.Check(ctx); err != nil {
		return err
	}
	guests, err := c.pve.VMs(ctx)
	if err != nil {
		return err
	}
	calls, err := DestroyCalls(guests, cluster, c.SnippetsDir, readOwnedSnippet)
	if err != nil {
		return err
	}
	if len(calls) == 0 {
		c.logf("no talosvm VMs for cluster %s", cluster)
		return nil
	}
	return c.send(ctx, calls)
}
