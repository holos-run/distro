# Talos machine configuration

`talosvm` stops at VMs in Talos maintenance mode. This directory turns them
into a Kubernetes cluster with `talosctl` and the patches committed here, as
[ADR 0001](../../../docs/adr/0001-talos-cluster-profile.md) decided. There is
no program: `cluster.sh` is a thin wrapper that reads the node inventory from
`talosvm list -json` and runs `talosctl`.

The result is one control plane node and the workers, bootstrapped, with no
CNI and no kube-proxy. Every node stays `NotReady` until Cilium is installed,
and the control plane stays `NotReady` after that too: it is kept off the pod
network, as on GKE and EKS, and the API server reaches webhooks through the
ingress Gateway's LoadBalancer address on the LAN. Webhooks start permissive
and are switched to enforcing by a CUE flag once each answers through the
Gateway. ADR 0001 has the reasoning and the two provisioning steps.

## Patches

| File | Applies to | Sets |
| --- | --- | --- |
| [`patches/all.yaml`](patches/all.yaml) | every node | KubePrism on `127.0.0.1:7445`; sysctls for sandbox density and user namespaces |
| [`patches/controlplane.yaml`](patches/controlplane.yaml) | control plane | Flannel deleted, kube-proxy disabled, Talos's CoreDNS disabled; API server `runtime-config=certificates.k8s.io/v1beta1=true` and `enable-aggregator-routing=true`; node label `holos.run/pod-network: none` |
| [`clusters/<cluster>/controlplane.yaml`](clusters/treasury/controlplane.yaml) (rendered, committed) | the cluster's control plane | `StaticHostConfig`: every admission webhook hostname at the ingress Gateway's address |
| `nodes/<vm>.patch.yaml` (generated) | one node | `topology.kubernetes.io/region` and `zone`, and `holos.run/nodepool` on workers |

The sysctls:

| Sysctl | Value | Source |
| --- | --- | --- |
| `net.ipv4.neigh.default.gc_thresh1` | 4096 | Substrate's GKE node pool (`tools/setup-gcp/cmd/cluster.go`) |
| `net.ipv4.neigh.default.gc_thresh2` | 16384 | same |
| `net.ipv4.neigh.default.gc_thresh3` | 32768 | same |
| `fs.inotify.max_user_instances` | 65536 | same |
| `fs.inotify.max_user_watches` | 1048576 | same |
| `user.max_user_namespaces` | 11255 | Talos's user namespace test patch; Talos defaults it to 0 |

The node labels come from `talosvm list`: region is the Proxmox cluster
(`garage`), zone is the Proxmox node the VM was created on, and the pool is
the worker's `talosvm-pool-<name>` tag. A VM moved to another Proxmox node
keeps its old zone until `gen` and `apply` run again.

The patches in `patches/` name no cluster, node or address. `gen` adds the
rest:

- the cluster's own patch, `clusters/<cluster>/controlplane.yaml`, on the
  control plane (Webhook host entries, below);

- the cluster name and the endpoint `https://<control plane address>:6443`,
  with no VIP;
- the installer image `factory.talos.dev/nocloud-installer/<schematic>:v1.14.4`,
  where the schematic is read from the control plane node itself
  (`talosctl get extensions`), or taken from `INSTALLER` when set. It must
  be the schematic `talosvm create` printed, so the installed system keeps
  the extensions and the `nocloud` platform;
- Talos `v1.14` config and Kubernetes `1.37.1`, pinned in the script.

The machine config has no network section. The installed system is still the
`nocloud` platform, so it keeps reading the /32 address, the on-link default
route and MTU 8950 from the VM's cloud-init snippet on every boot, exactly as
in maintenance mode.

## Secrets and state

Everything `cluster.sh` writes lives outside the repository, in
`~/.config/holos/talos/<cluster>/` (or `$HOLOS_TALOS_DIR/<cluster>/`). The
script sets `umask 077`, so directories are 0700 and files 0600:

| File | What it is |
| --- | --- |
| `secrets.yaml` | `talosctl gen secrets`: the cluster CAs, tokens and keys. Generated once and reused, so regenerating configs keeps the cluster's identity. |
| `nodes.json` | The `talosvm list -json` inventory `gen` used. |
| `nodes/<vm>.yaml` | Each node's full machine config, which embeds secrets. |
| `nodes/<vm>.patch.yaml` | Each node's label patch. |
| `talosconfig` | Talos API client config, endpoint and node set to the control plane. |
| `kubeconfig` | Cluster admin kubeconfig. |

Back the directory up: without `secrets.yaml` and `talosconfig` the cluster
can no longer be administered.

## Usage

`talosctl` v1.14.4, `kubectl`, `jq` and Go are needed, and `gen` and
`apply` read the inventory with `talosvm list`, which needs the Proxmox
credentials and the snippets mount described in the provider README; without
the mount it leaves addresses blank and the script refuses. Install `talosctl`
from the Talos release, checking its checksum:

```sh
cd "$(mktemp -d)"
gh release download v1.14.4 -R siderolabs/talos -p talosctl-linux-amd64 -p sha256sum.txt
grep ' talosctl-linux-amd64$' sha256sum.txt | sha256sum -c -
install -m 0755 talosctl-linux-amd64 ~/.local/bin/talosctl
```

Then, from the repository root, with the Proxmox credentials loaded for
`talosvm list`:

```sh
set -a; . ~/.config/holos/proxmox.env; set +a

go run ./providers/proxmox/cmd/talosvm create -cluster treasury

# create returns once Proxmox has started the VMs, before Talos is up. Wait
# until every node answers in maintenance mode (under a minute on the garage).
# Only for new VMs: a configured node never answers --insecure, so the loop
# would wait forever on a cluster that is already up.
for a in $(go run ./providers/proxmox/cmd/talosvm list -cluster treasury -json | jq -r '.[].address'); do
  until talosctl get machinestatus -n "$a" --insecure >/dev/null 2>&1; do sleep 5; done
done

providers/proxmox/talos/cluster.sh up treasury

export TALOSCONFIG=~/.config/holos/talos/treasury/talosconfig
export KUBECONFIG=~/.config/holos/talos/treasury/kubeconfig
talosctl health
kubectl get nodes -o wide --show-labels
```

`up` is `gen`, `apply` and `bootstrap`, which also run alone:

- `gen` reads the inventory, generates `secrets.yaml` if it is missing, and
  writes every node's config. It refuses a cluster without exactly one
  control plane VM.
- `apply` sends each node its config: with `--insecure` to a node in
  maintenance mode, which installs Talos to `/dev/sda` and reboots, and over
  the authenticated API to a node that is already configured. A node that
  has not booted yet does not answer the insecure probe, so `apply` takes it
  for a configured node and the authenticated call fails, which is why the
  usage above waits for maintenance mode first; `gen` also reads the schematic from the control
  plane node over the same insecure API, unless `INSTALLER` is set.
- `bootstrap` waits for the control plane, bootstraps etcd (an etcd that is
  already bootstrapped is fine), and writes the kubeconfig once the API
  server answers.

All three can be rerun. To change the patches on a running cluster, edit
them, then `gen` and `apply`.

## Webhook host entries

The API server reaches every admission webhook at
`https://<service>.<namespace>.webhooks.<cluster>.<privateDomain>:9443`, on
the ingress Gateway's address (`holos/webhooks.cue`), or at a hostname the
webhook's entry sets instead, as approver-policy's
`cert-manager-approver-policy.cert-manager.svc`. The control plane
resolves those names from a `StaticHostConfig` document, the Talos 1.14 form
of `extraHostEntries`, so it does not depend on the router's
`*.bank.internal` record. Talos's host DNS, which the API server resolves
through, answers them itself.

The document is rendered from the platform's CUE (`holos/talos.cue`): every
hostname in the webhook registry, at `clusters.<cluster>.loadBalancer.gateway`.
Render it with every platform render and commit it:

```sh
cd holos
cue cmd talos   # writes providers/proxmox/talos/clusters/<cluster>/controlplane.yaml
git status ../providers/proxmox/talos/clusters
```

`gen` refuses a cluster without it. Only the control plane calls webhooks, so
the workers get no entries.

A webhook added to the registry, or a new gateway address, reaches a running
control plane only through `talosctl`, not Argo CD. `gen` and `apply` do it
like any other patch change, from scratch. Without the Proxmox credentials
`gen` needs, patch the control plane in place. Host entries apply without a
reboot; check that with a dry run first:

```sh
export TALOSCONFIG=~/.config/holos/talos/treasury/talosconfig
p=providers/proxmox/talos/clusters/treasury/controlplane.yaml
del=$'apiVersion: v1alpha1\nkind: StaticHostConfig\nname: 10.20.0.30\n$patch: delete'
talosctl -n 10.20.0.50 patch mc -p "$del" -p @$p --dry-run   # "without a reboot", and the diff
talosctl -n 10.20.0.50 patch mc -p "$del" -p @$p --mode no-reboot
talosctl -n 10.20.0.50 get statichosts
```

The delete comes first because a patch appends to `hostnames` rather than
replacing it: applied twice, the same file would list every name twice.
Deleting the document by its `name`, the address, and adding it again makes
the patch idempotent; a second run reports `no changes detected`. If the
address changed, delete the old one. Then bring the saved config in step, so
that a later `apply` without `gen` does not take the entries away:

```sh
c=~/.config/holos/talos/treasury/nodes/treasury-cp-1.yaml
talosctl machineconfig patch $c -p "$del" -p @$p --output $c
```

The kube-apiserver Pod's own `/etc/hosts` is the kubelet's copy and does not
list the entries; Talos's host DNS on `169.254.116.108` answers them, with
the authoritative flag and a 10-second TTL, where a forwarded name has
neither.

`talosctl health` passes without a CNI: it skips the node-ready, kube-proxy
and CoreDNS checks. Talos's own CoreDNS is disabled by the control plane
patch, so the cluster has no DNS until the platform's `cilium`,
`cilium-resources` and `coredns` components are applied; see
[holos/README.md](../../../holos/README.md).
