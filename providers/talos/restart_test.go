package talos

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"go.holos.run/distro/providers/infra"
)

// fakeNode is one node of fakeCluster.
type fakeNode struct {
	name, addr  string
	cp          bool
	broken      bool // NotReady with no restart involved
	cordoned    bool
	annotations map[string]string
	boot        int
	// down is a powered-off VM: NotReady, with the old boot ID.
	down bool
	// pendingBoot is a reboot talosctl has accepted that has not
	// happened yet: the node still reads Ready with its old boot ID once
	// more, the race that a wait on Ready alone would lose.
	pendingBoot bool
	// notReady is how many more polls of the node read NotReady after it
	// boots.
	notReady   int
	neverReady bool
	// dsStale is how many more polls of its pods, once it is Ready again,
	// still show its DaemonSet pods Ready with the containers from before
	// the boot; dsUnready is how many more after that show them not Ready.
	dsStale, dsUnready int
}

// fakeCluster is kubectl and talosctl against a small treasury cluster:
// the control plane, NotReady by design, three workers with Cilium and
// ztunnel, and a few workloads. A restart of a node does what a real one
// does to it: the pods its graceful shutdown kills fail Terminated, one
// refused pod fails NodeShutdown, one container is lost, the boot ID changes
// only once it is back, it reads NotReady and its DaemonSet pods unready for
// a few polls, and its Deployments and StatefulSets are unavailable for a
// few polls. It records every command, and the fake compute's power cycles,
// in one log.
type fakeCluster struct {
	t     *testing.T
	mu    sync.Mutex
	nodes map[string]*fakeNode
	pods  []kubePod
	rs    []kubeObject
	works []kubeWorkload
	// unavailable is how many more polls each "Kind ns/name" reads
	// unavailable.
	unavailable map[string]int
	// apiDown is how many more kubectl calls fail, as while the only
	// control plane boots.
	apiDown int
	// staleDS is the dsStale a node gets when it boots.
	staleDS int
	// talosErr, when set, is what every talosctl call fails with.
	talosErr error
	log      []string
}

func owned(kind, name string) []ownerReference {
	return []ownerReference{{Kind: kind, Name: name, Controller: true}}
}

func runningPod(ns, name, node string, owner []ownerReference) kubePod {
	return kubePod{
		Metadata: objectMeta{Namespace: ns, Name: name, UID: "uid-" + ns + "-" + name, OwnerReferences: owner},
		Spec:     podSpec{NodeName: node},
		Status:   podStatus{Phase: "Running", Conditions: []condition{{Type: "Ready", Status: "True"}}},
	}
}

func failedPod(ns, name, node, reason string) kubePod {
	return kubePod{
		Metadata: objectMeta{Namespace: ns, Name: name, UID: "uid-" + ns + "-" + name},
		Spec:     podSpec{NodeName: node},
		Status:   podStatus{Phase: "Failed", Reason: reason},
	}
}

// shutdownPod is a pod the kubelet's node shutdown manager killed. Some
// carry the message only, some the DisruptionTarget condition too.
func shutdownPod(p kubePod, condition bool) kubePod {
	p.Status = podStatus{Phase: "Failed", Reason: "Terminated", Message: shutdownMessage}
	if condition {
		p.Status.Message = ""
		p.Status.Conditions = append(p.Status.Conditions, conditionTerminationByKubelet)
	}
	return p
}

var conditionTerminationByKubelet = condition{Type: "DisruptionTarget", Status: "True", Reason: "TerminationByKubelet"}

func csuPod(ns, name, node string) kubePod {
	p := failedPod(ns, name, node, "")
	p.Status.ContainerStatuses = []containerStatus{{Name: "app", State: containerState{Terminated: &containerTerminated{Reason: "ContainerStatusUnknown"}}}}
	return p
}

func workload(kind, ns, name string, replicas int32) kubeWorkload {
	return kubeWorkload{Kind: kind, Metadata: objectMeta{Namespace: ns, Name: name, Generation: 1}, Spec: workloadSpec{Replicas: &replicas}}
}

var treasuryWorkers = []string{"treasury-general-1", "treasury-general-2", "treasury-general-3"}

func newFakeCluster(t *testing.T) *fakeCluster {
	c := &fakeCluster{t: t, nodes: map[string]*fakeNode{}, unavailable: map[string]int{}}
	c.nodes["treasury-cp-1"] = &fakeNode{name: "treasury-cp-1", addr: "10.20.0.50", cp: true}
	for i, n := range treasuryWorkers {
		c.nodes[n] = &fakeNode{name: n, addr: fmt.Sprintf("10.20.0.%d", 51+i)}
		c.pods = append(c.pods,
			runningPod("kube-system", "cilium-"+n, n, owned("DaemonSet", "cilium")),
			runningPod("istio-system", "ztunnel-"+n, n, owned("DaemonSet", "ztunnel")))
	}
	g1, g2 := treasuryWorkers[0], treasuryWorkers[1]
	job := failedPod("default", "report-1", g1, "Error")
	job.Metadata.OwnerReferences = owned("Job", "report")
	other := failedPod("default", "terminated-other", g1, "Terminated")
	other.Status.Message = "Pod was terminated by the job controller."
	c.pods = append(c.pods,
		runningPod("kube-system", "cilium-operator-abc-1", g1, owned("ReplicaSet", "cilium-operator-abc")),
		runningPod("keycloak", "keycloak-0", g1, owned("StatefulSet", "keycloak")),
		job,
		failedPod("default", "evicted-1", g1, "Evicted"),
		other,
		runningPod("quay", "quay-abc-1", g2, owned("ReplicaSet", "quay-abc")))
	c.rs = []kubeObject{
		{Metadata: objectMeta{Namespace: "kube-system", Name: "cilium-operator-abc", OwnerReferences: owned("Deployment", "cilium-operator")}},
		{Metadata: objectMeta{Namespace: "quay", Name: "quay-abc", OwnerReferences: owned("Deployment", "quay")}},
	}
	c.works = []kubeWorkload{
		workload("Deployment", "kube-system", "cilium-operator", 2),
		workload("StatefulSet", "keycloak", "keycloak", 1),
		workload("Deployment", "quay", "quay", 1),
	}
	return c
}

func (c *fakeCluster) record(s string) { c.log = append(c.log, s) }

func (c *fakeCluster) nodeJSON(n *fakeNode, poll bool) kubeNode {
	ready := !n.cp && !n.broken && !n.down && n.notReady == 0
	if poll && !n.down && n.notReady > 0 {
		n.notReady--
	}
	status := "False"
	if ready {
		status = "True"
	}
	k := kubeNode{
		Metadata: objectMeta{Name: n.name, Labels: map[string]string{"kubernetes.io/hostname": n.name}, Annotations: maps.Clone(n.annotations)},
		Spec:     nodeSpec{Unschedulable: n.cordoned},
		Status: nodeStatus{
			Conditions: []condition{{Type: "Ready", Status: status}},
			Addresses:  []nodeAddress{{Type: "InternalIP", Address: n.addr}, {Type: "Hostname", Address: n.name}},
			NodeInfo:   nodeSystemInfo{BootID: "boot-" + strconv.Itoa(n.boot)},
		},
	}
	if n.cp {
		k.Metadata.Labels[controlPlaneLabel] = ""
	}
	return k
}

// shutDown is what a graceful node shutdown does to the node's pods: the
// shutdown manager kills the ones Deployments and StatefulSets own, which
// fail Terminated, and what it ran becomes unavailable; one replacement
// bound just before the cordon is refused with NodeShutdown; one container
// is lost; its DaemonSet pods stop being Ready.
func (c *fakeCluster) shutDown(n *fakeNode) {
	if !n.cordoned {
		c.t.Errorf("%s went down while schedulable", n.name)
	}
	for i := range c.pods {
		p := &c.pods[i]
		if p.Spec.NodeName != n.name || terminal(*p) {
			continue
		}
		o, _ := controller(p.Metadata)
		switch o.Kind {
		case "ReplicaSet":
			*p = shutdownPod(*p, true)
			for _, r := range c.rs {
				if r.Metadata.Namespace == p.Metadata.Namespace && r.Metadata.Name == o.Name {
					d, _ := controller(r.Metadata)
					c.unavailable["Deployment "+r.Metadata.Namespace+"/"+d.Name] = 2
				}
			}
		case "StatefulSet":
			*p = shutdownPod(*p, false)
			c.unavailable["StatefulSet "+p.Metadata.Namespace+"/"+o.Name] = 2
		}
	}
	c.pods = append(c.pods,
		failedPod("kube-system", "cilium-operator-abc-"+n.name, n.name, "NodeShutdown"),
		csuPod("default", "csu-"+n.name, n.name))
	n.dsUnready = 1 << 30
}

func (c *fakeCluster) bootUp(n *fakeNode) {
	n.down, n.pendingBoot = false, false
	n.boot++
	n.notReady, n.dsStale, n.dsUnready = 2, c.staleDS, 2
	if n.neverReady {
		n.notReady = 1 << 30
	}
	if n.cp {
		// Never Ready, and has no DaemonSet pods, but its API server
		// takes a moment.
		n.notReady, n.dsStale, n.dsUnready = 0, 0, 0
		c.apiDown = 3
	}
}

func (c *fakeCluster) out(v any) ([]byte, error) {
	b, err := json.Marshal(v)
	if err != nil {
		c.t.Fatal(err)
	}
	return b, nil
}

// apiDownError is kubectl's failure while the API server is down: klog
// lines whose headers differ at every call, then the same last line.
func (c *fakeCluster) apiDownError(cmd string) error {
	return &toolError{cmd: cmd, err: errors.New("exit status 1"), stderr: fmt.Sprintf(
		"E1028 10:15:%02d.%06d   4242 memcache.go:265] couldn't get current server API group list: dial tcp 10.20.0.50:6443: connect: connection refused\n"+
			"The connection to the server 10.20.0.50:6443 was refused - did you specify the right host or port?\n", c.apiDown, len(c.log))}
}

func (c *fakeCluster) Kubectl(ctx context.Context, args ...string) ([]byte, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(args) == 0 || args[0] != kubectlTimeout {
		c.t.Errorf("kubectl %v without %s", args, kubectlTimeout)
	} else {
		args = args[1:]
	}
	cmd := "kubectl " + strings.Join(args, " ")
	c.record(cmd)
	if cp := c.nodes["treasury-cp-1"]; cp.down || c.apiDown > 0 {
		if c.apiDown > 0 {
			c.apiDown--
		}
		return nil, c.apiDownError(cmd)
	}
	node := func(name string) (*fakeNode, error) {
		n, ok := c.nodes[name]
		if !ok {
			return nil, fmt.Errorf(`Error from server (NotFound): nodes %q not found`, name)
		}
		return n, nil
	}
	switch {
	case cmd == "kubectl get nodes -o json":
		var l kubeList[kubeNode]
		for _, name := range slices.Sorted(maps.Keys(c.nodes)) {
			l.Items = append(l.Items, c.nodeJSON(c.nodes[name], false))
		}
		return c.out(l)
	case len(args) == 5 && args[0] == "get" && args[1] == "node" && args[3] == "-o" && args[4] == "json":
		n, err := node(args[2])
		if err != nil {
			return nil, err
		}
		if n.pendingBoot {
			// Once more as it was, then the reboot happens.
			out := c.nodeJSON(n, false)
			c.bootUp(n)
			return c.out(out)
		}
		return c.out(c.nodeJSON(n, true))
	case len(args) == 7 && strings.Join(args[:6], " ") == "get pods -A -o json --field-selector":
		name, _ := strings.CutPrefix(args[6], "spec.nodeName=")
		n, err := node(name)
		if err != nil {
			return nil, err
		}
		// A DaemonSet pod is the same object across the boot, with new
		// containers once the kubelet has started them.
		dsReady, dsBoot := true, n.boot
		switch {
		case n.down || n.pendingBoot:
			dsReady = false
		case n.dsStale > 0:
			dsBoot = n.boot - 1
			if n.notReady == 0 {
				n.dsStale--
			}
		case n.dsUnready > 0:
			dsReady = false
			if n.notReady == 0 {
				n.dsUnready--
			}
		}
		var l kubeList[kubePod]
		for _, p := range c.pods {
			if p.Spec.NodeName != name {
				continue
			}
			if o, _ := controller(p.Metadata); o.Kind == "DaemonSet" {
				p.Status.ContainerStatuses = []containerStatus{{Name: "agent", ContainerID: fmt.Sprintf("containerd://%s-%d", p.Metadata.Name, dsBoot)}}
				if !dsReady {
					p.Status.Conditions = []condition{{Type: "Ready", Status: "False"}}
				}
			}
			l.Items = append(l.Items, p)
		}
		return c.out(l)
	case cmd == "kubectl get replicasets -A -o json":
		return c.out(kubeList[kubeObject]{Items: c.rs})
	case cmd == "kubectl get deployments,statefulsets -A -o json":
		var l kubeList[kubeWorkload]
		for _, w := range c.works {
			k := w.Kind + " " + key(w.Metadata)
			w.Status.ObservedGeneration = 1
			if c.unavailable[k] > 0 {
				c.unavailable[k]--
			} else {
				w.Status.ReadyReplicas, w.Status.AvailableReplicas = *w.Spec.Replicas, *w.Spec.Replicas
			}
			l.Items = append(l.Items, w)
		}
		return c.out(l)
	case len(args) == 2 && (args[0] == "cordon" || args[0] == "uncordon"):
		n, err := node(args[1])
		if err != nil {
			return nil, err
		}
		if args[0] == "uncordon" && (n.down || n.pendingBoot || n.notReady > 0 || n.dsStale > 0 || n.dsUnready > 0) {
			c.t.Errorf("uncordoned %s before it was back", n.name)
		}
		n.cordoned = args[0] == "cordon"
		return nil, nil
	case len(args) >= 4 && args[0] == "annotate" && args[1] == "node":
		n, err := node(args[2])
		if err != nil {
			return nil, err
		}
		if n.annotations == nil {
			n.annotations = map[string]string{}
		}
		if k, ok := strings.CutSuffix(args[3], "-"); ok && len(args) == 4 {
			delete(n.annotations, k)
			return nil, nil
		}
		if k, v, ok := strings.Cut(args[3], "="); ok && len(args) == 5 && args[4] == "--overwrite" {
			n.annotations[k] = v
			return nil, nil
		}
	case len(args) > 6 && strings.Join(args[:2], " ") == "delete pod" && args[2] == "-n" &&
		strings.Join(args[4:6], " ") == "--ignore-not-found --wait=false":
		for _, name := range args[6:] {
			c.pods = slices.DeleteFunc(c.pods, func(p kubePod) bool {
				return p.Metadata.Namespace == args[3] && p.Metadata.Name == name
			})
		}
		return nil, nil
	}
	c.t.Errorf("fake kubectl: unexpected %s", cmd)
	return nil, errors.New("not faked: " + cmd)
}

func (c *fakeCluster) Talosctl(ctx context.Context, args ...string) ([]byte, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	cmd := "talosctl " + strings.Join(args, " ")
	c.record(cmd)
	if c.talosErr != nil {
		return nil, c.talosErr
	}
	if len(args) == 4 && args[0] == "-n" && args[2] == "reboot" && args[3] == "--wait=false" {
		for _, n := range c.nodes {
			if n.addr == args[1] {
				c.shutDown(n)
				n.pendingBoot = true
				return nil, nil
			}
		}
	}
	c.t.Errorf("fake talosctl: unexpected %s", cmd)
	return nil, errors.New("not faked: " + cmd)
}

// computeHook makes the fake compute's power cycles act on the cluster.
func (c *fakeCluster) computeHook(half string, vm infra.VM) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.record("compute " + half + " " + vm.Name)
	n := c.nodes[vm.Name]
	if n == nil {
		return
	}
	switch half {
	case "shutdown":
		c.shutDown(n)
		n.down = true
	case "start":
		c.bootUp(n)
	}
}

// collapsed is the log with runs of the same command, a wait polling,
// folded into one.
func (c *fakeCluster) collapsed() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return slices.Compact(slices.Clone(c.log))
}

// restartFixture is a treasury cluster in the fake compute, whose VMs are
// the fake cluster's nodes. Compute reports no address for general-3, as
// Proxmox does without the snippets mount, so its Talos address comes from
// the Kubernetes node.
func restartFixture(t *testing.T) (*Runner, *bytes.Buffer, *fakeCompute, *fakeCluster) {
	t.Helper()
	f := newFakeCompute("treasury")
	kc := newFakeCluster(t)
	f.hook = kc.computeHook
	f.add("treasury-cp-1", "r620a", "10.20.0.50", infra.Size{Cores: 2, MemoryMiB: 8192}, infra.Label{Key: LabelRole, Value: RoleControlPlane})
	zones := []string{"r620b", "r620c", "r620a"}
	for i, n := range treasuryWorkers {
		addr := ""
		if i < 2 {
			addr = fmt.Sprintf("10.20.0.%d", 51+i)
		}
		f.add(n, zones[i], addr, infra.Size{Cores: 4, MemoryMiB: 16384},
			infra.Label{Key: LabelRole, Value: RoleWorker}, infra.Label{Key: LabelPool, Value: "general"})
	}
	r, out := newRunner(t, f, treasury())
	return r, out, f, kc
}

func restartOpts(kc *fakeCluster, mode string) RestartOptions {
	return RestartOptions{
		Mode:              mode,
		Timeout:           time.Minute,
		ShutdownTimeout:   time.Second,
		RequireDaemonSets: DefaultRequiredDaemonSets,
		Tools:             kc,
		PollInterval:      time.Millisecond,
	}
}

// snapshotLog is what restart reads of one node before restarting it.
func snapshotLog(node string, rs, works bool) []string {
	out := []string{"kubectl get node " + node + " -o json", "kubectl get pods -A -o json --field-selector spec.nodeName=" + node}
	if rs {
		out = append(out, "kubectl get replicasets -A -o json")
	}
	if works {
		out = append(out, "kubectl get deployments,statefulsets -A -o json")
	}
	return out
}

// nodeLog is the six steps of one node: mark and cordon, restart, wait for
// the node and then its DaemonSet pods, uncordon and unmark, the cleanup's
// read and deletes, and the wait for its workloads.
func nodeLog(node string, restart []string, deletes []string, works bool) []string {
	pods := "kubectl get pods -A -o json --field-selector spec.nodeName=" + node
	out := []string{"kubectl annotate node " + node + " " + cordonAnnotation + "=true --overwrite", "kubectl cordon " + node}
	out = append(out, restart...)
	out = append(out, "kubectl get node "+node+" -o json", pods,
		"kubectl uncordon "+node, "kubectl annotate node "+node+" "+cordonAnnotation+"-", pods)
	out = append(out, deletes...)
	if works {
		out = append(out, "kubectl get deployments,statefulsets -A -o json")
	}
	return out
}

func del(ns string, names ...string) string {
	return "kubectl delete pod -n " + ns + " --ignore-not-found --wait=false " + strings.Join(names, " ")
}

func failedLeft(kc *fakeCluster) []string {
	var failed []string
	for _, p := range kc.pods {
		if p.Status.Phase == "Failed" {
			failed = append(failed, key(p.Metadata))
		}
	}
	return failed
}

// The whole run, both modes: the preflight's reads, then for each worker in
// name order cordon, restart, wait for a new boot ID and Ready and for the
// Cilium and ztunnel pods, uncordon, delete what the restart left behind,
// and wait for the node's Deployments and StatefulSets, before the next
// node's check and snapshot. Nothing of a node starts before the one before
// it is done.
func TestRestartOrder(t *testing.T) {
	g1, g2, g3 := treasuryWorkers[0], treasuryWorkers[1], treasuryWorkers[2]
	for _, mode := range []string{ModeReboot, ModePowerCycle} {
		t.Run(mode, func(t *testing.T) {
			r, out, f, kc := restartFixture(t)
			if err := r.Restart(context.Background(), restartOpts(kc, mode)); err != nil {
				t.Fatalf("Restart: %v\n%s", err, out)
			}
			t.Log(out)
			restart := func(node, addr string) []string {
				if mode == ModeReboot {
					return []string{"talosctl -n " + addr + " reboot --wait=false"}
				}
				return []string{"compute shutdown " + node, "compute start " + node}
			}
			want := slices.Concat(
				[]string{"kubectl get nodes -o json"},
				snapshotLog(g1, true, true), snapshotLog(g2, true, true), snapshotLog(g3, false, false),
				nodeLog(g1, restart(g1, "10.20.0.51"), []string{
					del("default", "evicted-1", "csu-"+g1),
					del("keycloak", "keycloak-0"),
					del("kube-system", "cilium-operator-abc-1", "cilium-operator-abc-"+g1),
				}, true),
				[]string{"kubectl get nodes -o json"}, snapshotLog(g2, true, true),
				nodeLog(g2, restart(g2, "10.20.0.52"), []string{
					del("default", "csu-"+g2),
					del("kube-system", "cilium-operator-abc-"+g2),
					del("quay", "quay-abc-1"),
				}, true),
				[]string{"kubectl get nodes -o json"}, snapshotLog(g3, false, false),
				nodeLog(g3, restart(g3, "10.20.0.53"), []string{
					del("default", "csu-"+g3),
					del("kube-system", "cilium-operator-abc-"+g3),
				}, false),
			)
			if got := kc.collapsed(); !slices.Equal(got, want) {
				t.Errorf("commands =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
			}
			if mode == ModePowerCycle {
				// The guest gets the shutdown timeout to shut down
				// cleanly.
				if !slices.Contains(f.log, "power-cycle treasury-general-1 within 1s") {
					t.Errorf("power cycles = %v", f.log)
				}
			}
			// Nothing Failed is left but the Job's pod and the pod
			// Terminated for another reason, and every node is
			// schedulable and unmarked again.
			if got := failedLeft(kc); !slices.Equal(got, []string{"default/report-1", "default/terminated-other"}) {
				t.Errorf("Failed pods left = %v", got)
			}
			for _, n := range kc.nodes {
				if n.cordoned || n.annotations[cordonAnnotation] != "" {
					t.Errorf("%s left cordoned %v, annotations %v", n.name, n.cordoned, n.annotations)
				}
			}
			for _, w := range []string{
				"deleted 5 pods from treasury-general-1: 2 Terminated, 1 NodeShutdown, 1 Evicted, 1 ContainerStatusUnknown",
				"deleted 3 pods from treasury-general-2: 1 Terminated, 1 NodeShutdown, 1 ContainerStatusUnknown",
				"wait for Deployment kube-system/cilium-operator, StatefulSet keycloak/keycloak to be available",
				"then for a Ready pod, with new containers, of each DaemonSet istio-system/ztunnel, kube-system/cilium on it",
				"waiting for Deployment quay/quay (0/1 available)",
				"restarted treasury-general-1, treasury-general-2, treasury-general-3",
			} {
				if !strings.Contains(out.String(), w) {
					t.Errorf("output lacks %q", w)
				}
			}
		})
	}
}

// Right after a quick reboot the API can still show a DaemonSet pod Ready
// with the containers from before. That is not the node being back: step 3
// waits for the pod's new containers, and the fake fails the test if the
// node is uncordoned before.
func TestRestartWaitsForNewDaemonSetContainers(t *testing.T) {
	r, out, _, kc := restartFixture(t)
	kc.staleDS = 3
	o := restartOpts(kc, ModeReboot)
	o.Nodes = []string{"treasury-general-3"}
	if err := r.Restart(context.Background(), o); err != nil {
		t.Fatalf("Restart: %v\n%s", err, out)
	}
	if n := kc.nodes["treasury-general-3"]; n.dsStale != 0 || n.cordoned {
		t.Errorf("stale polls left %d, cordoned %v", n.dsStale, n.cordoned)
	}
	if !strings.Contains(out.String(), "no Ready pod since the restart yet of istio-system/ztunnel, kube-system/cilium") {
		t.Errorf("output lacks the wait on the new containers:\n%s", out)
	}
}

func TestPodIdentitySince(t *testing.T) {
	old := podIdentity{uid: "a", containerIDs: []string{"containerd://1", "containerd://2"}}
	for _, tc := range []struct {
		id   podIdentity
		want bool
	}{
		{podIdentity{uid: "b"}, true},
		{podIdentity{uid: "a", containerIDs: []string{"containerd://3", "containerd://4"}}, true},
		{podIdentity{uid: "a", containerIDs: []string{"containerd://3", "containerd://2"}}, false},
		{old, false},
		{podIdentity{uid: "a"}, false},
	} {
		if got := tc.id.since(old); got != tc.want {
			t.Errorf("%v.since(%v) = %v, want %v", tc.id, old, got, tc.want)
		}
	}
}

// A dry run reads and prints every node's steps, in order, and changes
// nothing: no cordon, no talosctl, no power cycle.
func TestRestartDryRun(t *testing.T) {
	for _, mode := range []string{ModeReboot, ModePowerCycle} {
		r, out, f, kc := restartFixture(t)
		r.DryRun = true
		if err := r.Restart(context.Background(), restartOpts(kc, mode)); err != nil {
			t.Fatalf("%s: Restart: %v\n%s", mode, err, out)
		}
		t.Log(out)
		for _, c := range kc.log {
			if !strings.HasPrefix(c, "kubectl get ") {
				t.Errorf("%s: dry run ran %s", mode, c)
			}
		}
		if len(f.log) != 0 {
			t.Errorf("%s: dry run changed %v", mode, f.log)
		}
		restart := "  2/6 reboot Talos on treasury-general-1\n      talosctl -n 10.20.0.51 reboot --wait=false\n"
		if mode == ModePowerCycle {
			restart = "  2/6 power-cycle VM treasury-general-1 (id 105 on r620b) through the fake\n" +
				"      shut down id 105 on r620b within 1s\n" +
				"      start id 105 on r620b\n"
		}
		want := []string{
			"restart treasury in mode " + mode + ", one at a time: treasury-general-1, treasury-general-2, treasury-general-3",
			"== treasury-general-1 (1/3): worker, id 105 on r620b, Talos at 10.20.0.51",
			"  1/6 cordon treasury-general-1\n      kubectl annotate node treasury-general-1 talosvm.holos.run/cordoned=true --overwrite\n      kubectl cordon treasury-general-1\n",
			restart,
			"  3/6 wait for treasury-general-1 to boot again",
			"  4/6 uncordon treasury-general-1\n      kubectl uncordon treasury-general-1\n      kubectl annotate node treasury-general-1 talosvm.holos.run/cordoned-\n",
			"  5/6 delete the Failed pods the restart left on treasury-general-1: Terminated by its shutdown, NodeShutdown, Evicted, ContainerStatusUnknown",
			"  6/6 wait for Deployment kube-system/cilium-operator, StatefulSet keycloak/keycloak to be available",
			"== treasury-general-2 (2/3)",
			"  6/6 wait for Deployment quay/quay to be available",
			"== treasury-general-3 (3/3): worker, id 107 on r620a, Talos at 10.20.0.53",
			"  6/6 no Deployment or StatefulSet had a pod on treasury-general-3",
			"dry run: restarted none of these 3 nodes",
		}
		last := -1
		for _, w := range want {
			i := strings.Index(out.String(), w)
			switch {
			case i < 0:
				t.Errorf("%s: dry run output lacks %q", mode, w)
			case i < last:
				t.Errorf("%s: %q is out of order", mode, w)
			default:
				last = i
			}
		}
	}
}

// A node that does not come back within the timeout stops the run: it is
// left cordoned, the next node is not touched, and the error says what to
// do.
func TestRestartStopsAtFailure(t *testing.T) {
	r, out, _, kc := restartFixture(t)
	kc.nodes["treasury-general-2"].neverReady = true
	o := restartOpts(kc, ModeReboot)
	o.Timeout = 300 * time.Millisecond
	err := r.Restart(context.Background(), o)
	for _, w := range []string{
		"treasury-general-2, step 3/6 (wait for treasury-general-2 to boot again",
		"context deadline exceeded",
		"has rebooted, not Ready yet",
		"treasury-general-2 is left cordoned: once it is healthy, kubectl uncordon treasury-general-2, or rerun restart on it",
		"not restarted: treasury-general-3 (rerun with -nodes treasury-general-3)",
	} {
		if err == nil || !strings.Contains(err.Error(), w) {
			t.Errorf("Restart err = %v, want it to say %q\n%s", err, w, out)
		}
	}
	for _, c := range kc.log {
		if strings.HasSuffix(c, "treasury-general-3") && !strings.HasPrefix(c, "kubectl get") || strings.Contains(c, "10.20.0.53") {
			t.Errorf("went on to the next node: %s", c)
		}
		if c == "kubectl uncordon treasury-general-2" {
			t.Errorf("uncordoned the node that did not come back")
		}
	}
	if !kc.nodes["treasury-general-2"].cordoned || kc.nodes["treasury-general-1"].cordoned {
		t.Errorf("cordoned: general-1 %v, general-2 %v; want false, true", kc.nodes["treasury-general-1"].cordoned, kc.nodes["treasury-general-2"].cordoned)
	}
}

// A restart call that fails leaves the node cordoned and in the list to
// rerun, since it may not have gone down.
func TestRestartFailedRebootIsRerun(t *testing.T) {
	r, _, _, kc := restartFixture(t)
	kc.talosErr = errors.New("rpc error: code = Unavailable")
	err := r.Restart(context.Background(), restartOpts(kc, ModeReboot))
	for _, w := range []string{
		"treasury-general-1, step 2/6 (reboot Talos on treasury-general-1): rpc error",
		"treasury-general-1 is left cordoned",
		"not restarted: treasury-general-1, treasury-general-2, treasury-general-3 (rerun with -nodes treasury-general-1,treasury-general-2,treasury-general-3)",
	} {
		if err == nil || !strings.Contains(err.Error(), w) {
			t.Errorf("Restart err = %v, want it to say %q", err, w)
		}
	}
	if c := kc.collapsed(); c[len(c)-1] != "talosctl -n 10.20.0.51 reboot --wait=false" {
		t.Errorf("ran %s after the failed reboot", c[len(c)-1])
	}
}

// A power cycle that fails in either half stops the run there, with
// compute's error, which says what state the VM is left in.
func TestRestartPowerCycleFailure(t *testing.T) {
	for _, half := range []string{"shutdown", "start"} {
		r, _, f, kc := restartFixture(t)
		f.failHalf = half
		err := r.Restart(context.Background(), restartOpts(kc, ModePowerCycle))
		for _, w := range []string{
			"treasury-general-1, step 2/6 (power-cycle VM treasury-general-1",
			"the fake's " + half + " failed",
			"treasury-general-1 is left cordoned",
			"not restarted: treasury-general-1, treasury-general-2, treasury-general-3",
		} {
			if err == nil || !strings.Contains(err.Error(), w) {
				t.Errorf("%s: Restart err = %v, want it to say %q", half, err, w)
			}
		}
		if c := kc.collapsed(); c[len(c)-1] != "compute "+half+" treasury-general-1" {
			t.Errorf("%s: ran %s after the failed power cycle", half, c[len(c)-1])
		}
	}
}

// Before anything changes, restart refuses a NotReady worker, a name that
// is not one of the cluster's VMs, a worker without Cilium or ztunnel, an
// address the VM and the node disagree on, a stopped VM, and a VM without a
// node. A control plane reading NotReady, as treasury-cp-1 always does, is
// no reason to refuse; every other test runs with it.
func TestRestartRefuses(t *testing.T) {
	for _, tc := range []struct {
		name  string
		nodes []string
		edit  func(*fakeCompute, *fakeCluster)
		want  string
	}{
		{"worker NotReady", nil, func(_ *fakeCompute, c *fakeCluster) { c.nodes["treasury-general-3"].broken = true },
			"refusing to restart while nodes are not Ready: treasury-general-3 (only a control plane may be NotReady)"},
		{"unknown node", []string{"treasury-general-1", "treasury-general-9"}, nil, "not VMs of cluster treasury: treasury-general-9"},
		{"tenant VM", []string{"jeffsbox"}, nil, "not VMs of cluster treasury: jeffsbox"},
		{"no ztunnel", nil, func(_ *fakeCompute, c *fakeCluster) {
			c.pods = slices.DeleteFunc(c.pods, func(p kubePod) bool { return p.Metadata.Name == "ztunnel-treasury-general-3" })
		}, "worker treasury-general-3 has no Ready pod of DaemonSet istio-system/ztunnel"},
		{"address mismatch", nil, func(_ *fakeCompute, c *fakeCluster) { c.nodes["treasury-general-1"].addr = "10.20.0.61" },
			"the VM's address is 10.20.0.51 but the Kubernetes node's InternalIP is 10.20.0.61; is KUBECONFIG this cluster's?"},
		{"stopped VM", nil, func(f *fakeCompute, _ *fakeCluster) { f.find("treasury-general-2").Status = "stopped" }, "VM treasury-general-2 is stopped, not running"},
		{"no node", nil, func(_ *fakeCompute, c *fakeCluster) { delete(c.nodes, "treasury-general-2") },
			"VM treasury-general-2 has no Kubernetes node of the same name"},
	} {
		r, _, f, kc := restartFixture(t)
		if tc.edit != nil {
			tc.edit(f, kc)
		}
		o := restartOpts(kc, ModePowerCycle)
		o.Nodes = tc.nodes
		err := r.Restart(context.Background(), o)
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: err = %v, want %q", tc.name, err, tc.want)
		}
		for _, c := range kc.log {
			if !strings.HasPrefix(c, "kubectl get ") {
				t.Errorf("%s: ran %s before refusing", tc.name, c)
			}
		}
		if len(f.log) != 0 {
			t.Errorf("%s: changed %v before refusing", tc.name, f.log)
		}
	}
}

// The control plane is restarted only when named. It reads NotReady before
// and after, so the wait is for its new boot ID, through the API server
// refusing connections while it comes back. That prints kubectl's last line
// once, without klog's headers, however many polls fail.
func TestRestartControlPlane(t *testing.T) {
	r, out, _, kc := restartFixture(t)
	o := restartOpts(kc, ModePowerCycle)
	o.Nodes = []string{"treasury-cp-1"}
	if err := r.Restart(context.Background(), o); err != nil {
		t.Fatalf("Restart: %v\n%s", err, out)
	}
	if kc.nodes["treasury-cp-1"].boot != 1 || kc.nodes["treasury-cp-1"].cordoned {
		t.Errorf("control plane: boot %d, cordoned %v", kc.nodes["treasury-cp-1"].boot, kc.nodes["treasury-cp-1"].cordoned)
	}
	for _, n := range treasuryWorkers {
		if kc.nodes[n].boot != 0 {
			t.Errorf("restarted %s, which was not named", n)
		}
	}
	for _, w := range []string{"reach its NotReady state, as before", "no Deployment or StatefulSet had a pod on treasury-cp-1"} {
		if !strings.Contains(out.String(), w) {
			t.Errorf("output lacks %q:\n%s", w, out)
		}
	}
	refused := "      The connection to the server 10.20.0.50:6443 was refused - did you specify the right host or port?\n"
	if n := strings.Count(out.String(), refused); n != 1 || strings.Contains(out.String(), "E1028") {
		t.Errorf("printed the refusal %d times, want once without klog headers:\n%s", n, out)
	}
}

func TestShortError(t *testing.T) {
	te := &toolError{cmd: "kubectl get node x", err: errors.New("exit status 1"), stderr: "E1028 10:15:01.123456   12345 memcache.go:265] couldn't get current server API group list\n" +
		"E1028 10:15:02.000001   12345 memcache.go:265] again\n\n"}
	if got := shortError(te); got != "again" {
		t.Errorf("shortError = %q, want the last line without its klog header", got)
	}
	if got := shortError(&toolError{cmd: "kubectl get node x", err: errors.New("exit status 1")}); got != "kubectl get node x: exit status 1" {
		t.Errorf("shortError without stderr = %q", got)
	}
	if got := shortError(errors.New("plain")); got != "plain" {
		t.Errorf("shortError(plain) = %q", got)
	}
}

// A node someone else cordoned before the restart stays cordoned after it.
func TestRestartKeepsCordon(t *testing.T) {
	r, out, _, kc := restartFixture(t)
	kc.nodes["treasury-general-3"].cordoned = true
	o := restartOpts(kc, ModeReboot)
	o.Nodes = []string{"treasury-general-3"}
	if err := r.Restart(context.Background(), o); err != nil {
		t.Fatalf("Restart: %v\n%s", err, out)
	}
	if !kc.nodes["treasury-general-3"].cordoned {
		t.Error("uncordoned a node that was cordoned before")
	}
	for _, c := range kc.log {
		if strings.Contains(c, "cordon") {
			t.Errorf("ran %s", c)
		}
	}
}

// A node a failed run left cordoned carries restart's annotation, so the
// rerun takes the cordon for its own and uncordons the node at the end.
func TestRestartRerunUncordons(t *testing.T) {
	r, out, _, kc := restartFixture(t)
	n := kc.nodes["treasury-general-1"]
	n.cordoned, n.annotations = true, map[string]string{cordonAnnotation: "true"}
	o := restartOpts(kc, ModeReboot)
	o.Nodes = []string{"treasury-general-1"}
	if err := r.Restart(context.Background(), o); err != nil {
		t.Fatalf("Restart: %v\n%s", err, out)
	}
	if n.cordoned || n.annotations[cordonAnnotation] != "" {
		t.Errorf("rerun left cordoned %v, annotations %v", n.cordoned, n.annotations)
	}
	if !slices.Contains(kc.log, "kubectl uncordon treasury-general-1") {
		t.Error("rerun did not uncordon")
	}
}

// Cleanup deletes only the Failed pods a restart leaves on the node.
func TestOrphanReason(t *testing.T) {
	const node = "treasury-general-1"
	initCSU := failedPod("ns", "init", node, "")
	initCSU.Status.InitContainerStatuses = []containerStatus{{Name: "i", State: containerState{Terminated: &containerTerminated{Reason: "ContainerStatusUnknown"}}}}
	runningCSU := csuPod("ns", "sidecar-lost", node)
	runningCSU.Status.Phase = "Running"
	otherTerminated := failedPod("ns", "terminated-other", node, "Terminated")
	otherTerminated.Status.Message = "Pod was terminated by the job controller."
	otherDisruption := failedPod("ns", "evicted-by-api", node, "Terminated")
	otherDisruption.Status.Conditions = []condition{{Type: "DisruptionTarget", Status: "True", Reason: "EvictionByEvictionAPI"}}
	runningShutdown := shutdownPod(runningPod("ns", "still-running", node, nil), false)
	runningShutdown.Status.Phase = "Running"
	for _, tc := range []struct {
		pod  kubePod
		want string
	}{
		{shutdownPod(runningPod("kube-system", "op-message", node, nil), false), "Terminated"},
		{shutdownPod(runningPod("kube-system", "op-condition", node, nil), true), "Terminated"},
		{failedPod("kube-system", "op", node, "NodeShutdown"), "NodeShutdown"},
		{failedPod("ns", "ev", node, "Evicted"), "Evicted"},
		{csuPod("ns", "csu", node), "ContainerStatusUnknown"},
		{initCSU, "ContainerStatusUnknown"},
		{otherTerminated, ""},
		{otherDisruption, ""},
		{runningShutdown, ""},
		{failedPod("default", "job", node, "Error"), ""},
		{failedPod("default", "oom", node, "OOMKilled"), ""},
		{failedPod("kube-system", "other-node", "treasury-general-2", "NodeShutdown"), ""},
		{runningPod("ns", "running", node, nil), ""},
		{runningCSU, ""},
		{kubePod{Metadata: objectMeta{Name: "pending"}, Spec: podSpec{NodeName: node}, Status: podStatus{Phase: "Pending", Reason: "NodeShutdown"}}, ""},
		{kubePod{Metadata: objectMeta{Name: "done"}, Spec: podSpec{NodeName: node}, Status: podStatus{Phase: "Succeeded"}}, ""},
	} {
		if got := orphanReason(tc.pod, node); got != tc.want {
			t.Errorf("%s: orphanReason = %q, want %q", tc.pod.Metadata.Name, got, tc.want)
		}
	}
}

func TestRestartOptionsValidate(t *testing.T) {
	ok := RestartOptions{Mode: ModePowerCycle, Timeout: DefaultRestartTimeout, ShutdownTimeout: DefaultShutdownTimeout, RequireDaemonSets: DefaultRequiredDaemonSets}
	if err := ok.Validate(); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		edit func(*RestartOptions)
		want string
	}{
		{func(o *RestartOptions) { o.Mode = "halt" }, `mode "halt"`},
		{func(o *RestartOptions) { o.Timeout = 0 }, "timeout 0s"},
		{func(o *RestartOptions) { o.ShutdownTimeout = o.Timeout }, "less than the timeout"},
		{func(o *RestartOptions) { o.Nodes = []string{"a", "a"} }, "named twice"},
		{func(o *RestartOptions) { o.Nodes = []string{"../x"} }, "not a VM name"},
		{func(o *RestartOptions) { o.RequireDaemonSets = []string{"cilium"} }, "want namespace/name"},
	} {
		o := ok
		tc.edit(&o)
		if err := o.Validate(); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("Validate = %v, want %q", err, tc.want)
		}
	}
}

func TestWorkloadAvailable(t *testing.T) {
	w := workload("Deployment", "quay", "quay", 2)
	w.Status = workloadStatus{ObservedGeneration: 1, ReadyReplicas: 2, AvailableReplicas: 1}
	if ok, how := workloadAvailable(w); ok || how != "1/2 available" {
		t.Errorf("deployment with one available = %v %q", ok, how)
	}
	w.Status.AvailableReplicas = 2
	if ok, _ := workloadAvailable(w); !ok {
		t.Error("available deployment reads unavailable")
	}
	w.Metadata.Generation = 2
	if ok, _ := workloadAvailable(w); ok {
		t.Error("a change not yet observed reads available")
	}
	s := workload("StatefulSet", "keycloak", "keycloak", 1)
	s.Spec.Replicas = nil // defaults to one
	s.Status = workloadStatus{ObservedGeneration: 1, ReadyReplicas: 1}
	if ok, _ := workloadAvailable(s); !ok {
		t.Error("ready statefulset reads unavailable")
	}
}

var (
	_ Tools = (*fakeCluster)(nil)
	_ Tools = ExecTools{}
)
