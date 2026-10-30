package talos

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"go.holos.run/distro/providers/infra"
)

// Restart modes.
const (
	// ModeReboot restarts Talos inside the guest with talosctl reboot. It is
	// enough for any change inside the guest, such as containerd reading a
	// new trust store.
	ModeReboot = "reboot"
	// ModePowerCycle shuts the VM down and starts it again through compute,
	// which on Proxmox starts a new QEMU process. A changed VM config, such
	// as new memory, applies only this way: a guest reboot keeps the running
	// process and the hardware it was started with.
	ModePowerCycle = "power-cycle"
)

// Restart defaults.
const (
	// DefaultRestartTimeout bounds one node, from cordon to its workloads
	// being available again. A worker of the treasury cluster takes about
	// three minutes.
	DefaultRestartTimeout = 15 * time.Minute
	// DefaultShutdownTimeout is how long power-cycle lets the guest shut
	// down cleanly before compute stops it hard.
	DefaultShutdownTimeout = 5 * time.Minute

	restartPoll = 5 * time.Second
	// kubectlTimeout bounds every kubectl call, so a poll against an API
	// server that is down, as it is while the only control plane restarts,
	// fails and is tried again instead of hanging.
	kubectlTimeout = "--request-timeout=30s"
	// controlPlaneLabel marks a control plane node. The garage's control
	// planes are kept off the pod network (Q33), so they read NotReady for
	// good, and restart accepts that of them alone.
	controlPlaneLabel = "node-role.kubernetes.io/control-plane"
	// cordonAnnotation marks a node restart cordoned, set before the cordon
	// and removed after the uncordon. A node cordoned with it is one a
	// failed run left cordoned, which a rerun uncordons; without it the
	// cordon is someone else's, which restart leaves as it is.
	cordonAnnotation = "talosvm.holos.run/cordoned"
)

// DefaultRequiredDaemonSets are the node-local pods a worker is not back
// without: the Cilium agent, without which it has no pod network, and
// ztunnel, without which the mesh's traffic to and from its pods fails.
var DefaultRequiredDaemonSets = []string{"kube-system/cilium", "istio-system/ztunnel"}

// Tools runs the command-line programs restart drives. ExecTools runs the
// real ones; the tests use a fake.
type Tools interface {
	Kubectl(ctx context.Context, args ...string) ([]byte, error)
	Talosctl(ctx context.Context, args ...string) ([]byte, error)
}

// ExecTools runs kubectl and talosctl as child processes. They inherit the
// environment, so they act with the kubeconfig and talosconfig KUBECONFIG and
// TALOSCONFIG name, as they would at the shell, and restart needs no
// Kubernetes or Talos client library. The paths are the programs as
// exec.LookPath found them.
type ExecTools struct {
	KubectlPath  string
	TalosctlPath string
}

func (t ExecTools) Kubectl(ctx context.Context, args ...string) ([]byte, error) {
	return execTool(ctx, t.KubectlPath, args)
}

func (t ExecTools) Talosctl(ctx context.Context, args ...string) ([]byte, error) {
	return execTool(ctx, t.TalosctlPath, args)
}

func execTool(ctx context.Context, bin string, args []string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, bin, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		return nil, &toolError{cmd: filepath.Base(bin) + " " + strings.Join(args, " "), err: err, stderr: stderr.String()}
	}
	return stdout.Bytes(), nil
}

// toolError is a kubectl or talosctl run that failed, with what it wrote to
// stderr.
type toolError struct {
	cmd    string
	err    error
	stderr string
}

func (e *toolError) Error() string {
	msg := strings.TrimSpace(e.stderr)
	if len(msg) > 1000 {
		msg = "..." + msg[len(msg)-1000:]
	}
	return fmt.Sprintf("%s: %v: %s", e.cmd, e.err, msg)
}

func (e *toolError) Unwrap() error { return e.err }

// klogPrefix is the header klog puts on each line kubectl logs, such as
// "E1028 10:15:01.123456   12345 memcache.go:265] ".
var klogPrefix = regexp.MustCompile(`^[IWEF]\d{4} \d{2}:\d{2}:\d{2}\.\d+\s+\d+ [^\s\]]+:\d+\] `)

// shortError is an error as one line for a wait's status: for a tool that
// failed, the last line it wrote to stderr without klog's header, which
// stays the same from one failed poll to the next while the API server is
// down, so the status is printed once rather than at every poll.
func shortError(err error) string {
	var te *toolError
	if !errors.As(err, &te) {
		return err.Error()
	}
	lines := strings.Split(strings.TrimSpace(te.stderr), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if line := strings.TrimSpace(klogPrefix.ReplaceAllString(strings.TrimSpace(lines[i]), "")); line != "" {
			return line
		}
	}
	return te.cmd + ": " + te.err.Error()
}

// RestartOptions are restart's settings, which the command line's flags fill.
type RestartOptions struct {
	// Mode is ModeReboot or ModePowerCycle.
	Mode string
	// Nodes names the VMs to restart, in that order. Empty means every
	// worker of the cluster, by name. The control plane is restarted only
	// when it is named here.
	Nodes []string
	// Timeout bounds one node, from cordon to its workloads being
	// available again.
	Timeout time.Duration
	// ShutdownTimeout is how long power-cycle lets the guest shut down
	// before compute stops it hard.
	ShutdownTimeout time.Duration
	// RequireDaemonSets are DaemonSets, as namespace/name, a worker must
	// have a Ready pod of before its restart and again before it is
	// uncordoned.
	RequireDaemonSets []string
	Tools             Tools
	// PollInterval is how often the waits look again. Zero means five
	// seconds.
	PollInterval time.Duration
}

// Validate checks the options that need no cluster to check.
func (o RestartOptions) Validate() error {
	var errs []error
	if o.Mode != ModeReboot && o.Mode != ModePowerCycle {
		errs = append(errs, fmt.Errorf("mode %q: want %s or %s", o.Mode, ModeReboot, ModePowerCycle))
	}
	if o.Timeout <= 0 {
		errs = append(errs, fmt.Errorf("timeout %v: want a positive duration", o.Timeout))
	}
	if o.Mode == ModePowerCycle && (o.ShutdownTimeout < time.Second || o.ShutdownTimeout >= o.Timeout) {
		errs = append(errs, fmt.Errorf("shutdown timeout %v: want at least a second and less than the timeout %v", o.ShutdownTimeout, o.Timeout))
	}
	seen := map[string]bool{}
	for _, n := range o.Nodes {
		switch {
		case !label.MatchString(n):
			errs = append(errs, fmt.Errorf("node %q is not a VM name", n))
		case seen[n]:
			errs = append(errs, fmt.Errorf("node %s is named twice", n))
		}
		seen[n] = true
	}
	for _, d := range o.RequireDaemonSets {
		ns, name, ok := strings.Cut(d, "/")
		if !ok || ns == "" || name == "" || strings.Contains(name, "/") {
			errs = append(errs, fmt.Errorf("required DaemonSet %q: want namespace/name", d))
		}
	}
	return errors.Join(errs...)
}

// The parts of Kubernetes objects restart reads, as kubectl -o json prints
// them. The tests encode the same types for their fake kubectl.
type (
	objectMeta struct {
		Name              string            `json:"name"`
		Namespace         string            `json:"namespace,omitempty"`
		UID               string            `json:"uid,omitempty"`
		Generation        int64             `json:"generation,omitempty"`
		Labels            map[string]string `json:"labels,omitempty"`
		Annotations       map[string]string `json:"annotations,omitempty"`
		DeletionTimestamp string            `json:"deletionTimestamp,omitempty"`
		OwnerReferences   []ownerReference  `json:"ownerReferences,omitempty"`
	}
	ownerReference struct {
		Kind       string `json:"kind"`
		Name       string `json:"name"`
		Controller bool   `json:"controller,omitempty"`
	}
	condition struct {
		Type   string `json:"type"`
		Status string `json:"status"`
		Reason string `json:"reason,omitempty"`
	}

	kubeNode struct {
		Metadata objectMeta `json:"metadata"`
		Spec     nodeSpec   `json:"spec"`
		Status   nodeStatus `json:"status"`
	}
	nodeSpec struct {
		Unschedulable bool `json:"unschedulable,omitempty"`
	}
	nodeStatus struct {
		Conditions []condition    `json:"conditions,omitempty"`
		Addresses  []nodeAddress  `json:"addresses,omitempty"`
		NodeInfo   nodeSystemInfo `json:"nodeInfo"`
	}
	nodeAddress struct {
		Type    string `json:"type"`
		Address string `json:"address"`
	}
	nodeSystemInfo struct {
		BootID string `json:"bootID"`
	}

	kubePod struct {
		Metadata objectMeta `json:"metadata"`
		Spec     podSpec    `json:"spec"`
		Status   podStatus  `json:"status"`
	}
	podSpec struct {
		NodeName string `json:"nodeName,omitempty"`
	}
	podStatus struct {
		Phase                 string            `json:"phase,omitempty"`
		Reason                string            `json:"reason,omitempty"`
		Message               string            `json:"message,omitempty"`
		Conditions            []condition       `json:"conditions,omitempty"`
		InitContainerStatuses []containerStatus `json:"initContainerStatuses,omitempty"`
		ContainerStatuses     []containerStatus `json:"containerStatuses,omitempty"`
	}
	containerStatus struct {
		Name        string         `json:"name"`
		ContainerID string         `json:"containerID,omitempty"`
		State       containerState `json:"state"`
	}
	containerState struct {
		Terminated *containerTerminated `json:"terminated,omitempty"`
	}
	containerTerminated struct {
		Reason string `json:"reason,omitempty"`
	}

	// kubeObject is anything only the metadata of which matters, such as
	// a ReplicaSet.
	kubeObject struct {
		Metadata objectMeta `json:"metadata"`
	}

	// kubeWorkload is a Deployment or a StatefulSet.
	kubeWorkload struct {
		Kind     string         `json:"kind"`
		Metadata objectMeta     `json:"metadata"`
		Spec     workloadSpec   `json:"spec"`
		Status   workloadStatus `json:"status"`
	}
	workloadSpec struct {
		Replicas *int32 `json:"replicas,omitempty"`
	}
	workloadStatus struct {
		ObservedGeneration int64 `json:"observedGeneration,omitempty"`
		ReadyReplicas      int32 `json:"readyReplicas,omitempty"`
		AvailableReplicas  int32 `json:"availableReplicas,omitempty"`
	}

	kubeList[T any] struct {
		Items []T `json:"items"`
	}
)

func hasCondition(cs []condition, typ string) bool {
	return slices.ContainsFunc(cs, func(c condition) bool { return c.Type == typ && c.Status == "True" })
}

func nodeReady(n kubeNode) bool { return hasCondition(n.Status.Conditions, "Ready") }

func isControlPlane(n kubeNode) bool {
	_, ok := n.Metadata.Labels[controlPlaneLabel]
	return ok
}

// controller returns the owner reference that controls an object.
func controller(m objectMeta) (ownerReference, bool) {
	for _, o := range m.OwnerReferences {
		if o.Controller {
			return o, true
		}
	}
	return ownerReference{}, false
}

func terminal(p kubePod) bool { return p.Status.Phase == "Failed" || p.Status.Phase == "Succeeded" }

func podReady(p kubePod) bool {
	return p.Status.Phase == "Running" && p.Metadata.DeletionTimestamp == "" && hasCondition(p.Status.Conditions, "Ready")
}

// key is namespace/name.
func key(m objectMeta) string { return m.Namespace + "/" + m.Name }

// workloadAvailable reports whether a Deployment or StatefulSet has all the
// replicas it asks for, and if not, how many it has.
func workloadAvailable(w kubeWorkload) (bool, string) {
	want := int32(1)
	if w.Spec.Replicas != nil {
		want = *w.Spec.Replicas
	}
	have := w.Status.ReadyReplicas
	if w.Kind == "Deployment" {
		have = w.Status.AvailableReplicas
	}
	if w.Status.ObservedGeneration < w.Metadata.Generation {
		return false, "a change not yet rolled out"
	}
	return have >= want, fmt.Sprintf("%d/%d available", have, want)
}

// orphanReasons are the pod failures a node restart leaves behind, which
// cleanup deletes:
//
//   - Terminated, with the message shutdownMessage or a DisruptionTarget
//     condition of reason TerminationByKubelet, is a pod the kubelet's node
//     shutdown manager killed as the node went down;
//   - NodeShutdown is a pod the kubelet refused to admit while its node shut
//     down. The ReplicaSet keeps sending replacements to a node that still
//     reads Ready, which is how cilium-operator left a hundred of them before
//     restart cordoned first;
//   - Evicted is the kubelet's eviction under node pressure;
//   - ContainerStatusUnknown is a container the kubelet could not find again
//     after the restart.
var orphanReasons = []string{"Terminated", "NodeShutdown", "Evicted", "ContainerStatusUnknown"}

// shutdownMessage is the message the kubelet's node shutdown manager puts on
// each pod it kills.
const shutdownMessage = "Pod was terminated in response to imminent node shutdown."

// orphanReason returns why cleanup deletes a pod on node, or "" to keep it.
// Only Failed pods are candidates, so a pod that is still running is never
// deleted, whatever its containers once reported; nor is a Failed pod with
// another reason, such as a Job's pod that exited with an Error, or one
// Terminated for something other than the node's shutdown, whose record
// someone may want.
func orphanReason(p kubePod, node string) string {
	if p.Spec.NodeName != node || p.Status.Phase != "Failed" {
		return ""
	}
	switch p.Status.Reason {
	case "NodeShutdown", "Evicted":
		return p.Status.Reason
	case "Terminated":
		if strings.TrimSpace(p.Status.Message) == shutdownMessage || slices.ContainsFunc(p.Status.Conditions, func(c condition) bool {
			return c.Type == "DisruptionTarget" && c.Status == "True" && c.Reason == "TerminationByKubelet"
		}) {
			return p.Status.Reason
		}
		return ""
	}
	for _, cs := range slices.Concat(p.Status.InitContainerStatuses, p.Status.ContainerStatuses) {
		if t := cs.State.Terminated; t != nil && t.Reason == "ContainerStatusUnknown" {
			return t.Reason
		}
	}
	return ""
}

// orphans returns the pods cleanup deletes from node, with the reason of
// each.
func orphans(pods []kubePod, node string) (out []kubePod, reasons []string) {
	for _, p := range pods {
		if r := orphanReason(p, node); r != "" {
			out = append(out, p)
			reasons = append(reasons, r)
		}
	}
	return out, reasons
}

// restartNode is one node to restart.
type restartNode struct {
	vm      infra.VM
	role    string
	address string // the Talos API address

	// From the snapshot taken just before the node's restart.
	wasReady    bool
	wasCordoned bool
	bootID      string
	// daemonSets had a Ready pod on the node; step 3 waits for each to
	// have one again, and not the one in before.
	daemonSets []string
	// before is, for each of daemonSets, the identity of its Ready pod
	// before the restart.
	before map[string]podIdentity
	// workloads are the Deployments and StatefulSets, "Kind ns/name", that
	// had a pod on the node and were available; step 6 waits for them.
	workloads []string
	// unavailable had a pod on the node but were not available before
	// the restart, so step 6 does not wait for them.
	unavailable []string
}

func (t *restartNode) name() string { return t.vm.Name }

// podIdentity tells a pod, and the run of its containers, from another: a
// DaemonSet pod is often the same object after a reboot, with new
// containers.
type podIdentity struct {
	uid          string
	containerIDs []string
}

func identity(p kubePod) podIdentity {
	id := podIdentity{uid: p.Metadata.UID}
	for _, cs := range p.Status.ContainerStatuses {
		if cs.ContainerID != "" {
			id.containerIDs = append(id.containerIDs, cs.ContainerID)
		}
	}
	return id
}

// since reports whether p is a pod, or a run of its containers, that started
// after old: another pod, or the same one with none of its old containers.
// Right after a quick reboot or a hard stop, the API can still hold the old
// containers' status, Ready, until the kubelet reports again.
func (id podIdentity) since(old podIdentity) bool {
	if id.uid != old.uid {
		return true
	}
	if len(id.containerIDs) == 0 {
		return false
	}
	for _, c := range id.containerIDs {
		if slices.Contains(old.containerIDs, c) {
			return false
		}
	}
	return true
}

type restarter struct {
	r *Runner
	o RestartOptions
}

func (x *restarter) kubectl(ctx context.Context, args ...string) ([]byte, error) {
	return x.o.Tools.Kubectl(ctx, append([]string{kubectlTimeout}, args...)...)
}

func kubeGet[T any](ctx context.Context, x *restarter, args ...string) (T, error) {
	var v T
	out, err := x.kubectl(ctx, append([]string{"get"}, args...)...)
	if err != nil {
		return v, err
	}
	if err := json.Unmarshal(out, &v); err != nil {
		return v, fmt.Errorf("kubectl get %s: decoding: %w", strings.Join(args, " "), err)
	}
	return v, nil
}

func (x *restarter) node(ctx context.Context, name string) (kubeNode, error) {
	return kubeGet[kubeNode](ctx, x, "node", name, "-o", "json")
}

func (x *restarter) podsOn(ctx context.Context, node string) ([]kubePod, error) {
	l, err := kubeGet[kubeList[kubePod]](ctx, x, "pods", "-A", "-o", "json", "--field-selector", "spec.nodeName="+node)
	return l.Items, err
}

// checkNodes refuses while any node is not Ready, except a control plane,
// which the garage keeps off the pod network and so reads NotReady for good.
func (x *restarter) checkNodes(ctx context.Context) (map[string]kubeNode, error) {
	l, err := kubeGet[kubeList[kubeNode]](ctx, x, "nodes", "-o", "json")
	if err != nil {
		return nil, err
	}
	nodes := map[string]kubeNode{}
	var notReady []string
	for _, n := range l.Items {
		nodes[n.Metadata.Name] = n
		if !nodeReady(n) && !isControlPlane(n) {
			notReady = append(notReady, n.Metadata.Name)
		}
	}
	if len(notReady) > 0 {
		slices.Sort(notReady)
		return nil, fmt.Errorf("refusing to restart while nodes are not Ready: %s (only a control plane may be NotReady)", strings.Join(notReady, ", "))
	}
	return nodes, nil
}

// targets returns the VMs to restart: the ones named, in that order, or
// every worker by name.
func (x *restarter) targets(owned []infra.VM) ([]infra.VM, error) {
	cluster := x.r.Config.Cluster
	if len(x.o.Nodes) == 0 {
		var out []infra.VM
		for _, v := range owned {
			if v.Label(LabelRole) == RoleWorker {
				out = append(out, v)
			}
		}
		if len(out) == 0 {
			return nil, fmt.Errorf("cluster %s has no worker VMs", cluster)
		}
		return out, nil
	}
	var out []infra.VM
	var unknown []string
	for _, n := range x.o.Nodes {
		i := slices.IndexFunc(owned, func(v infra.VM) bool { return v.Name == n })
		if i < 0 {
			unknown = append(unknown, n)
			continue
		}
		out = append(out, owned[i])
	}
	if len(unknown) > 0 {
		var names []string
		for _, v := range owned {
			names = append(names, v.Name)
		}
		return nil, fmt.Errorf("not VMs of cluster %s: %s (its VMs: %s)", cluster, strings.Join(unknown, ", "), strings.Join(names, ", "))
	}
	return out, nil
}

// talosAddress picks the address talosctl reaches the node at: the VM's own
// static address, as compute reports it from its config or network snippet,
// and otherwise the Kubernetes node's InternalIP on the VM's subnet. When
// both are known they must agree, which also catches a kubeconfig of another
// cluster whose nodes happen to have the same names.
func talosAddress(nic infra.NIC, n kubeNode) (string, error) {
	vmAddr := ""
	if nic.Address.IsValid() {
		vmAddr = nic.Address.Addr().String()
	}
	nodeAddr := ""
	for _, a := range n.Status.Addresses {
		if ip, err := netip.ParseAddr(a.Address); a.Type == "InternalIP" && err == nil && nic.Subnet.Contains(ip) {
			nodeAddr = a.Address
			break
		}
	}
	switch {
	case vmAddr != "" && nodeAddr != "" && vmAddr != nodeAddr:
		return "", fmt.Errorf("node %s: the VM's address is %s but the Kubernetes node's InternalIP is %s; is KUBECONFIG this cluster's?", n.Metadata.Name, vmAddr, nodeAddr)
	case vmAddr != "":
		return vmAddr, nil
	case nodeAddr != "":
		return nodeAddr, nil
	}
	return "", fmt.Errorf("node %s: no address in %s in the VM's config, its snippet or the Kubernetes node", n.Metadata.Name, nic.Subnet)
}

// snapshot reads, without changing anything, what the node's restart waits
// for afterwards. It is taken just before each node's restart, since the
// restart of the node before moves pods.
func (x *restarter) snapshot(ctx context.Context, t *restartNode) error {
	n, err := x.node(ctx, t.name())
	if err != nil {
		return err
	}
	// A node restart cordoned itself, and left so after a failure, is
	// uncordoned by the rerun; one cordoned by someone else stays so.
	_, ours := n.Metadata.Annotations[cordonAnnotation]
	t.wasReady, t.wasCordoned, t.bootID = nodeReady(n), n.Spec.Unschedulable && !ours, n.Status.NodeInfo.BootID
	if t.bootID == "" {
		return fmt.Errorf("node %s reports no boot ID, so a restart could not tell when it has rebooted", t.name())
	}
	pods, err := x.podsOn(ctx, t.name())
	if err != nil {
		return err
	}
	var ds, rs, sts []string
	t.before = map[string]podIdentity{}
	for _, p := range pods {
		if terminal(p) || p.Metadata.DeletionTimestamp != "" {
			continue
		}
		c, ok := controller(p.Metadata)
		if !ok {
			continue
		}
		k := p.Metadata.Namespace + "/" + c.Name
		switch c.Kind {
		case "DaemonSet":
			// One whose pod was not Ready before would not be after,
			// and is no sign of the node being back.
			if podReady(p) && !slices.Contains(ds, k) {
				ds = append(ds, k)
				t.before[k] = identity(p)
			}
		case "ReplicaSet":
			rs = append(rs, k)
		case "StatefulSet":
			sts = append(sts, k)
		}
	}
	slices.Sort(ds)
	t.daemonSets = ds
	if t.role == RoleWorker {
		var missing []string
		for _, d := range x.o.RequireDaemonSets {
			if !slices.Contains(ds, d) {
				missing = append(missing, d)
			}
		}
		if len(missing) > 0 {
			return fmt.Errorf("worker %s has no Ready pod of DaemonSet %s, so its restart could not tell when it is back; fix that first, or change -require-daemonsets", t.name(), strings.Join(missing, ", "))
		}
	}

	var want []string
	if len(rs) > 0 {
		l, err := kubeGet[kubeList[kubeObject]](ctx, x, "replicasets", "-A", "-o", "json")
		if err != nil {
			return err
		}
		deploy := map[string]string{}
		for _, r := range l.Items {
			if c, ok := controller(r.Metadata); ok && c.Kind == "Deployment" {
				deploy[key(r.Metadata)] = "Deployment " + r.Metadata.Namespace + "/" + c.Name
			}
		}
		for _, k := range rs {
			// A ReplicaSet of its own, without a Deployment, is rare
			// and not waited for.
			if d, ok := deploy[k]; ok {
				want = append(want, d)
			}
		}
	}
	for _, k := range sts {
		want = append(want, "StatefulSet "+k)
	}
	slices.Sort(want)
	want = slices.Compact(want)
	t.workloads, t.unavailable = nil, nil
	if len(want) == 0 {
		return nil
	}
	status, err := x.workloads(ctx)
	if err != nil {
		return err
	}
	for _, w := range want {
		s, ok := status[w]
		if !ok {
			continue
		}
		if avail, _ := workloadAvailable(s); avail {
			t.workloads = append(t.workloads, w)
		} else {
			t.unavailable = append(t.unavailable, w)
		}
	}
	return nil
}

// workloads returns every Deployment and StatefulSet by "Kind ns/name".
func (x *restarter) workloads(ctx context.Context) (map[string]kubeWorkload, error) {
	l, err := kubeGet[kubeList[kubeWorkload]](ctx, x, "deployments,statefulsets", "-A", "-o", "json")
	if err != nil {
		return nil, err
	}
	out := map[string]kubeWorkload{}
	for _, w := range l.Items {
		out[w.Kind+" "+key(w.Metadata)] = w
	}
	return out, nil
}

// poll calls check until it reports done or ctx ends. It prints each new
// status, so a long wait shows what it is waiting on. An error from check,
// such as kubectl failing while the API server restarts, is a status too,
// and the next poll tries again.
func (x *restarter) poll(ctx context.Context, what string, check func(context.Context) (bool, string, error)) error {
	every := x.o.PollInterval
	if every == 0 {
		every = restartPoll
	}
	printed := ""
	for {
		done, status, err := check(ctx)
		if err == nil && done {
			return nil
		}
		if err != nil {
			status = shortError(err)
		}
		if status != printed {
			x.r.logf("      %s", status)
			printed = status
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("waiting for %s: %w (last: %s)", what, ctx.Err(), status)
		case <-time.After(every):
		}
	}
}

// restartStep is one of the six steps of a node's restart. A dry run prints
// what and cmds; a real run prints them, then calls do.
type restartStep struct {
	what string
	cmds []string
	do   func(context.Context) error
}

func (x *restarter) steps(t *restartNode) []restartStep {
	name := t.name()
	var steps []restartStep

	// 1. Cordon first, so nothing new is scheduled onto the node while it
	// goes down. A node that still reads Ready otherwise keeps being sent
	// replacements, which the shutting-down kubelet refuses with
	// NodeShutdown.
	if t.wasCordoned {
		steps = append(steps, restartStep{what: "cordon " + name + ": it is cordoned already", do: func(context.Context) error { return nil }})
	} else {
		annotate := []string{"annotate", "node", name, cordonAnnotation + "=true", "--overwrite"}
		steps = append(steps, restartStep{
			what: "cordon " + name,
			cmds: []string{"kubectl " + strings.Join(annotate, " "), "kubectl cordon " + name},
			do: func(ctx context.Context) error {
				if _, err := x.kubectl(ctx, annotate...); err != nil {
					return err
				}
				_, err := x.kubectl(ctx, "cordon", name)
				return err
			},
		})
	}

	// 2. Restart it.
	if x.o.Mode == ModeReboot {
		// Not --wait: the wait is step 3's, on the boot ID Kubernetes
		// reports, the same for both modes.
		args := []string{"-n", t.address, "reboot", "--wait=false"}
		steps = append(steps, restartStep{
			what: "reboot Talos on " + name,
			cmds: []string{"talosctl " + strings.Join(args, " ")},
			do: func(ctx context.Context) error {
				_, err := x.o.Tools.Talosctl(ctx, args...)
				return err
			},
		})
	} else {
		// Compute's error says what state a failed power cycle leaves the
		// VM in, since a rerun refuses a stopped VM.
		compute := x.r.Compute
		steps = append(steps, restartStep{
			what: fmt.Sprintf("power-cycle VM %s (%s on %s) through %s", name, t.vm.ID, t.vm.Zone, compute),
			cmds: compute.PowerCycleCalls(t.vm, x.o.ShutdownTimeout),
			do: func(ctx context.Context) error {
				return compute.PowerCycle(ctx, x.r.Config.Cluster, t.vm, x.o.ShutdownTimeout)
			},
		})
	}

	// 3. Wait for it to be back: a new boot ID, which tells a node that
	// has rebooted from one that has not gone down yet, then Ready, then
	// a Ready pod of each DaemonSet that had one there.
	ready := "Ready"
	if !t.wasReady {
		// A control plane kept off the pod network stays NotReady.
		ready = "its NotReady state, as before"
	}
	wait := fmt.Sprintf("wait for %s to boot again (a new boot ID) and reach %s", name, ready)
	if len(t.daemonSets) > 0 {
		wait += ", then for a Ready pod, with new containers, of each DaemonSet " + strings.Join(t.daemonSets, ", ") + " on it"
	}
	steps = append(steps, restartStep{what: wait, do: func(ctx context.Context) error { return x.waitBack(ctx, t) }})

	// 4. Uncordon, unless it was cordoned before.
	if t.wasCordoned {
		steps = append(steps, restartStep{what: "leave " + name + " cordoned, as it was before", do: func(context.Context) error { return nil }})
	} else {
		unannotate := []string{"annotate", "node", name, cordonAnnotation + "-"}
		steps = append(steps, restartStep{
			what: "uncordon " + name,
			cmds: []string{"kubectl uncordon " + name, "kubectl " + strings.Join(unannotate, " ")},
			do: func(ctx context.Context) error {
				if _, err := x.kubectl(ctx, "uncordon", name); err != nil {
					return err
				}
				_, err := x.kubectl(ctx, unannotate...)
				return err
			},
		})
	}

	// 5. Delete the pods the restart left behind on the node.
	steps = append(steps, restartStep{
		what: "delete the Failed pods the restart left on " + name + ": Terminated by its shutdown, NodeShutdown, Evicted, ContainerStatusUnknown",
		do:   func(ctx context.Context) error { return x.cleanup(ctx, name) },
	})

	// 6. Wait for what ran on the node to be available again. This, not
	// the node alone, is what catches a dependency coming back late, as
	// Keycloak did for Quay.
	what := "no Deployment or StatefulSet had a pod on " + name
	if len(t.workloads) > 0 {
		what = "wait for " + strings.Join(t.workloads, ", ") + " to be available"
	}
	if len(t.unavailable) > 0 {
		what += "; not waiting for " + strings.Join(t.unavailable, ", ") + ", not available before the restart"
	}
	steps = append(steps, restartStep{what: what, do: func(ctx context.Context) error { return x.waitWorkloads(ctx, t.workloads) }})
	return steps
}

func (x *restarter) waitBack(ctx context.Context, t *restartNode) error {
	name := t.name()
	err := x.poll(ctx, name+" to boot again", func(ctx context.Context) (bool, string, error) {
		n, err := x.node(ctx, name)
		if err != nil {
			return false, "", err
		}
		switch {
		case n.Status.NodeInfo.BootID == t.bootID:
			return false, name + " has not rebooted yet", nil
		case t.wasReady && !nodeReady(n):
			return false, name + " has rebooted, not Ready yet", nil
		}
		return true, "", nil
	})
	if err != nil || len(t.daemonSets) == 0 {
		return err
	}
	return x.poll(ctx, "the DaemonSet pods on "+name, func(ctx context.Context) (bool, string, error) {
		pods, err := x.podsOn(ctx, name)
		if err != nil {
			return false, "", err
		}
		var waiting []string
		for _, d := range t.daemonSets {
			if !slices.ContainsFunc(pods, func(p kubePod) bool {
				c, ok := controller(p.Metadata)
				return ok && c.Kind == "DaemonSet" && p.Metadata.Namespace+"/"+c.Name == d && podReady(p) &&
					identity(p).since(t.before[d])
			}) {
				waiting = append(waiting, d)
			}
		}
		if len(waiting) > 0 {
			return false, "no Ready pod since the restart yet of " + strings.Join(waiting, ", "), nil
		}
		return true, "", nil
	})
}

func (x *restarter) cleanup(ctx context.Context, node string) error {
	pods, err := x.podsOn(ctx, node)
	if err != nil {
		return err
	}
	del, reasons := orphans(pods, node)
	if len(del) == 0 {
		x.r.logf("      no pods to delete")
		return nil
	}
	byNS := map[string][]string{}
	var namespaces []string
	for _, p := range del {
		ns := p.Metadata.Namespace
		if _, ok := byNS[ns]; !ok {
			namespaces = append(namespaces, ns)
		}
		byNS[ns] = append(byNS[ns], p.Metadata.Name)
	}
	slices.Sort(namespaces)
	for _, ns := range namespaces {
		args := append([]string{"delete", "pod", "-n", ns, "--ignore-not-found", "--wait=false"}, byNS[ns]...)
		if _, err := x.kubectl(ctx, args...); err != nil {
			return err
		}
	}
	count := map[string]int{}
	for _, r := range reasons {
		count[r]++
	}
	var parts []string
	for _, r := range orphanReasons {
		if count[r] > 0 {
			parts = append(parts, fmt.Sprintf("%d %s", count[r], r))
		}
	}
	noun := "pods"
	if len(del) == 1 {
		noun = "pod"
	}
	x.r.logf("      deleted %d %s from %s: %s", len(del), noun, node, strings.Join(parts, ", "))
	return nil
}

func (x *restarter) waitWorkloads(ctx context.Context, want []string) error {
	if len(want) == 0 {
		return nil
	}
	return x.poll(ctx, strings.Join(want, ", "), func(ctx context.Context) (bool, string, error) {
		status, err := x.workloads(ctx)
		if err != nil {
			return false, "", err
		}
		var waiting []string
		for _, w := range want {
			s, ok := status[w]
			if !ok {
				// Deleted meanwhile: nothing left to wait for.
				continue
			}
			if avail, how := workloadAvailable(s); !avail {
				waiting = append(waiting, w+" ("+how+")")
			}
		}
		if len(waiting) > 0 {
			return false, "waiting for " + strings.Join(waiting, ", "), nil
		}
		return true, "", nil
	})
}

// Restart restarts the cluster's workers one at a time, or the nodes
// RestartOptions.Nodes names in that order, each in six steps: cordon it,
// restart it in the chosen mode, wait until it has booted again, is Ready
// and its node-local DaemonSet pods are Ready, uncordon it, delete the
// Failed pods the restart left on it, and wait until every Deployment and
// StatefulSet that had a pod on it is available again. Only then does it
// move to the next node.
//
// It does not drain. The kubelet's graceful node shutdown stops the node's
// pods anyway, and their controllers recreate them on the other workers,
// which are not cordoned, so Deployment and StatefulSet pods and their RBD
// volumes can move either way; a StatefulSet's new pod can sit in
// Multi-Attach until the old node reports the volume unmounted. Step 6 waits
// for those moved and recreated workloads. A drain would evict them first,
// through PodDisruptionBudgets, which the shutdown does not honor; whether to
// add one is left for later.
//
// Before anything changes it checks compute's credentials, that every
// target is a running VM of the cluster with a Kubernetes node of the same
// name and a Talos address, that every node is Ready except a control plane,
// which may be NotReady by design, and that each worker has a Ready pod of
// every required DaemonSet. The node check runs again before each node.
//
// A dry run does those reads and prints the steps of every node, and changes
// nothing. A failure, or the timeout of one node, stops the run there and
// does not go on to the next node. A node that fails before step 4 is left
// cordoned, so nothing new is scheduled onto a node that did not come back;
// the error says so and what was not restarted.
//
// The command line checks the cluster name and o.Validate before reading the
// compute provider's credentials; Restart takes both as checked.
func (r *Runner) Restart(ctx context.Context, o RestartOptions) error {
	if o.Tools == nil {
		return errors.New("restart: no kubectl and talosctl to run")
	}
	x := &restarter{r: r, o: o}
	if err := r.Compute.Check(ctx); err != nil {
		return err
	}
	owned, err := r.Compute.List(ctx, r.Config.Cluster)
	if err != nil {
		return err
	}
	vms, err := x.targets(owned)
	if err != nil {
		return err
	}
	kn, err := x.checkNodes(ctx)
	if err != nil {
		return err
	}
	var targets []*restartNode
	var errs []error
	for _, v := range vms {
		t := &restartNode{vm: v, role: v.Label(LabelRole)}
		n, ok := kn[v.Name]
		switch {
		case v.Status != "running":
			errs = append(errs, fmt.Errorf("VM %s is %s, not running", v.Name, v.Status))
			continue
		case !ok:
			errs = append(errs, fmt.Errorf("VM %s has no Kubernetes node of the same name; is KUBECONFIG this cluster's?", v.Name))
			continue
		}
		var err error
		if t.address, err = talosAddress(v.NIC, n); err != nil {
			errs = append(errs, err)
			continue
		}
		if err := x.snapshot(ctx, t); err != nil {
			errs = append(errs, err)
			continue
		}
		targets = append(targets, t)
	}
	if len(errs) > 0 {
		return fmt.Errorf("refusing to restart: %w", errors.Join(errs...))
	}

	var names []string
	for _, t := range targets {
		names = append(names, t.name())
	}
	r.logf("restart %s in mode %s, one at a time: %s", r.Config.Cluster, o.Mode, strings.Join(names, ", "))
	for i, t := range targets {
		if i > 0 && !r.DryRun {
			// Every node, not only the next: one that went NotReady
			// meanwhile is reason enough to stop. The snapshot is taken
			// again because the last restart moved pods.
			if _, err := x.checkNodes(ctx); err != nil {
				return fmt.Errorf("%w; not restarted: %s", err, strings.Join(names[i:], ", "))
			}
			if err := x.snapshot(ctx, t); err != nil {
				return fmt.Errorf("%w; not restarted: %s", err, strings.Join(names[i:], ", "))
			}
		}
		r.logf("== %s (%d/%d): %s, %s on %s, Talos at %s", t.name(), i+1, len(targets), t.role, t.vm.ID, t.vm.Zone, t.address)
		steps := x.steps(t)
		if r.DryRun {
			for j, s := range steps {
				r.logf("  %d/%d %s", j+1, len(steps), s.what)
				for _, c := range s.cmds {
					r.logf("      %s", strings.ReplaceAll(c, "\n", "\n      "))
				}
			}
			continue
		}
		if err := x.restartOne(ctx, t, steps, names[i+1:]); err != nil {
			return err
		}
	}
	if r.DryRun {
		r.logf("dry run: restarted none of these %d nodes", len(targets))
		return nil
	}
	r.logf("restarted %s", strings.Join(names, ", "))
	return nil
}

// restartOne runs one node's steps under the per-node timeout. On a failure
// it says what state the node is left in and what was not restarted.
func (x *restarter) restartOne(ctx context.Context, t *restartNode, steps []restartStep, rest []string) error {
	nctx, cancel := context.WithTimeout(ctx, x.o.Timeout)
	defer cancel()
	began := time.Now()
	for j, s := range steps {
		x.r.logf("  %d/%d %s", j+1, len(steps), s.what)
		for _, c := range s.cmds {
			x.r.logf("      %s", strings.ReplaceAll(c, "\n", "\n      "))
		}
		err := s.do(nctx)
		if err == nil {
			continue
		}
		msg := fmt.Sprintf("%s, step %d/%d (%s): %v", t.name(), j+1, len(steps), s.what, err)
		if j >= 1 && j <= 3 && !t.wasCordoned {
			// Uncordoning a node that has not come back would let
			// pods be scheduled onto it, which is what restart is
			// meant to prevent; after a failed uncordon it is still
			// cordoned too.
			msg += fmt.Sprintf("; %s is left cordoned: once it is healthy, kubectl uncordon %s, or rerun restart on it, which uncordons it", t.name(), t.name())
		}
		if j < 2 {
			// It may not have gone down; a rerun restarts it again.
			rest = append([]string{t.name()}, rest...)
		}
		if len(rest) > 0 {
			msg += fmt.Sprintf("; not restarted: %s (rerun with -nodes %s)", strings.Join(rest, ", "), strings.Join(rest, ","))
		}
		return errors.New(msg)
	}
	x.r.logf("  %s is back after %s", t.name(), time.Since(began).Round(time.Second))
	return nil
}
