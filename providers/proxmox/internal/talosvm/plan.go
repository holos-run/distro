package talosvm

import (
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"net/url"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"go.holos.run/distro/providers/proxmox/internal/pve"
)

// Tags. Proxmox tags are free-form labels on a VM; these are how the program
// recognizes its own VMs and how later items find a VM's role and pool. All
// but the first carry the program's name too, so a tag someone types by hand
// for another purpose, such as cluster-x, is never taken for one of these.
const (
	// TagManaged marks every VM talosvm created.
	TagManaged = "talosvm"
	// RoleControlPlane and RoleWorker are the two roles.
	RoleControlPlane = "controlplane"
	RoleWorker       = "worker"

	clusterTagPrefix = "talosvm-cluster-"
	roleTagPrefix    = "talosvm-role-"
	poolTagPrefix    = "talosvm-pool-"

	controlPlaneName = "cp"
)

// ClusterTag is the tag that scopes a VM to one cluster.
func ClusterTag(cluster string) string { return clusterTagPrefix + cluster }

// RoleTag is the tag that records a VM's role.
func RoleTag(role string) string { return roleTagPrefix + role }

// PoolTag is the tag that puts a worker in a pool.
func PoolTag(pool string) string { return poolTagPrefix + pool }

// Spec is one VM the config asks for.
type Spec struct {
	Name string
	Role string
	// Pool is empty for the control plane.
	Pool string
	// Node is the Proxmox node the VM is created on.
	Node    string
	Address netip.Addr
	// MAC is net0's MAC address, which the network snippet matches on: the
	// first candidate until the plan picks a free one.
	MAC string
	Size
}

// Tags returns the VM's tags in a stable order.
func (s Spec) Tags(cluster string) []string {
	tags := []string{TagManaged, ClusterTag(cluster), RoleTag(s.Role)}
	if s.Pool != "" {
		tags = append(tags, PoolTag(s.Pool))
	}
	return tags
}

// Specs expands the config into VMs, named <cluster>-cp-<n> and
// <cluster>-<pool>-<n> from 1. Placement is round robin over each group's
// node list, continuing one sequence across groups, so a single control plane
// and its workers start on different hosts and three workers on three hosts
// land one per host after it. Placement and addresses depend only on the
// config and the node list, so a VM removed by hand comes back on the same
// node with the same address when create runs again.
func Specs(c Config, nodes []string) ([]Spec, error) {
	addrs, err := c.addresses()
	if err != nil {
		return nil, err
	}
	if len(nodes) == 0 {
		return nil, errors.New("no Proxmox nodes to place VMs on")
	}
	var specs []Spec
	seq := 0
	place := func(override []string) string {
		list := nodes
		if len(override) > 0 {
			list = override
		}
		n := list[seq%len(list)]
		seq++
		return n
	}
	for i := range c.ControlPlane.Count {
		specs = append(specs, Spec{
			Name: fmt.Sprintf("%s-%s-%d", c.Cluster, controlPlaneName, i+1),
			Role: RoleControlPlane,
			Node: place(c.ControlPlane.Nodes),
			Size: c.ControlPlane.Size,
		})
	}
	for _, p := range c.Pools {
		for i := range p.Count {
			specs = append(specs, Spec{
				Name: fmt.Sprintf("%s-%s-%d", c.Cluster, p.Name, i+1),
				Role: RoleWorker,
				Pool: p.Name,
				Node: place(p.Nodes),
				Size: p.Size,
			})
		}
	}
	for i := range specs {
		specs[i].Address = addrs[i]
		specs[i].MAC = MACFor(c.Cluster, specs[i].Name, 0)
	}
	return specs, nil
}

// CreateParams is the body of POST /nodes/{node}/qemu for one VM. The
// settings follow the Talos Proxmox guide and the plan:
//
//   - scsihw virtio-scsi-pci. VirtIO SCSI single is the Proxmox default for
//     new VMs and the guide warns it can hang Talos at bootstrap.
//   - cpu host, so the guest sees the host's vmx flag and Kata's microVMs get
//     /dev/kvm (the host kernel's kvm_intel nested=Y is the other half), and
//     Talos's x86-64-v2 requirement is met.
//   - balloon 0, as the guide says: ballooning confuses Talos's memory
//     detection, and memory a balloon takes back is memory the kubelet has
//     already promised to pods.
//   - OVMF on q35 with a 4m EFI disk without pre-enrolled keys, the guide's
//     recommendation. Enrolled keys would turn on Secure Boot, which the
//     plain ISO is not signed for.
//   - agent enabled, which only works because the schematic carries the
//     qemu-guest-agent extension; serial0 a socket, for a console that
//     survives a hung display, as on the garage's Talos templates.
//   - the ISO on ide0 and the cloud-init drive on ide2, where the garage's
//     other VMs keep it. citype nocloud matches the nocloud ISO, and
//     cicustom points the drive's network-config at the VM's snippet, which
//     gives the /32 address and the on-link route to the anycast gateway
//     that Proxmox's own ipconfig0 cannot express.
//   - net0 virtio on the vnet with the MAC the snippet matches and mtu=1,
//     which makes the NIC take the bridge's MTU (8950 on k8s) instead of
//     1500; the snippet sets the same MTU inside Talos.
//   - boot from the system disk first, then the ISO. The disk is empty until
//     talosctl installs Talos, so the first boot falls through to the ISO,
//     and every boot after the install comes from the disk.
//   - onboot 1, so the VM comes up after a host reboot. It is not started
//     by the create call: Proxmox only warns when start-after-create fails
//     and the task still ends well, so the plan starts it with a call of its
//     own, whose failure is an error.
func CreateParams(c Config, s Spec, vmid int, img Image, description string) url.Values {
	disk := fmt.Sprintf("%s:%d,discard=on", c.DiskStorage, s.DiskGiB)
	if c.DiskSSD {
		disk += ",ssd=1"
	}
	return url.Values{
		"vmid":        {strconv.Itoa(vmid)},
		"name":        {s.Name},
		"tags":        {strings.Join(s.Tags(c.Cluster), ";")},
		"description": {description},
		"ostype":      {"l26"},
		"machine":     {"q35"},
		"bios":        {"ovmf"},
		"efidisk0":    {c.DiskStorage + ":1,efitype=4m,pre-enrolled-keys=0"},
		"cpu":         {"host"},
		"sockets":     {"1"},
		"cores":       {strconv.Itoa(s.Cores)},
		"memory":      {strconv.Itoa(s.MemoryMiB)},
		"balloon":     {"0"},
		"scsihw":      {"virtio-scsi-pci"},
		"scsi0":       {disk},
		"ide0":        {img.VolID(c.ISOStorage) + ",media=cdrom"},
		"ide2":        {c.DiskStorage + ":cloudinit"},
		"citype":      {"nocloud"},
		"cicustom":    {"network=" + SnippetVolume(c.SnippetStorage, SnippetName(c.Cluster, s.Name))},
		"net0":        {"virtio=" + s.MAC + ",bridge=" + c.Bridge + ",mtu=1"},
		"serial0":     {"socket"},
		"boot":        {"order=scsi0;ide0"},
		"agent":       {"enabled=1"},
		"onboot":      {"1"},
	}
}

// Owned reports whether a guest is a talosvm VM of the given cluster. Both
// tags are required: the managed tag alone would match another cluster's VMs,
// and a cluster tag alone could have been typed by hand on anything.
// Templates and containers are never owned.
func Owned(r pve.Resource, cluster string) bool {
	if r.Type != "qemu" || r.Template != 0 || cluster == "" {
		return false
	}
	tags := r.TagList()
	return slices.Contains(tags, TagManaged) && slices.Contains(tags, ClusterTag(cluster))
}

// OwnedVMs filters guests to the cluster's VMs, sorted by name.
func OwnedVMs(rs []pve.Resource, cluster string) []pve.Resource {
	var out []pve.Resource
	for _, r := range rs {
		if Owned(r, cluster) {
			out = append(out, r)
		}
	}
	slices.SortFunc(out, func(a, b pve.Resource) int { return strings.Compare(a.Name, b.Name) })
	return out
}

// Action is what create does with one spec.
type Action struct {
	Spec Spec
	// Existing is the VM already carrying the spec's name, if any.
	Existing *pve.Resource
}

// Reconcile matches specs against the cluster's guests by name. A spec whose
// name is free is to be created. A spec whose name belongs to one of this
// cluster's talosvm VMs is skipped, whatever node it is on and whatever its
// size, since create never changes a VM it already made. A spec whose name is
// taken by anything else is an error, and the whole run stops before any
// change, because creating a second VM with the same name would confuse
// every later step and taking over the existing one could destroy it later.
func Reconcile(specs []Spec, rs []pve.Resource, cluster string) (create, skip []Action, err error) {
	byName := map[string][]pve.Resource{}
	for _, r := range rs {
		byName[r.Name] = append(byName[r.Name], r)
	}
	var conflicts []string
	for _, s := range specs {
		existing := byName[s.Name]
		switch {
		case len(existing) == 0:
			create = append(create, Action{Spec: s})
		case len(existing) == 1 && Owned(existing[0], cluster):
			r := existing[0]
			skip = append(skip, Action{Spec: s, Existing: &r})
		default:
			for _, r := range existing {
				conflicts = append(conflicts, fmt.Sprintf("%s (vmid %d on %s, tags %q)", s.Name, r.VMID, r.Node, r.Tags))
			}
		}
	}
	if len(conflicts) > 0 {
		return nil, nil, fmt.Errorf("refusing to create: these names are taken by VMs talosvm did not create for cluster %s: %s",
			cluster, strings.Join(conflicts, ", "))
	}
	return create, skip, nil
}

// GuestNet is what a guest's config says about its network: the addresses
// it assigns, from ipconfigN, netN or its cicustom network snippet, its
// NICs' MAC addresses, and net0's MAC in particular.
type GuestNet struct {
	Addresses []netip.Addr
	MACs      []string
	Net0MAC   string
}

// CheckStorages checks that the disk storage accepts images and the ISO
// storage accepts ISOs on every node a VM goes to, so a missing storage is
// found before the first VM is made rather than halfway through. It returns
// whether the ISO storage is shared, which decides how many downloads the ISO
// takes.
func CheckStorages(c Config, nodes []string, storages []pve.Storage) (isoShared bool, err error) {
	find := func(node, name string) *pve.Storage {
		for i := range storages {
			if storages[i].Node == node && storages[i].Storage == name {
				return &storages[i]
			}
		}
		return nil
	}
	var errs []error
	isoShared = true
	for _, n := range nodes {
		for _, want := range []struct{ storage, content string }{{c.DiskStorage, "images"}, {c.ISOStorage, "iso"}, {c.SnippetStorage, "snippets"}} {
			s := find(n, want.storage)
			switch {
			case s == nil:
				errs = append(errs, fmt.Errorf("storage %s is not on node %s", want.storage, n))
			case s.Status != "" && s.Status != "available":
				errs = append(errs, fmt.Errorf("storage %s on node %s is %s", want.storage, n, s.Status))
			case !s.HasContent(want.content):
				errs = append(errs, fmt.Errorf("storage %s on node %s does not allow %s content (has %q)", want.storage, n, want.content, s.Content))
			}
			if s != nil && want.storage == c.ISOStorage && s.Shared == 0 {
				isoShared = false
			}
		}
	}
	return isoShared, errors.Join(errs...)
}

// Call is one Proxmox API call that changes the cluster. Create and destroy
// build their whole list of calls before sending any, so a dry run prints
// exactly what a real run sends.
type Call struct {
	// Method is an HTTP method for an API call, or WriteFile or RemoveFile
	// for a snippet in the mounted snippets directory, where Path is the
	// local file and Content what is written.
	Method  string
	Path    string
	Params  url.Values
	Content string
	// Header is, for a file operation, the first line a file already at
	// Path must have; the file is checked again just before it is
	// overwritten or removed.
	Header string
	// What says what the call does, for the log.
	What string
	// Timeout bounds the task the call starts.
	Timeout time.Duration
}

// String prints the call as the API sees it: the method and full path, with
// a DELETE's parameters in the query string and a POST's form fields one per
// line, sorted.
func (c Call) String() string {
	var b strings.Builder
	switch c.Method {
	case WriteFile:
		fmt.Fprintf(&b, "%s %s (mode 0644)", c.Method, c.Path)
		for _, line := range strings.Split(strings.TrimSuffix(c.Content, "\n"), "\n") {
			fmt.Fprintf(&b, "\n    | %s", line)
		}
		return b.String()
	case RemoveFile:
		fmt.Fprintf(&b, "%s %s", c.Method, c.Path)
		return b.String()
	}
	path := "/api2/json" + c.Path
	if c.Method == http.MethodDelete || c.Method == http.MethodGet {
		if q := c.Params.Encode(); q != "" {
			path += "?" + q
		}
		fmt.Fprintf(&b, "%s %s", c.Method, path)
		return b.String()
	}
	fmt.Fprintf(&b, "%s %s", c.Method, path)
	keys := make([]string, 0, len(c.Params))
	for k := range c.Params {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	for _, k := range keys {
		for _, v := range c.Params[k] {
			fmt.Fprintf(&b, "\n    %s=%s", k, strings.ReplaceAll(v, "\n", `\n`))
		}
	}
	return b.String()
}

// The file operations a plan can hold besides API calls.
const (
	WriteFile  = "WRITE"
	RemoveFile = "REMOVE"
)

// Task timeouts. An ISO download from Image Factory is a few hundred MiB
// onto NFS; everything else is local and quick.
const (
	downloadTimeout = 30 * time.Minute
	taskTimeout     = 10 * time.Minute
)

// DownloadCall fetches the ISO into the ISO storage through node.
func DownloadCall(c Config, node string, img Image) Call {
	return Call{
		Method: http.MethodPost,
		Path:   "/nodes/" + url.PathEscape(node) + "/storage/" + url.PathEscape(c.ISOStorage) + "/download-url",
		Params: url.Values{
			"content":             {"iso"},
			"filename":            {img.Filename()},
			"url":                 {img.ISOURL()},
			"verify-certificates": {"1"},
		},
		What:    fmt.Sprintf("download %s into %s through %s", img.Filename(), c.ISOStorage, node),
		Timeout: downloadTimeout,
	}
}

// AllocateVMIDs gives n VMs their IDs: next, the answer of /cluster/nextid,
// and the IDs after it that no guest uses. Planning them up front is what
// lets a dry run print the exact create calls. If something else takes one
// of them between plan and create, Proxmox refuses the create, which stops
// the run without touching the other VM.
func AllocateVMIDs(next, n int, guests []pve.Resource) []int {
	used := map[int]bool{}
	for _, g := range guests {
		used[g.VMID] = true
	}
	var ids []int
	for id := next; len(ids) < n; id++ {
		if !used[id] {
			ids = append(ids, id)
		}
	}
	return ids
}

// VMPlan is everything create knows once it has read Proxmox: the VMs to
// create and the cluster's VMs that exist already, every guest and what its
// config says about its network, the snippets directory, and the VMIDs and
// image for the new VMs.
type VMPlan struct {
	Config      Config
	Create      []Action
	Existing    []Action
	Guests      []pve.Resource
	Nets        map[int]GuestNet
	Dir         string
	VMIDs       []int
	Image       Image
	SchematicID string
	// Read reads one of talosvm's snippets: (content, found, error), with
	// the error for a file that is there but is not a regular file starting
	// with the given header. readOwnedSnippet in production.
	Read func(path, header string) (string, bool, error)
}

// maxMACAttempts bounds the search for a free MAC; with three fresh bytes
// per attempt it is only reached if something is badly wrong.
const maxMACAttempts = 64

type holder struct {
	vmid int
	who  string
}

// Calls checks the plan against the cluster and returns its calls, which
// follow the ISO downloads. It refuses the whole run, before any change, on
// any problem:
//
//   - An existing VM's address never changes. If its snippet is there, the
//     address in it must be the one the config gives it now; if not, create
//     refuses rather than move a cluster's node onto an address that may by
//     now be another cluster's. If the snippet is missing, it is written
//     again, after the same collision check a new VM gets, with the MAC on
//     the VM's net0. An existing VM that is stopped is started.
//   - A new VM's address must be free, counting every guest and every VM
//     earlier in the same run, and its MAC is the first candidate no guest
//     and no earlier VM has. It gets its snippet, then a create call, then a
//     start call.
//   - A snippet file is only ever overwritten if it is talosvm's for the
//     same cluster and VM.
func (p VMPlan) Calls() ([]Call, error) {
	c := p.Config
	addrs := map[netip.Addr][]holder{}
	macs := map[string][]holder{}
	for _, g := range p.Guests {
		h := holder{g.VMID, fmt.Sprintf("vmid %d %s on %s", g.VMID, g.Name, g.Node)}
		for _, a := range p.Nets[g.VMID].Addresses {
			addrs[a] = append(addrs[a], h)
		}
		for _, m := range p.Nets[g.VMID].MACs {
			macs[m] = append(macs[m], h)
		}
	}
	// others names the holders that are not vmid.
	others := func(hs []holder, vmid int) []string {
		var out []string
		for _, h := range hs {
			if h.vmid != vmid {
				out = append(out, h.who)
			}
		}
		return out
	}
	snippet := func(s Spec) (path, header string) {
		return filepath.Join(p.Dir, SnippetName(c.Cluster, s.Name)), SnippetHeader(c.Cluster, s.Name)
	}
	start := func(node string, vmid int, name string) Call {
		return Call{
			Method:  http.MethodPost,
			Path:    "/nodes/" + url.PathEscape(node) + "/qemu/" + strconv.Itoa(vmid) + "/status/start",
			Params:  url.Values{},
			What:    fmt.Sprintf("start %s vmid %d on %s", name, vmid, node),
			Timeout: taskTimeout,
		}
	}
	var errs []error
	var calls []Call

	for _, a := range p.Existing {
		s, vm := a.Spec, a.Existing
		path, header := snippet(s)
		have, found, err := p.Read(path, header)
		switch {
		case err != nil:
			errs = append(errs, err)
		case found:
			got, ok := SnippetNodeAddress(have)
			if !ok {
				errs = append(errs, fmt.Errorf("VM %s: cannot find its address in %s", s.Name, path))
			} else if got != s.Address {
				errs = append(errs, fmt.Errorf("VM %s has address %s, config says %s: create never moves an existing VM; give the config its original addresses, or destroy and create the cluster", s.Name, got, s.Address))
			}
		default:
			mac := p.Nets[vm.VMID].Net0MAC
			if mac == "" {
				errs = append(errs, fmt.Errorf("VM %s has no MAC on net0 to write its missing snippet for", s.Name))
				break
			}
			if who := others(addrs[s.Address], vm.VMID); len(who) > 0 {
				errs = append(errs, fmt.Errorf("VM %s: its snippet is missing and its address %s is now used by %s", s.Name, s.Address, strings.Join(who, ", ")))
				break
			}
			calls = append(calls, Call{
				Method:  WriteFile,
				Path:    path,
				Content: NetworkConfig(c, s, mac),
				Header:  header,
				What:    fmt.Sprintf("write the missing network snippet of %s, %s/32 on MAC %s", s.Name, s.Address, mac),
			})
		}
		addrs[s.Address] = append(addrs[s.Address], holder{vm.VMID, s.Name})
		if vm.Status == "stopped" {
			calls = append(calls, start(vm.Node, vm.VMID, s.Name))
		}
	}

	for i, a := range p.Create {
		s := a.Spec
		vmid := p.VMIDs[i]
		if who := others(addrs[s.Address], vmid); len(who) > 0 {
			errs = append(errs, fmt.Errorf("%s: address %s is already used by %s", s.Name, s.Address, strings.Join(who, ", ")))
		}
		addrs[s.Address] = append(addrs[s.Address], holder{vmid, s.Name + " (created by this run)"})
		s.MAC = ""
		for k := range maxMACAttempts {
			if m := MACFor(c.Cluster, s.Name, k); len(macs[m]) == 0 {
				s.MAC = m
				break
			}
		}
		if s.MAC == "" {
			errs = append(errs, fmt.Errorf("%s: no free MAC in %d attempts", s.Name, maxMACAttempts))
			continue
		}
		macs[s.MAC] = append(macs[s.MAC], holder{vmid, s.Name + " (created by this run)"})

		path, header := snippet(s)
		content := NetworkConfig(c, s, s.MAC)
		have, found, err := p.Read(path, header)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		// The snippet of a VM that does not exist is left over from a run
		// that stopped early; it is rewritten when it differs.
		if !found || have != content {
			calls = append(calls, Call{
				Method:  WriteFile,
				Path:    path,
				Content: content,
				Header:  header,
				What:    fmt.Sprintf("write the network snippet of %s, %s/32 on MAC %s", s.Name, s.Address, s.MAC),
			})
		}
		calls = append(calls, Call{
			Method:  http.MethodPost,
			Path:    "/nodes/" + url.PathEscape(s.Node) + "/qemu",
			Params:  CreateParams(c, s, vmid, p.Image, p.description()),
			What:    fmt.Sprintf("create %s vmid %d on %s at %s (%d cores, %d MiB, %d GiB)", s.Name, vmid, s.Node, s.Address, s.Cores, s.MemoryMiB, s.DiskGiB),
			Timeout: taskTimeout,
		}, start(s.Node, vmid, s.Name))
	}
	if len(errs) > 0 {
		return nil, fmt.Errorf("refusing to create: %w", errors.Join(errs...))
	}
	return calls, nil
}

func (p VMPlan) description() string {
	return fmt.Sprintf("Created by talosvm (go.holos.run/distro/providers/proxmox/cmd/talosvm) for cluster %s.\nTalos %s, schematic %s.",
		p.Config.Cluster, p.Config.TalosVersion, p.SchematicID)
}

// DestroyCalls is the calls that remove the cluster's VMs: a hard stop for
// each VM that is not stopped, then a delete with purge, which also drops the
// VM from backup jobs, replication and HA, then the removal of the VM's
// network snippet when it is there. The snippet removed is the one file
// SnippetName gives for the VM, and only if read finds it is talosvm's for
// that cluster and VM; anything else at that path stops the plan. Nothing is
// globbed, so another tenant's snippet in the same directory is never
// touched. The delete removes the disks the VM's config references.
// destroy-unreferenced-disks is not sent: it scans every storage for disks
// named after the VMID, and a stale disk on some other tenant's storage that
// happens to carry the same number is not this program's to delete. Only
// Owned VMs are ever in the list.
func DestroyCalls(guests []pve.Resource, cluster, dir string, read func(path, header string) (string, bool, error)) ([]Call, error) {
	var calls []Call
	var errs []error
	for _, v := range OwnedVMs(guests, cluster) {
		base := "/nodes/" + url.PathEscape(v.Node) + "/qemu/" + strconv.Itoa(v.VMID)
		if v.Status != "stopped" {
			// A hard stop, not a shutdown: the VM is about to be deleted,
			// and a Talos node has nothing to flush that matters.
			calls = append(calls, Call{
				Method:  http.MethodPost,
				Path:    base + "/status/stop",
				Params:  url.Values{},
				What:    fmt.Sprintf("stop %s vmid %d on %s", v.Name, v.VMID, v.Node),
				Timeout: taskTimeout,
			})
		}
		calls = append(calls, Call{
			Method:  http.MethodDelete,
			Path:    base,
			Params:  url.Values{"purge": {"1"}},
			What:    fmt.Sprintf("delete %s vmid %d on %s and its disks", v.Name, v.VMID, v.Node),
			Timeout: taskTimeout,
		})
		if !label.MatchString(v.Name) {
			// A name that is not a DNS label is not one talosvm gave, and
			// could carry a path separator.
			continue
		}
		path, header := filepath.Join(dir, SnippetName(cluster, v.Name)), SnippetHeader(cluster, v.Name)
		_, found, err := read(path, header)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		if found {
			calls = append(calls, Call{
				Method: RemoveFile,
				Path:   path,
				Header: header,
				What:   fmt.Sprintf("remove the network snippet of %s", v.Name),
			})
		}
	}
	if len(errs) > 0 {
		return nil, fmt.Errorf("refusing to destroy: %w", errors.Join(errs...))
	}
	return calls, nil
}

// RoleOf returns the role tag's value.
func RoleOf(r pve.Resource) string { return tagValue(r, roleTagPrefix) }

// PoolOf returns the pool tag's value, empty for the control plane.
func PoolOf(r pve.Resource) string { return tagValue(r, poolTagPrefix) }

func tagValue(r pve.Resource, prefix string) string {
	for _, t := range r.TagList() {
		if v, ok := strings.CutPrefix(t, prefix); ok {
			return v
		}
	}
	return ""
}
