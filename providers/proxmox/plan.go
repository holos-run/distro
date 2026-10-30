package proxmox

import (
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"net/url"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"go.holos.run/distro/providers/infra"
	"go.holos.run/distro/providers/proxmox/internal/pve"
)

// Tags. Proxmox tags are free-form labels on a VM; these are how the
// provider recognizes its own VMs and records their labels. They carry the
// name of talosvm, the program that first made them, since the VMs that
// exist already carry them. All but the first carry it as a prefix, so a tag
// someone types by hand for another purpose, such as cluster-x, is never
// taken for one of these.
const (
	// TagManaged marks every VM the provider created.
	TagManaged = "talosvm"

	tagPrefix        = "talosvm-"
	clusterTagPrefix = "talosvm-cluster-"
)

// ClusterTag is the tag that scopes a VM to one cluster, the group the
// contract names.
func ClusterTag(cluster string) string { return clusterTagPrefix + cluster }

// LabelTag is the tag that records one of a VM's labels, such as
// talosvm-role-worker for the label role=worker.
func LabelTag(l infra.Label) string { return tagPrefix + l.Key + "-" + l.Value }

// labelKey is a label's key: it goes between two hyphens in a tag, so it
// has none itself, and cluster is the cluster tag's.
var labelKey = regexp.MustCompile(`^[a-z0-9]+$`)

// Tags returns the tags of a VM of cluster with labels, in a stable order.
func Tags(cluster string, labels []infra.Label) []string {
	tags := []string{TagManaged, ClusterTag(cluster)}
	for _, l := range labels {
		tags = append(tags, LabelTag(l))
	}
	return tags
}

// Labels reads a VM's labels back from its tags, in the order Proxmox keeps
// them, which is sorted, not the order create gave them in.
func Labels(r pve.Resource) []infra.Label {
	var out []infra.Label
	for _, t := range r.TagList() {
		rest, ok := strings.CutPrefix(t, tagPrefix)
		if !ok || strings.HasPrefix(t, clusterTagPrefix) {
			continue
		}
		if k, v, ok := strings.Cut(rest, "-"); ok && v != "" {
			out = append(out, infra.Label{Key: k, Value: v})
		}
	}
	return out
}

// vmID is a VM's ID as the contract reports it.
func vmID(vmid int) infra.ID { return infra.ID{Kind: "vmid", Value: strconv.Itoa(vmid)} }

// checkSpecs refuses specs the provider cannot turn into Proxmox calls
// safely. The Kubernetes layer validates its config first, so this is the
// provider's own guard on what ends up in a VM name, a tag, a property
// string or a file name.
func checkSpecs(cluster string, specs []infra.VMSpec) error {
	var errs []error
	add := func(format string, a ...any) { errs = append(errs, fmt.Errorf(format, a...)) }
	if !label.MatchString(cluster) || len(cluster) > 30 {
		add("cluster %q: want a lowercase DNS label of at most 30 characters", cluster)
	}
	seen := map[string]bool{}
	for _, s := range specs {
		switch {
		case !label.MatchString(s.Name) || len(s.Name) > 63:
			add("VM name %q: want a lowercase DNS label", s.Name)
		case seen[s.Name]:
			add("VM %s is asked for twice", s.Name)
		}
		seen[s.Name] = true
		for _, l := range s.Labels {
			if !labelKey.MatchString(l.Key) || l.Key == "cluster" || !label.MatchString(l.Value) {
				add("VM %s: label %s=%s: want a key of lowercase letters and digits, not cluster, and a DNS label value", s.Name, l.Key, l.Value)
			}
		}
		if !plainName(s.Network) {
			add("VM %s: network %q: want a plain name", s.Name, s.Network)
		}
		if !plainName(s.Image.Name) || strings.Contains(s.Image.Name, "/") || s.Image.URL == "" {
			add("VM %s: image %q from %q: want a plain file name and a URL", s.Name, s.Image.Name, s.Image.URL)
		}
		if len(s.Disks) != 1 || s.Disks[0].SizeGiB < 1 {
			add("VM %s: want exactly one disk, the system disk, of at least 1 GiB", s.Name)
		}
		if err := CheckNodeAddress(s.Address); err != nil {
			add("VM %s: %w", s.Name, err)
		}
	}
	return errors.Join(errs...)
}

// place gives each spec its node. Placement is round robin over the spec's
// zones, or the node list, continuing one sequence across specs, so a single
// control plane and its workers start on different hosts and three workers
// on three hosts land one per host after it. Placement depends only on the
// specs and the node list, so a VM removed by hand comes back on the same
// node when create runs again.
func place(specs []infra.VMSpec, nodes []string) ([]string, error) {
	if len(nodes) == 0 {
		return nil, errors.New("no Proxmox nodes to place VMs on")
	}
	out := make([]string, len(specs))
	for i, s := range specs {
		list := nodes
		if len(s.Zones) > 0 {
			list = s.Zones
		}
		out[i] = list[i%len(list)]
	}
	return out, nil
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
//   - agent enabled, which only works because the image carries the
//     qemu-guest-agent extension; serial0 a socket, for a console that
//     survives a hung display, as on the garage's Talos templates.
//   - the ISO on ide0 and the cloud-init drive on ide2, where the garage's
//     other VMs keep it. citype nocloud matches the nocloud ISO, and
//     cicustom points the drive's network-config at the VM's snippet, which
//     gives the /32 address and the on-link route to the anycast gateway
//     that Proxmox's own ipconfig0 cannot express.
//   - net0 virtio on the vnet with the MAC the snippet matches and mtu=1,
//     which makes the NIC take the bridge's MTU (8950 on k8s) instead of
//     1500; the snippet sets the same MTU inside the guest.
//   - boot from the system disk first, then the ISO. The disk is empty until
//     talosctl installs Talos, so the first boot falls through to the ISO,
//     and every boot after the install comes from the disk.
//   - onboot 1, so the VM comes up after a host reboot. It is not started
//     by the create call: Proxmox only warns when start-after-create fails
//     and the task still ends well, so the plan starts it with a call of its
//     own, whose failure is an error.
func CreateParams(c Config, cluster string, s infra.VMSpec, mac string, vmid int) url.Values {
	disk := fmt.Sprintf("%s:%d,discard=on", c.DiskStorage, s.Disks[0].SizeGiB)
	if c.DiskSSD {
		disk += ",ssd=1"
	}
	return url.Values{
		"vmid":        {strconv.Itoa(vmid)},
		"name":        {s.Name},
		"tags":        {strings.Join(Tags(cluster, s.Labels), ";")},
		"description": {s.Description},
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
		"ide0":        {isoVolID(c.ISOStorage, s.Image) + ",media=cdrom"},
		"ide2":        {c.DiskStorage + ":cloudinit"},
		"citype":      {"nocloud"},
		"cicustom":    {"network=" + SnippetVolume(c.SnippetStorage, SnippetName(cluster, s.Name))},
		"net0":        {"virtio=" + mac + ",bridge=" + s.Network + ",mtu=1"},
		"serial0":     {"socket"},
		"boot":        {"order=scsi0;ide0"},
		"agent":       {"enabled=1"},
		"onboot":      {"1"},
	}
}

// isoVolID is an image's volume ID in the ISO storage.
func isoVolID(storage string, img infra.Image) string { return storage + ":iso/" + img.Name }

// Owned reports whether a guest is one of the provider's VMs of the given
// cluster. Both tags are required: the managed tag alone would match another
// cluster's VMs, and a cluster tag alone could have been typed by hand on
// anything. Templates and containers are never owned.
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

// existingVM is a spec whose VM exists: specs[i] is it, as vm.
type existingVM struct {
	i  int
	vm pve.Resource
	// rewrite is set when the VM's snippet is missing and is written again.
	rewrite bool
}

// Reconcile matches specs against the cluster's guests by name. A spec whose
// name is free is to be created, and its index is in create. A spec whose
// name belongs to one of this cluster's VMs is in skip, whatever node it is
// on and whatever its size, since create never changes a VM it already made
// (resize changes its size). A spec whose name is taken by anything else is
// an error, and the whole run stops before any change, because creating a
// second VM with the same name would confuse every later step and taking
// over the existing one could destroy it later.
func Reconcile(specs []infra.VMSpec, rs []pve.Resource, cluster string) (create []int, skip []existingVM, err error) {
	byName := map[string][]pve.Resource{}
	for _, r := range rs {
		byName[r.Name] = append(byName[r.Name], r)
	}
	var conflicts []string
	for i, s := range specs {
		existing := byName[s.Name]
		switch {
		case len(existing) == 0:
			create = append(create, i)
		case len(existing) == 1 && Owned(existing[0], cluster):
			skip = append(skip, existingVM{i: i, vm: existing[0]})
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

// Call is one Proxmox API call that changes the cluster. Create, resize and
// destroy build their whole list of calls before sending any, so a dry run
// prints exactly what a real run sends.
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
	// Timeout bounds the task the call starts. A PUT starts none.
	Timeout time.Duration
}

// String prints the call as the API sees it: the method and full path, with
// a DELETE's parameters in the query string and a POST's or PUT's form fields
// one per line, sorted.
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

// DownloadCall fetches the image into the ISO storage through node.
func DownloadCall(c Config, node string, img infra.Image) Call {
	return Call{
		Method: http.MethodPost,
		Path:   "/nodes/" + url.PathEscape(node) + "/storage/" + url.PathEscape(c.ISOStorage) + "/download-url",
		Params: url.Values{
			"content":             {"iso"},
			"filename":            {img.Name},
			"url":                 {img.URL},
			"verify-certificates": {"1"},
		},
		What:    fmt.Sprintf("download %s into %s through %s", img.Name, c.ISOStorage, node),
		Timeout: downloadTimeout,
	}
}

// startCall starts a VM.
func startCall(node, vmid, name string) Call {
	return Call{
		Method:  http.MethodPost,
		Path:    "/nodes/" + url.PathEscape(node) + "/qemu/" + url.PathEscape(vmid) + "/status/start",
		Params:  url.Values{},
		What:    fmt.Sprintf("start %s vmid %s on %s", name, vmid, node),
		Timeout: taskTimeout,
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

// readFunc reads one of the provider's snippets: (content, found, error),
// with the error for a file that is there but is not a regular file starting
// with the given header. readOwnedSnippet in production.
type readFunc func(path, header string) (string, bool, error)

// createPlan is the provider's infra.Plan: everything create knows once it
// has read Proxmox. vms is specs as the VMs they are or will be; create
// holds the indexes of the specs to create, and existing the rest.
type createPlan struct {
	config   Config
	cluster  string
	specs    []infra.VMSpec
	vms      []infra.VM
	create   []int
	existing []existingVM
	guests   []pve.Resource
	dir      string
	read     readFunc
}

func (p *createPlan) VMs() []infra.VM { return slices.Clone(p.vms) }

// maxMACAttempts bounds the search for a free MAC; with three fresh bytes
// per attempt it is only reached if something is badly wrong.
const maxMACAttempts = 64

type holder struct {
	vmid int
	who  string
}

// allocate checks the plan against the cluster, given every guest's
// network, and gives each new VM its MAC. It refuses the whole run, before
// any change, on any problem:
//
//   - An existing VM's address never changes. If its snippet is there, the
//     address in it must be the one its spec asks for now; if not, create
//     refuses rather than move a cluster's node onto an address that may by
//     now be another cluster's. If the snippet is missing, it is written
//     again, after the same collision check a new VM gets, with the MAC on
//     the VM's net0.
//   - A new VM's address must be free, counting every guest and every VM
//     earlier in the same run, and its MAC is the first candidate no guest
//     and no earlier VM has.
func (p *createPlan) allocate(nets map[int]GuestNet) error {
	addrs := map[netip.Addr][]holder{}
	macs := map[string][]holder{}
	for _, g := range p.guests {
		h := holder{g.VMID, fmt.Sprintf("vmid %d %s on %s", g.VMID, g.Name, g.Node)}
		for _, a := range nets[g.VMID].Addresses {
			addrs[a] = append(addrs[a], h)
		}
		for _, m := range nets[g.VMID].MACs {
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
	var errs []error

	for k := range p.existing {
		a := &p.existing[k]
		s, vm := p.specs[a.i], a.vm
		path, header := p.snippet(s.Name)
		have, found, err := p.read(path, header)
		mac := nets[vm.VMID].Net0MAC
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
			if mac == "" {
				errs = append(errs, fmt.Errorf("VM %s has no MAC on net0 to write its missing snippet for", s.Name))
				break
			}
			if who := others(addrs[s.Address], vm.VMID); len(who) > 0 {
				errs = append(errs, fmt.Errorf("VM %s: its snippet is missing and its address %s is now used by %s", s.Name, s.Address, strings.Join(who, ", ")))
				break
			}
			a.rewrite = true
		}
		addrs[s.Address] = append(addrs[s.Address], holder{vm.VMID, s.Name})
		p.vms[a.i].NIC.MAC = mac
	}

	for k, i := range p.create {
		s := p.specs[i]
		// A new VM has no VMID until create; a negative stand-in tells it
		// from every guest and every other new VM.
		vmid := -1 - k
		if who := others(addrs[s.Address], vmid); len(who) > 0 {
			errs = append(errs, fmt.Errorf("%s: address %s is already used by %s", s.Name, s.Address, strings.Join(who, ", ")))
		}
		addrs[s.Address] = append(addrs[s.Address], holder{vmid, s.Name + " (created by this run)"})
		mac := ""
		for n := range maxMACAttempts {
			if m := MACFor(p.cluster, s.Name, n); len(macs[m]) == 0 {
				mac = m
				break
			}
		}
		if mac == "" {
			errs = append(errs, fmt.Errorf("%s: no free MAC in %d attempts", s.Name, maxMACAttempts))
			continue
		}
		macs[mac] = append(macs[mac], holder{vmid, s.Name + " (created by this run)"})
		p.vms[i].NIC.MAC = mac
	}
	if len(errs) > 0 {
		return fmt.Errorf("refusing to create: %w", errors.Join(errs...))
	}
	return nil
}

func (p *createPlan) snippet(vm string) (path, header string) {
	return filepath.Join(p.dir, SnippetName(p.cluster, vm)), SnippetHeader(p.cluster, vm)
}

// Calls returns the plan's calls, which follow the ISO downloads, given
// each VM's config and the new VMs' VMIDs:
//
//   - An existing VM whose snippet is missing has it written again. An
//     existing VM that is stopped is started.
//   - A new VM gets its snippet, then a create call, then a start call.
//   - A snippet file is only ever overwritten if it is the provider's for
//     the same cluster and VM.
func (p *createPlan) Calls(configs map[string]string, vmids []int) ([]Call, error) {
	var errs []error
	var calls []Call
	config := func(name string) (string, bool) {
		c, ok := configs[name]
		if !ok {
			errs = append(errs, fmt.Errorf("no config for VM %s", name))
		}
		return c, ok
	}

	for _, a := range p.existing {
		s, vm := p.specs[a.i], a.vm
		if a.rewrite {
			if body, ok := config(s.Name); ok {
				path, header := p.snippet(s.Name)
				mac := p.vms[a.i].NIC.MAC
				calls = append(calls, Call{
					Method:  WriteFile,
					Path:    path,
					Content: snippetContent(p.cluster, s.Name, body),
					Header:  header,
					What:    fmt.Sprintf("write the missing network snippet of %s, %s/32 on MAC %s", s.Name, s.Address, mac),
				})
			}
		}
		if vm.Status == "stopped" {
			calls = append(calls, startCall(vm.Node, strconv.Itoa(vm.VMID), s.Name))
		}
	}

	for k, i := range p.create {
		s, vm := p.specs[i], p.vms[i]
		vmid := vmids[k]
		body, ok := config(s.Name)
		if !ok {
			continue
		}
		path, header := p.snippet(s.Name)
		content := snippetContent(p.cluster, s.Name, body)
		have, found, err := p.read(path, header)
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
				What:    fmt.Sprintf("write the network snippet of %s, %s/32 on MAC %s", s.Name, s.Address, vm.NIC.MAC),
			})
		}
		calls = append(calls, Call{
			Method:  http.MethodPost,
			Path:    "/nodes/" + url.PathEscape(vm.Zone) + "/qemu",
			Params:  CreateParams(p.config, p.cluster, s, vm.NIC.MAC, vmid),
			What:    fmt.Sprintf("create %s vmid %d on %s at %s (%d cores, %d MiB, %d GiB)", s.Name, vmid, vm.Zone, s.Address, s.Cores, s.MemoryMiB, s.Disks[0].SizeGiB),
			Timeout: taskTimeout,
		}, startCall(vm.Zone, strconv.Itoa(vmid), s.Name))
	}
	if len(errs) > 0 {
		return nil, fmt.Errorf("refusing to create: %w", errors.Join(errs...))
	}
	return calls, nil
}

// DestroyCalls is the calls that remove the cluster's VMs: a hard stop for
// each VM that is not stopped, then a delete with purge, which also drops the
// VM from backup jobs, replication and HA, then the removal of the VM's
// network snippet when it is there. The snippet removed is the one file
// SnippetName gives for the VM, and only if read finds it is the provider's
// for that cluster and VM; anything else at that path stops the plan.
// Nothing is globbed, so another tenant's snippet in the same directory is
// never touched. The delete removes the disks the VM's config references.
// destroy-unreferenced-disks is not sent: it scans every storage for disks
// named after the VMID, and a stale disk on some other tenant's storage that
// happens to carry the same number is not this provider's to delete. Only
// Owned VMs are ever in the list.
func DestroyCalls(guests []pve.Resource, cluster, dir string, read readFunc) ([]Call, error) {
	var calls []Call
	var errs []error
	for _, v := range OwnedVMs(guests, cluster) {
		base := "/nodes/" + url.PathEscape(v.Node) + "/qemu/" + strconv.Itoa(v.VMID)
		if v.Status != "stopped" {
			// A hard stop, not a shutdown: the VM is about to be deleted,
			// and its guest has nothing to flush that matters.
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
			// A name that is not a DNS label is not one the provider gave,
			// and could carry a path separator.
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

// powerCycleCalls are the two Proxmox calls of a power cycle. It is a
// shutdown rather than a hard stop: the guest, through its agent, stops its
// services and unmounts its volumes first, so a Talos node's pods end as
// they do on a reboot and no Ceph volume is cut off mid-write. forceStop
// makes Proxmox stop the VM hard if the guest has not shut down within the
// timeout, so the VM always ends up stopped, and then started.
func powerCycleCalls(name, vmid, node string, timeout time.Duration) (shutdown, start Call) {
	shutdown = Call{
		Method:  http.MethodPost,
		Path:    "/nodes/" + url.PathEscape(node) + "/qemu/" + url.PathEscape(vmid) + "/status/shutdown",
		Params:  url.Values{"timeout": {strconv.Itoa(int(timeout / time.Second))}, "forceStop": {"1"}},
		What:    fmt.Sprintf("shut down %s vmid %s on %s", name, vmid, node),
		Timeout: timeout + time.Minute,
	}
	return shutdown, startCall(node, vmid, name)
}

// resizeCall sets a VM's cores and memory, sending only what differs from
// what its config holds for its next start, and never balloon, so
// ballooning stays off as create left it, nor the disk, which Proxmox can
// grow but not shrink. ok is false when nothing differs. r is the VM as
// Proxmox lists it now, which names its node and VMID.
func resizeCall(r pve.Resource, z infra.Resize) (c Call, ok bool) {
	vm, size := z.VM, z.Size
	params := url.Values{}
	if vm.Sizing.Next.Cores != size.Cores {
		params.Set("cores", strconv.Itoa(size.Cores))
	}
	if vm.Sizing.Next.MemoryMiB != size.MemoryMiB {
		params.Set("memory", strconv.Itoa(size.MemoryMiB))
	}
	if len(params) == 0 {
		return Call{}, false
	}
	return Call{
		Method: http.MethodPut,
		Path:   "/nodes/" + url.PathEscape(r.Node) + "/qemu/" + strconv.Itoa(r.VMID) + "/config",
		Params: params,
		What:   fmt.Sprintf("resize %s vmid %d on %s to %d cores and %d MiB", r.Name, r.VMID, r.Node, size.Cores, size.MemoryMiB),
	}, true
}
