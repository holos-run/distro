# Control plane memory

Proxmox showed `treasury-cp-1`, then a control plane VM with 6 GiB, at 99.82%
memory used. The guest was not out of memory: about half of it is available.
This page says where the memory goes, which number answers which question,
what normal and alarming look like, and how the default size was chosen, so
the next person who sees 99.82% can check it in five minutes and the next
resize starts from measurements.

The measurements were taken on 2026-10-27 and 28 on `treasury` (one control
plane of 2 cores and 6144 MiB, three workers, Talos v1.14.4, Kubernetes 1.37,
about 50 pods and 50 CRDs, Argo CD reconciling 25 Applications every 30
seconds). The raw samples are one a minute for an hour; this page quotes the
ranges. Where a statement is an inference rather than something measured, it
says so.

## Where the memory goes

`talosctl memory` on the idle `treasury-cp-1`, in MiB:

| Total | Used | Free | Page cache | Available |
| --- | --- | --- | --- | --- |
| 5840 | 2250 to 2530 | 430 to 490 | 3030 to 3150 | 2890 to 3170 |

The guest sees 5840 of the VM's 6144 MiB; the rest is firmware and kernel
reservations. "Used" here excludes page cache, so it is the memory that
cannot be handed back. It is about 2.4 GiB, and the processes behind it are:

| What | Memory | Notes |
| --- | --- | --- |
| kube-apiserver, anonymous | 1.5 to 1.8 GiB (peak sampled 1.81) | The Go heap and stacks. The process RSS was 1.6 to 1.9 GiB. This is the one part that scales with the workload. |
| etcd, anonymous | about 80 MiB (one reading, not in the sample series) | The database is 35 MB on disk, 18 MB in use. The rest of its 370 to 430 MiB cgroup is page cache of that file. |
| kube-controller-manager | 80 to 100 MiB | |
| kube-scheduler | 25 to 30 MiB | |
| kubelet, apid, trustd, udevd, dashboard, init and the other Talos services | about 180 MiB | The `system` and `podruntime/kubelet` cgroups. |
| kernel (slab, page tables, stacks) | about 150 MiB | |

The page cache, about 3 GiB, is the other half of the 6 GiB, and the kernel
gives it back when anything else needs it:

| What | Page cache | Why |
| --- | --- | --- |
| kube-apiserver pod cgroup | 1.0 to 1.1 GiB | The audit log. Talos runs the API server with `--audit-log-maxsize=100 --audit-log-maxbackup=10`, so up to 1 GiB of rotated files plus the current one, and the pages the API server wrote stay charged to its cgroup until the kernel reclaims them. This is why the API server's pod cgroup reads 2.7 GiB while its process uses 1.7. |
| `podruntime/runtime` (containerd) | 1.3 GiB | Mostly image and layer cache (not split into anon and file in the samples). Constant. |
| etcd | 0.3 GiB | The database file. |

Everything the control plane runs is in three groups of cgroups, which is how
`talosctl cgroups` shows it: `kubepods` (the three static pods, capped by the
kubelet at 5.2 GiB, its cgroup limit), `podruntime` (etcd,
kubelet, containerd and the shims) and `system` (Talos's own services).

### What the API server spends its heap on

The control plane's one large and variable consumer is the API server. In an
hour of samples its anonymous memory moved between 1.5 and 1.8 GiB with no
trend (first-half and second-half means 1693 and 1670 MiB), as the Go heap
grew to its next GC target (1.25 to 1.7 GiB) and was collected. There is no
leak at this load, and the process had run 26 hours without a restart.

What it is not: the stored objects. The whole cluster's current state, as the
API returns it, is small: pods 0.7 MB, configmaps 0.3 MB, secrets 0.08 MB,
Applications 0.3 MB, 23 leases at 18 KB, and the 50 CRDs at 5 MB. The heap is
spent on serving that state to watchers, which is churn and fan-out:

- **About 6,900 goroutines**, about 730 of them open watches (the rest were not
  attributed).
- **Watch events.** Over 26 hours the API server received 517,000 lease events
  (about 6 a second, from the controllers that renew a leader election lease), 68,000 Application events (Argo CD rewrites each
  Application's status every 30 seconds, `timeout.reconciliation: 30s`), and
  37,000 configmap events. It then sent each to every watcher: 1.0 million
  lease events (501 MB) and 418,000 Application events, which at about 9 KB an
  Application is 3.8 GB, the most bytes of any resource.
- **Large LISTs.** The CRDs are 5 MB a LIST.
- **Discovery and OpenAPI**: 18,900 `/openapi/v3` requests in 26 hours.
- **The audit log**, which is I/O and page cache rather than heap: about 34
  events a second at the `Metadata` level, 100 MiB roughly every 40 minutes.

The requests come from the controllers the platform installs: leader election
leases from Cilium, ceph-csi, Istio, CloudNativePG, trust-manager, Keycloak,
holos-controller, kube-controller-manager and kube-scheduler; the Argo CD
application controller; kube-probe on `/readyz`; and the local-path
provisioner, which lists pods, PVCs and configmaps about once every 2.5
seconds. Attributing the heap to particular allocations needs a heap profile,
which was not available: see [Profiling](#profiling).

## Which number to trust

| Question | Look at | Why |
| --- | --- | --- |
| Is the node out of memory? | `talosctl memory`: AVAILABLE as a share of TOTAL. Also `/proc/pressure/memory`, `pswpout` and `oom_kill` in `/proc/vmstat`. | AVAILABLE is the kernel's estimate of what a new allocation can get without swapping, counting reclaimable cache. 3 GiB of 5.7 is healthy. |
| How much does the control plane really need? | `talosctl memory`: USED. | It excludes all page cache, so it is the working set. |
| Which process is using it? | `talosctl cgroups --preset memory`, reading anonymous memory when it matters (`memory.stat` `anon` and `file`). | The pod cgroup's current value includes file cache; anonymous is the process. |
| Is the API server growing? | The API server's `go_memstats_heap_inuse_bytes` and `process_resident_memory_bytes` from `kubectl get --raw /metrics`, over hours. | A single reading says nothing; it is a sawtooth. |
| How much can pods be scheduled? | `kubectl describe node`: Allocatable (5.1 GiB) against Requests (832 MiB on the control plane). | Requests are what pods ask for, not what the control plane's static pods use. |
| How much host memory does the VM hold? | Proxmox's `memhost`. | It is the QEMU process's resident memory on the hypervisor. |
| Is the VM using too much? | Not Proxmox's `mem`. | See below. |

### Why Proxmox says 99.82%

The Proxmox API reports `mem` 6,430,740,480 and `maxmem` 6,442,450,944 for VM
104, and that is the 99.82%. `status/current` returns `memhost` with the
identical value (6,430,912,512 on the second reading) and no `ballooninfo`. The
VM has `balloon: 0` and the guest agent enabled. The conclusion this supports
is that with ballooning off, Proxmox has no memory statistics from inside the
guest, and `mem` is the amount of the VM's memory the host has backed with
pages, which the QEMU process holds resident. The guest agent does not feed
it. (Reading the agent itself was not possible with the provider's token,
which lacks `VM.GuestAgent.Audit`, so this is shown by the API's two fields
being identical, not by querying the agent.)

A guest touches a page the first time it uses it, including for page cache,
and, with no balloon driver (and, we infer, no free page reporting), is not expected to give it back to
the host. The VM's day graph is consistent with that: 5.2 GB, then 6.4 GB in the
first hours, flat since. The three workers, 8 GiB at the time, showed 99.96 to 99.98%
for the same reason. The figure measures how much of the VM the guest has ever
touched, which for any long-running Linux guest tends to 100%, and says
nothing about pressure. Do not alert on it and do not size from it. Pressure shows in the guest, as
`oom_kill` or PSI above zero.

(The CPU figure Proxmox shows is real: 17 to 50% of two cores. The API server
used the most CPU of anything on the node, and I/O pressure is the audit log
and etcd: PSI `io` some about 8%, `cpu` some about 5%.)

## What normal and alarming look like

On a control plane with this workload (one node, 25 Applications, 50 pods):

| Reading | Normal | Look into it |
| --- | --- | --- |
| `talosctl memory` USED | 2.2 to 2.6 GiB, level | More than 2.8 GiB (where the sizing rule below stops holding), or climbing over days |
| AVAILABLE | 2.9 to 3.2 GiB (about 50%) | Under 1.5 GiB (25%) |
| Page cache | about 3 GiB | Falling toward 0 with AVAILABLE low: the cache is being squeezed |
| API server anonymous | 1.5 to 1.8 GiB, sawtooth | A floor that rises hour over hour, or over 3 GiB |
| `allocstall_*`, `pswpout`, `oom_kill` in `/proc/vmstat` | 0 | Any increase |
| `/proc/pressure/memory` | `some` 0.00 | `some` avg60 above 1%, any `full` |
| `kubepods` cgroup | 2.7 to 3.0 GiB (peak since boot 3.1) | Approaching its limit of 5.2 GiB |
| Goroutines | about 6,900, flat | Rising: a client is leaking watches |

Proxmox's `mem` at 99% and the API server pod at 2.7 GiB are both normal
here, for the reasons above.

## Sizing rule

Size the control plane so that its USED, at its observed peak, is no more than
about half of the guest's memory, and keep at least a gigabyte of page cache
for the audit log, etcd and containerd. Concretely: VM memory is at least
twice the peak USED plus the 300 MiB the guest does not see, rounded up to a
whole GiB.

For `treasury`: peak USED 2.47 GiB (2528 MiB); 2 x 2528 + 304 = 5360 MiB, so
6 GiB. At that size the node has 2.3 times
its peak working set before the kernel has to reclaim everything it can, and
the API server's pod, at its peak since boot (3.0 GiB, which includes its
start-up LISTs and the audit cache), has 2.2 GiB of room under the kubelet's
5.2 GiB `kubepods` cgroup limit.

The default is 8192 MiB, one step above what the rule gives today. The
rule sizes for an idle cluster, and the next workloads, Substrate, kagent
and their controllers, add the watches that grow the API server's heap
(below). `treasury-cp-1` already runs with 8 GiB, so the default now
matches the cluster rather than asking a rebuild to shrink it.

The reasoning, and what would change it:

- The working set is dominated by the API server's Go heap, and the heap
  follows the number of watches, the rate of watch events and the size of
  LISTs, not the count of objects. Adding controllers that run leader
  election, or Applications, or large CRDs, raises it; adding pods with no
  new watchers barely does.
- The measurement is of an idle cluster with Argo CD's 30 second reconcile.
  A merge to `main` that changes many Applications was not sampled (none
  happened in the window), nor was an API server restart, whose start-up
  LISTs are inside the 3.0 GiB peak since boot but not isolated.
- The next large sources of watches are Substrate, kagent and their
  controllers. Re-measure after they are installed, with the sampling in this
  page, before they ship. At 8 GiB the rule holds while peak USED stays
  under about 3.9 GiB; raise the default again past that, or if the API
  server's anonymous memory floor keeps rising. Ballooning stays off, so the
  memory is reserved on the host, which has 251 GiB on `r620a`; the host is
  not the constraint.
- A bigger VM does not reduce CPU use. The cores are 17 to 50% busy because
  the API server spends them on the same churn; adding memory would not change
  that.

### Resizing a running control plane

Changing the default in the provider changes new VMs only. Resizing the
running `treasury-cp-1` means changing `memory` on the VM in Proxmox, which
`talosvm resize` does from the config, and then stopping and starting the
VM, because the VM has no memory hotplug configured; a reboot inside the
guest (`talosctl reboot`) keeps the running QEMU process and its old memory.
`talosvm restart` does that, and waits for the node to come back
([Resizing a pool](../README.md#resizing-a-pool),
[Restarting nodes](../README.md#restarting-nodes)):

```sh
go run ./providers/talos/cmd/talosvm resize  -cluster treasury -nodes treasury-cp-1
go run ./providers/talos/cmd/talosvm restart -cluster treasury -mode power-cycle -nodes treasury-cp-1
```

`-nodes` keeps `resize` to the control plane; without it, `resize` sets
every VM to the config's size, workers included. Pass the `-config` and
`-workers` the cluster was made with, if any; without them `resize` skips
workers beyond the config's count, and it refuses to shrink a VM unless
given `-shrink`.

With one control plane the Kubernetes API is down until it is back. Prefer
to leave it until the next rebuild, as with the move to 6 GiB. A worker's
memory is changed the same way, with `-nodes` naming it, or without
`-nodes` for every worker in turn.

## Reading it yourself

All of this is read-only.

```sh
export TALOSCONFIG=~/.config/holos/talos/treasury/talosconfig
export KUBECONFIG=~/.config/holos/talos/treasury/kubeconfig
CP=10.20.0.50

# The guest's view: TOTAL, USED (no cache), CACHE, AVAILABLE.
talosctl -n $CP memory

# Memory by cgroup. MemCurrent includes page cache.
talosctl -n $CP cgroups --preset memory

# Anonymous memory against file cache for the API server's pod cgroup.
talosctl -n $CP read /sys/fs/cgroup/kubepods/burstable/pod<hash>/memory.stat | grep -E '^(anon|file) '

# Pressure and the reclaim counters that matter.
talosctl -n $CP read /proc/pressure/memory
talosctl -n $CP read /proc/vmstat | grep -E '^(allocstall|pswp|oom_kill)'

# The API server's own Go heap, goroutines and watch cache traffic.
kubectl get --raw /metrics | grep -E '^(go_memstats_(heap_inuse|heap_alloc|next_gc)_bytes|process_resident_memory_bytes|go_goroutines|apiserver_watch_cache_events_received_total|apiserver_watch_events_total)'
```

`pod<hash>` is a directory named by the pod's config hash, not its UID. Run
`talosctl ls /sys/fs/cgroup/kubepods/burstable` and take the one with the
largest `memory.current`;
the `kube-apiserver` container's cgroup has no `memory.stat` of its own on
Talos, the pod's has.

And Proxmox, with the token and CA from [Credentials and the CA](../../proxmox/README.md#credentials-and-the-ca):

```sh
set -a; . ~/.config/holos/proxmox.env; set +a
curl -s --cacert ~/.config/holos/pve-root-ca.pem \
  -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN_ID=$PROXMOX_TOKEN_SECRET" \
  "$PROXMOX_URL/api2/json/nodes/r620a/qemu/104/status/current"
# mem equals memhost: the host-resident size, not the guest's use.
```

To record a series, loop the first four commands once a minute. The hour of
samples behind this page is in the Planboard project that produced it
(`Agent_Substrate_Day_MVP/files/control-plane-memory-samples.md`).

## Profiling

The API server runs with `--profiling=false`, Talos's generated default, so
there is no `/debug/pprof` and the heap cannot be attributed to allocations.
To turn it on, add `profiling: "true"` to the `extraArgs` of the
`KubeAPIServerConfig` document in
[`patches/controlplane.yaml`](../patches/controlplane.yaml) and
apply it with `talosctl patch machineconfig`; the API server's static pod
restarts, so the API is down for a few seconds and its heap starts again.
Then, as a cluster admin, `kubectl get --raw /debug/pprof/heap > heap.pb.gz`
and `go tool pprof -sample_index=inuse_space`. The endpoint is served only to
authenticated users with access to `/debug/*`, but it exposes internals and
costs CPU while profiling, so turn it off again afterward. The patch does not
enable it today.
