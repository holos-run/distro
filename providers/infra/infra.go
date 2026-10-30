// Package infra holds the contracts of the infrastructure layer: what a
// provider such as Proxmox, GCE or EC2 must offer the Kubernetes layer above
// it, and nothing more. There are three, compute, block and bucket, and they
// are Go interfaces over plain types, so the layer above is written once and
// runs on any provider that implements them.
//
// Nothing here names a hypervisor or a Kubernetes concept. A provider assigns
// addresses, MACs and placement, keeps track of which VMs are its own, and
// checks its own credentials; the layer above names VMs, groups them, labels
// them and hands each one an opaque config. A Kubernetes node name, a
// StorageClass or a node label never crosses into a provider.
//
// Compute has one implementation, providers/proxmox. Block and Bucket are
// contracts only: on Proxmox, block storage is the Ceph cluster the hosts
// already run, which ceph-csi uses directly, and the bucket is RustFS inside
// the cluster.
package infra

import (
	"context"
	"fmt"
	"net/netip"
	"time"
)

// Compute creates, lists, resizes, power-cycles and destroys VMs.
//
// Every VM belongs to a group, such as a cluster, and a provider acts only on
// the VMs it made for that group: List, Resize, PowerCycle and Destroy never
// touch a VM another group or another tenant of the same hosts owns, whatever
// its name, and Resize and PowerCycle refuse such a VM even when a caller
// hands it in.
//
// Plan, then Create, make the VMs a group asks for. They are two calls
// because each VM's config depends on what the provider assigns it: the
// guest's network config names the address and MAC, which Plan works out
// before anything changes. A rerun never renumbers or recreates a VM: one
// that exists keeps its address, MAC and placement, and is only started if it
// is stopped.
//
// Create, Resize and Destroy log every call they make, in full, before making
// any, so a provider made for a dry run reads what it needs, logs the same
// calls, and makes none. PowerCycle is one step of a longer sequence its
// caller logs, so it logs nothing, and PowerCycleCalls says what it would
// send; made for a dry run, it checks the VM and sends nothing.
type Compute interface {
	// String names the provider, such as Proxmox, for messages.
	fmt.Stringer

	// Check fails unless the provider's credentials allow everything this
	// contract does. Plan and Destroy check first themselves; a caller that
	// reads before it changes anything, as a resize does, calls it first, so
	// a missing privilege stops it before any change.
	Check(ctx context.Context) error

	// CheckAddress refuses an address the network does not let a VM have,
	// such as its gateway or a reserved range. It reads nothing, so a
	// caller can check its addresses before it has credentials.
	CheckAddress(a netip.Addr) error

	// Plan reads the group's VMs and works out what Create would do with
	// specs, in order, and changes nothing. It refuses when a spec's name
	// is taken by a VM that is not the group's, when a spec's address is in
	// use or not allowed, or when a VM that exists has another address than
	// its spec asks for.
	Plan(ctx context.Context, group string, specs []VMSpec) (Plan, error)

	// Create carries out plan: it starts the group's VMs that exist and are
	// stopped, and makes and starts the rest. configs holds each VM's
	// config by name, which the provider attaches to the VM as a
	// cloud-init style drive without parsing it: to each VM it makes, and
	// to a VM that exists only when it has lost its config.
	Create(ctx context.Context, plan Plan, configs map[string]string) error

	// List returns the group's VMs, by name.
	List(ctx context.Context, group string) ([]VM, error)

	// Resize gives each of the group's VMs its new cores and memory. On a
	// provider without CPU and memory hotplug a running VM keeps its old
	// size until it is stopped and started, as Sizing reports.
	Resize(ctx context.Context, group string, resizes []Resize) error

	// PowerCycle shuts one of the group's VMs down and starts it again,
	// which is what applies a resize. The guest has timeout to shut down
	// cleanly before the provider stops it hard, so the VM always ends up
	// stopped, and then started.
	PowerCycle(ctx context.Context, group string, vm VM, timeout time.Duration) error

	// PowerCycleCalls returns the calls PowerCycle makes, each as the
	// provider prints it, so a caller can log them first, or instead in a
	// dry run.
	PowerCycleCalls(vm VM, timeout time.Duration) []string

	// Destroy stops and deletes the group's VMs with their disks and
	// configs.
	Destroy(ctx context.Context, group string) error
}

// A Plan is what Create will do, worked out by Plan before anything
// changes. Only the provider that made it can carry it out.
type Plan interface {
	// VMs is each spec, in order, as the VM it is or will be: a VM that
	// exists as it is, and a new one with the address, MAC and placement
	// Create will give it, and no ID yet.
	VMs() []VM
}

// VMSpec is one VM a caller asks for.
type VMSpec struct {
	// Name is unique within the group and is a DNS label.
	Name string
	// Labels are recorded on the VM and reported back by List, whose order
	// is the provider's: Proxmox sorts a VM's tags. Keys are lowercase
	// letters and digits; VM.Label looks one up.
	Labels []Label
	// Description is free text the provider keeps with the VM.
	Description string
	// Image is what the VM boots.
	Image Image
	Size
	// Disks are the VM's disks, the system disk first.
	Disks []Disk
	// Network names the network the VM's one NIC attaches to.
	Network string
	// Address is the address the VM asks for on that network. The provider
	// gives it if the network allows it and no other VM has it, and keeps
	// giving it to the VM for its lifetime.
	Address netip.Addr
	// Zones, when set, are the zones the VM may be placed in. Empty means
	// any the provider spreads VMs across.
	Zones []string
}

// Label is one key and value recorded on a VM.
type Label struct {
	Key, Value string
}

// Image is a boot image. A provider that does not have it yet fetches it.
type Image struct {
	// Name is the image's name in the provider's storage. An image already
	// there by this name is taken to be this one, so the name must change
	// when the image does.
	Name string
	// URL is where the provider fetches it from.
	URL string
}

// Size is a VM's processors and memory.
type Size struct {
	Cores     int
	MemoryMiB int
}

// Disk is one disk of a VM.
type Disk struct {
	SizeGiB int
}

// VM is one VM as the provider reports it.
type VM struct {
	Name string
	// ID is the provider's own identifier, empty for a VM a Plan has not
	// created yet.
	ID     ID
	Labels []Label
	// Region and Zone are where the VM runs: on Proxmox, the cluster and
	// the host node.
	Region, Zone string
	// Status is the VM's power state, such as running or stopped, empty
	// for a VM that does not exist yet.
	Status string
	NIC    NIC
	// Size is what the VM runs with, as the provider's inventory reports
	// it. It can lag a power cycle by a few seconds; Sizing is read from
	// the VM's own configuration.
	Size Size
	// Sizing is what the VM's configuration holds now and for its next
	// start. When it could not be read SizingErr says why and Sizing is
	// zero.
	Sizing    Sizing
	SizingErr error
}

// Label returns the value of the VM's label key, or "".
func (v VM) Label(key string) string {
	for _, l := range v.Labels {
		if l.Key == key {
			return l.Value
		}
	}
	return ""
}

// ID is a provider's identifier for a VM: Kind is what the provider calls
// that identifier, such as vmid on Proxmox, and Value is the identifier.
type ID struct {
	Kind, Value string
}

// String prints the ID as the provider's own tools do, such as vmid 104.
func (id ID) String() string {
	if id.Value == "" {
		return ""
	}
	return id.Kind + " " + id.Value
}

// NIC is a VM's one network interface, with what its guest needs to set it
// up. A network without DHCP leaves the address, route and resolvers to the
// guest, which takes them from the VM's config, so the provider reports them
// for the caller to put there.
type NIC struct {
	Network string
	MAC     string
	// Address is the VM's address with the prefix length the guest sets,
	// such as 10.20.0.50/32. It is invalid when the provider cannot tell.
	Address netip.Prefix
	// Subnet is the network's subnet, which holds every VM address on it.
	Subnet netip.Prefix
	// Gateway is the default route's next hop. Outside a /32 it is on-link.
	Gateway       netip.Addr
	MTU           int
	Nameservers   []netip.Addr
	SearchDomains []string
}

// Sizing is a VM's cores and memory as its configuration holds them: Now,
// what it runs with, and Next, what it runs with after its next start. They
// differ while a resize waits for a power cycle.
type Sizing struct {
	Now, Next Size
}

// Pending reports whether a new size waits for the VM's next start.
func (s Sizing) Pending() bool { return s.Now != s.Next }

// Resize is one VM's new size, for Compute.Resize. VM is as List reported
// it; the provider reads it again before it changes anything.
type Resize struct {
	VM   VM
	Size Size
}

// Block is block storage in the RBD model: volumes in a named pool, each of
// which outlives the pod or VM that mounts it and is replicated below the
// node, so losing a node loses no data. A storage class provisions, attaches
// and deletes them, the calls of a CSI controller.
//
// On Proxmox this is the Ceph cluster the hosts already run, whose pool
// ceph-csi uses directly; nothing in this repository implements it yet.
type Block interface {
	// CreateVolume makes a volume of sizeGiB in pool.
	CreateVolume(ctx context.Context, pool, name string, sizeGiB int) error
	// AttachVolume makes a volume a block device of vm.
	AttachVolume(ctx context.Context, pool, name string, vm VM) error
	// DetachVolume takes it away again.
	DetachVolume(ctx context.Context, pool, name string, vm VM) error
	// DeleteVolume deletes a detached volume and its data.
	DeleteVolume(ctx context.Context, pool, name string) error
}

// Bucket is S3-compatible object storage.
//
// Where its Proxmox implementation runs is not decided: the base's one object
// store is RustFS inside the cluster, on Ceph RBD, and it would have to run
// outside the cluster to be the infrastructure layer's. Nothing in this
// repository implements it yet.
type Bucket interface {
	// CreateBucket makes a bucket.
	CreateBucket(ctx context.Context, name string) error
	// CreateCredential makes a credential that can read and write one
	// bucket and nothing else.
	CreateCredential(ctx context.Context, bucket string) (Credential, error)
	// Endpoint reports where the buckets are served.
	Endpoint(ctx context.Context) (Endpoint, error)
}

// Endpoint is where an S3-compatible API is served.
type Endpoint struct {
	URL    string
	Region string
	// PathStyle is set when buckets are addressed as URL/bucket rather than
	// as bucket.host.
	PathStyle bool
}

// Credential is an S3 access key.
type Credential struct {
	AccessKeyID     string
	SecretAccessKey string
}
