#!/usr/bin/env bash
# cluster.sh turns the VMs talosvm made for a cluster into a Talos Kubernetes
# cluster with talosctl and the patches beside this script.
#
#   cluster.sh gen       <cluster>   secrets (once), then every node's config
#   cluster.sh apply     <cluster>   apply each node's config
#   cluster.sh bootstrap <cluster>   bootstrap etcd, write kubeconfig
#   cluster.sh up        <cluster>   gen, apply, bootstrap
#
# The patches in patches/ are the same for every cluster. Those in
# clusters/<cluster>/ are the cluster's own, rendered from holos/talos.cue.
#
# Secrets, machine configs, talosconfig and kubeconfig live outside the
# repository in $HOLOS_TALOS_DIR/<cluster> (default ~/.config/holos/talos),
# directories 0700 and files 0600. Nothing this script writes goes in git.
#
# The node inventory comes from `talosvm list -json`, so the Proxmox
# credentials must be in the environment, as for talosvm itself.
set -euo pipefail

TALOS_VERSION=v1.14.4
KUBERNETES_VERSION=1.37.1
POOL_LABEL=holos.run/nodepool

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
patches=$here/patches

die() { echo "cluster.sh: $*" >&2; exit 1; }
log() { echo "cluster.sh: $*" >&2; }

[[ $# -eq 2 ]] || die "usage: cluster.sh gen|apply|bootstrap|up <cluster>"
cmd=$1 cluster=$2
[[ $cluster =~ ^[a-z][a-z0-9-]{0,30}$ ]] || die "invalid cluster name: $cluster"

for tool in talosctl jq go kubectl; do
  command -v "$tool" >/dev/null || die "$tool not found in PATH"
done
have=$(talosctl version --client --short 2>/dev/null | awk '/Talos/ {print $2}')
[[ $have == "$TALOS_VERSION" ]] || die "talosctl is ${have:-unknown}, want $TALOS_VERSION"

umask 077
state=${HOLOS_TALOS_DIR:-$HOME/.config/holos/talos}/$cluster
mkdir -p "$state/nodes"
chmod 0700 "$state" "$state/nodes"
export TALOSCONFIG=$state/talosconfig

# list writes the cluster's VMs as talosvm sees them now to $1, and refuses
# an inventory this script cannot build a cluster from: an address talosvm
# left blank (it does when it cannot read the snippets mount), an unknown
# role, or anything but one control plane and at least one worker.
list() {
  (cd "$repo" && go run ./providers/talos/cmd/talosvm list -cluster "$cluster" -json) >"$1"
  jq -e 'all(.[]; (.address | type == "string" and length > 0)
                  and (.role == "controlplane" or .role == "worker"))' "$1" >/dev/null ||
    die "talosvm list gave a VM with no address or an unknown role; is the snippets directory mounted?"
  [[ $(jq '[.[] | select(.role == "controlplane")] | length' "$1") -eq 1 ]] ||
    die "want exactly one control plane VM in cluster $cluster"
  [[ $(jq '[.[] | select(.role == "worker")] | length' "$1") -ge 1 ]] ||
    die "want at least one worker VM in cluster $cluster"
}

# inventory refuses to go on without the inventory gen wrote.
inventory() {
  [[ -s $state/nodes.json ]] || die "no inventory; run: cluster.sh gen $cluster"
}

# nodes writes the cluster's VMs, one JSON object per line. Callers run
# inventory first: a die in here runs in a subshell and would not stop them.
nodes() {
  jq -c '.[]' "$state/nodes.json"
}

controlplane() {
  jq -r '[.[] | select(.role == "controlplane")][0].address' "$state/nodes.json"
}

# installer prints the installer image, from $INSTALLER or else from the
# schematic the control plane node booted with, so the installed system keeps
# the extensions and the nocloud platform.
installer() {
  if [[ -n ${INSTALLER:-} ]]; then echo "$INSTALLER"; return; fi
  local cp id
  cp=$(controlplane)
  id=$(talosctl get extensions -n "$cp" --insecure -o json 2>/dev/null |
    jq -r 'select(.spec.metadata.name == "schematic") | .spec.metadata.version' || true)
  if [[ -z $id && -s $TALOSCONFIG ]]; then
    id=$(talosctl get extensions -n "$cp" -e "$cp" -o json 2>/dev/null |
      jq -r 'select(.spec.metadata.name == "schematic") | .spec.metadata.version' || true)
  fi
  [[ $id =~ ^[0-9a-f]{64}$ ]] || die "cannot read the schematic from $cp; set INSTALLER to the image talosvm create printed"
  echo "factory.talos.dev/nocloud-installer/$id:$TALOS_VERSION"
}

gen() {
  # The cluster's own patches, rendered from the platform's CUE (holos/talos.cue)
  # by `cue cmd talos` and committed: the API server's webhook host entries.
  local rendered=$here/clusters/$cluster/controlplane.yaml
  [[ -s $rendered ]] || die "no $rendered; run cue cmd talos in holos/"

  list "$state/nodes.json.tmp"
  mv "$state/nodes.json.tmp" "$state/nodes.json"

  if [[ ! -s $state/secrets.yaml ]]; then
    log "generating secrets in $state/secrets.yaml"
    talosctl gen secrets -o "$state/secrets.yaml"
  fi

  local cp image base
  cp=$(controlplane)
  image=$(installer)
  log "endpoint https://$cp:6443, installer $image"
  base=$(mktemp -d "$state/gen.XXXXXX")
  trap 'rm -rf "$base"' RETURN
  talosctl gen config "$cluster" "https://$cp:6443" \
    --with-secrets "$state/secrets.yaml" \
    --talos-version "${TALOS_VERSION%.*}" \
    --kubernetes-version "$KUBERNETES_VERSION" \
    --install-image "$image" \
    --config-patch "@$patches/all.yaml" \
    --config-patch-control-plane "@$patches/controlplane.yaml" \
    --config-patch-control-plane "@$rendered" \
    --output "$base" --force >/dev/null

  talosctl --talosconfig "$base/talosconfig" config endpoint "$cp"
  talosctl --talosconfig "$base/talosconfig" config node "$cp"
  mv "$base/talosconfig" "$TALOSCONFIG"

  local node name role
  while read -r node; do
    name=$(jq -r .name <<<"$node")
    role=$(jq -r .role <<<"$node")
    # Standard topology labels: region is the Proxmox cluster, zone the
    # Proxmox node the VM runs on. Workers also carry their pool.
    jq -r --arg pool "$POOL_LABEL" '
      "apiVersion: v1alpha1",
      "kind: KubeNodeConfig",
      "labels:",
      "  topology.kubernetes.io/region: \(.region | @json)",
      "  topology.kubernetes.io/zone: \(.zone | @json)",
      (if .pool then "  \($pool): \(.pool | @json)" else empty end)' <<<"$node" >"$state/nodes/$name.patch.yaml"
    talosctl machineconfig patch "$base/$role.yaml" \
      --patch "@$state/nodes/$name.patch.yaml" \
      --output "$state/nodes/$name.yaml"
    talosctl validate --mode cloud --config "$state/nodes/$name.yaml" >/dev/null
    log "wrote $state/nodes/$name.yaml"
  done < <(nodes)
}

apply() {
  inventory
  # The first apply goes to nodes in maintenance mode without credentials,
  # carrying the cluster's CA keys, so the configs go only to the VMs this
  # cluster has now. An inventory that has drifted since gen, such as another
  # cluster's VMs now holding these addresses, is refused.
  local now
  now=$(mktemp "$state/now.XXXXXX")
  list "$now"
  if ! diff -q <(jq -S '[.[] | {name, address}] | sort_by(.name)' "$state/nodes.json") \
      <(jq -S '[.[] | {name, address}] | sort_by(.name)' "$now") >/dev/null; then
    rm -f "$now"
    die "cluster $cluster's VMs changed since gen; run: cluster.sh gen $cluster"
  fi
  rm -f "$now"
  local node name addr
  while read -r node; do
    name=$(jq -r .name <<<"$node")
    addr=$(jq -r .address <<<"$node")
    [[ -s $state/nodes/$name.yaml ]] || die "no config for $name; run: cluster.sh gen $cluster"
    # A node in maintenance mode answers without credentials and installs
    # Talos to disk on apply; a configured node takes the update in place.
    if talosctl get machinestatus -n "$addr" --insecure >/dev/null 2>&1; then
      log "$name ($addr): maintenance mode, installing"
      talosctl apply-config -n "$addr" --insecure --file "$state/nodes/$name.yaml"
    else
      log "$name ($addr): configured, applying"
      talosctl apply-config -n "$addr" -e "$addr" --file "$state/nodes/$name.yaml"
    fi
  done < <(nodes)
}

bootstrap() {
  inventory
  local cp i
  cp=$(controlplane)
  log "waiting for the Talos API on $cp"
  for i in $(seq 120); do
    talosctl version -n "$cp" >/dev/null 2>&1 && break
    [[ $i -lt 120 ]] || die "Talos API on $cp did not come up"
    sleep 5
  done
  # The API answers while Talos is still installing and rebooting, and
  # bootstrap says "not available yet" until etcd waits for it. It refuses a
  # second time with AlreadyExists, which is success here.
  local out
  for i in $(seq 120); do
    if out=$(talosctl bootstrap -n "$cp" 2>&1); then break; fi
    if grep -q AlreadyExists <<<"$out"; then log "etcd already bootstrapped"; break; fi
    grep -qE 'not available yet|Unavailable|connection refused|deadline' <<<"$out" || die "bootstrap: $out"
    [[ $i -lt 120 ]] || die "bootstrap: $out"
    sleep 5
  done
  log "waiting for the Kubernetes API on $cp"
  for i in $(seq 120); do
    talosctl kubeconfig "$state/kubeconfig" -n "$cp" --force >/dev/null 2>&1 &&
      kubectl --kubeconfig "$state/kubeconfig" get --raw /readyz >/dev/null 2>&1 && break
    [[ $i -lt 120 ]] || die "Kubernetes API on $cp did not come up"
    sleep 5
  done
  chmod 0600 "$state/kubeconfig"
  log "export TALOSCONFIG=$TALOSCONFIG KUBECONFIG=$state/kubeconfig"
}

case $cmd in
  gen) gen ;;
  apply) apply ;;
  bootstrap) bootstrap ;;
  up) gen; apply; bootstrap ;;
  *) die "unknown command: $cmd" ;;
esac
