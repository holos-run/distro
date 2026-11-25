#!/usr/bin/env bash
# cluster.sh turns the VMs talosvm made for a cluster into a Talos Kubernetes
# cluster with talosctl and the patches beside this script.
#
#   cluster.sh gen       <cluster>   secrets (once), then every node's config
#   cluster.sh apply     <cluster>   apply each node's config
#   cluster.sh bootstrap <cluster>   bootstrap etcd, write kubeconfig
#   cluster.sh labels    <cluster>   set each pool's adminLabels on its nodes
#   cluster.sh up        <cluster>   gen, apply, bootstrap, labels
#
# The cluster's Talos version is talosVersion in its committed
# clusters/<cluster>/talosvm.json, for the client check, the machine configs
# and the installer tag. The client is $TALOSCTL when it is set, else
# talosctl-<version> on PATH, else talosctl, and it must be that version;
# the refusal prints how to install it.
#
# The same file may set endpoint, a DNS name the cluster's Kubernetes endpoint
# uses in place of the control plane's address, and kubernetesVersion, in
# place of KUBERNETES_VERSION below. talosctl uses the address either way.
# A pool there may set taints and labels, which gen writes into its nodes'
# configs, and adminLabels, which labels sets with the admin kubeconfig.
#
# The patches in patches/ are the same for every cluster. A cluster that
# needs a patch of its own puts it in clusters/<cluster>/controlplane.yaml;
# none does today.
#
# Secrets, machine configs, talosconfig and kubeconfig live outside the
# repository in $HOLOS_TALOS_DIR/<cluster> (default ~/.config/holos/talos),
# directories 0700 and files 0600. Nothing this script writes goes in git.
#
# The node inventory comes from `talosvm list -json`, so the Proxmox
# credentials must be in the environment, as for talosvm itself.
set -euo pipefail

KUBERNETES_VERSION=1.37.1
POOL_LABEL=holos.run/nodepool

# What endpoint, kubernetesVersion and a pool's taints and labels may be: the
# patterns in config.go, whose test finds them here.
ENDPOINT_PATTERN='\A([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?\z'
KUBERNETES_VERSION_PATTERN='\A[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?\z'
POOL_NAME_PATTERN='\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z'
POOL_TAINT_PATTERN='\A([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*/)?[A-Za-z0-9]([A-Za-z0-9_.-]{0,61}[A-Za-z0-9])?(=([A-Za-z0-9]([A-Za-z0-9_.-]{0,61}[A-Za-z0-9])?)?)?:(NoSchedule|PreferNoSchedule|NoExecute)\z'
POOL_LABEL_PATTERN='\A([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*/)?[A-Za-z0-9]([A-Za-z0-9_.-]{0,61}[A-Za-z0-9])?(=([A-Za-z0-9]([A-Za-z0-9_.-]{0,61}[A-Za-z0-9])?)?)?\z'
RESERVED_LABEL_PATTERN='\A([a-z0-9.-]+\.)?(kubernetes|k8s)\.io/'
KUBELET_LABEL_PATTERN='\A([a-z0-9.-]+\.)?(node|kubelet)\.kubernetes\.io/'
ADMIN_LABEL_PATTERN='\A([a-z0-9.-]+\.)?node-restriction\.kubernetes\.io/'

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
patches=$here/patches

die() { echo "cluster.sh: $*" >&2; exit 1; }
log() { echo "cluster.sh: $*" >&2; }

[[ $# -eq 2 ]] || die "usage: cluster.sh gen|apply|bootstrap|labels|up <cluster>"
cmd=$1 cluster=$2
[[ $cluster =~ ^[a-z][a-z0-9-]{0,30}$ ]] || die "invalid cluster name: $cluster"

for tool in jq go kubectl; do
  command -v "$tool" >/dev/null || die "$tool not found in PATH"
done

config=$here/clusters/$cluster/talosvm.json
[[ -f $config ]] || die "no config for cluster $cluster: $config does not exist"
TALOS_VERSION=$(jq -r '.talosVersion // empty' "$config") || die "cannot read talosVersion from $config"
[[ -n $TALOS_VERSION ]] || die "$config sets no talosVersion"

# Go matches keys in any case and jq does not, so talosvm would take Endpoint
# for endpoint while gen built the cluster on its address, and Pools for pools
# while gen left their taints out. Go folds two letters that are not ASCII too.
miscased=$(jq -r 'keys[]
  | select(ascii_downcase | gsub("\u017f"; "s") | gsub("\u212a"; "k") | IN("endpoint", "kubernetesversion", "pools"))
  | select(IN("endpoint", "kubernetesVersion", "pools") | not)' "$config") || die "cannot read the keys of $config"
[[ -z $miscased ]] || die "$config: key $miscased: want endpoint, kubernetesVersion or pools, in that case"

# optional prints the config's field $1, or nothing when the file leaves it
# out or sets it to null, and fails when it is not a string matching $2. The
# check is jq's, on the string the file holds: \A and \z see a trailing
# newline, which the shell would drop.
optional() {
  jq -r --arg field "$1" --arg pattern "$2" '.[$field] |
    if . == null then empty
    elif type == "string" and length <= 253 and test($pattern) then .
    else "" | halt_error(1) end' "$config"
}
ENDPOINT=$(optional endpoint "$ENDPOINT_PATTERN") ||
  die "$config: endpoint $(jq -c .endpoint "$config"): want a lowercase DNS name alone, such as api.example.internal, with no scheme, port or trailing dot"
version=$(optional kubernetesVersion "$KUBERNETES_VERSION_PATTERN") ||
  die "$config: kubernetesVersion $(jq -c .kubernetesVersion "$config"): want a release such as $KUBERNETES_VERSION, without a leading v"
KUBERNETES_VERSION=${version:-$KUBERNETES_VERSION}

# POOLS is each pool's count, taints, labels and adminLabels, by pool name, or
# the script ends with what is wrong with one. A pool's keys are named in full
# for the reason above: a Taints that only talosvm took would leave the pool
# untainted.
POOLS=$(jq -c --arg namere "$POOL_NAME_PATTERN" --arg taintre "$POOL_TAINT_PATTERN" --arg labelre "$POOL_LABEL_PATTERN" --arg nodepool "$POOL_LABEL" \
  --arg reserved "$RESERVED_LABEL_PATTERN" --arg kubelet "$KUBELET_LABEL_PATTERN" --arg admin "$ADMIN_LABEL_PATTERN" '
  def refuse: halt_error(1);
  def list($where; $field; $pattern; $want; why): "\($where).\($field)" as $at
    | .[$field]
    | if . == null then [] elif type == "array" then . else "\($at): want a list" | refuse end
    | to_entries | map("\($at)[\(.key)] \(.value | tojson)" as $at | .value
      | if type == "string" and length <= 253 and test($pattern) then . else "\($at): \($want)" | refuse end
      | (if $field == "taints" then .[:rindex(":")] else . end | split("=")) as $kv
      | {key: $kv[0], value: ($kv[1] // "")} + (if $field == "taints" then {effect: .[rindex(":") + 1:]} else {} end)
      | (.key | why) as $why | if $why == null then . else "\($at): \($why)" | refuse end)
    | if (unique_by([.key, .effect]) | length) == length then . else "\($at): one is given twice" | refuse end;
  .pools
  | if . == null then [] elif type == "array" then . else "pools: want a list" | refuse end
  | to_entries | map("pools[\(.key)]" as $at | .value
    | if type == "object" and (.name | type) == "string" then . else "\($at): want a pool with a name" | refuse end
    | if (.name | length <= 20 and test($namere)) and .name != "cp" then . else "\($at).name \(.name | tojson): want a lowercase DNS label of at most 20 characters that is not cp" | refuse end
    | if .count == null or ((.count | type) == "number" and .count >= 0 and .count == (.count | floor)) then . else "\($at).count \(.count | tojson): want zero or more" | refuse end
    | (keys - ["name", "count", "cores", "memoryMiB", "diskGiB", "nodes", "addresses", "taints", "labels", "adminLabels"]) as $unknown
    | if $unknown == [] then . else "\($at): unknown key \($unknown[0])" | refuse end
    | {key: .name, value: {
        count: (.count // 0),
        taints: list($at; "taints"; $taintre; "want a taint such as example.com/key=value:NoSchedule"; null),
        labels: list($at; "labels"; $labelre; "want a label such as example.com/key=value";
          if . == $nodepool then "cluster.sh sets this label"
          elif test($admin) then "a node may not set this label on itself; put it in adminLabels"
          elif test($reserved) and (test($kubelet) | not) then "Kubernetes keeps this label for itself"
          else null end),
        adminLabels: list($at; "adminLabels"; $labelre; "want a label such as node-restriction.kubernetes.io/key=value";
          if test($admin) then null
          else "want a node-restriction.kubernetes.io/ label, since a node can set any other on itself" end)}})
  | if (unique_by(.key) | length) == length then from_entries else "pools: a name is used twice" | refuse end' \
  "$config" 2>&1) || die "$config: $POOLS"

if [[ -z ${TALOSCTL:-} ]]; then
  TALOSCTL=talosctl
  if command -v "talosctl-$TALOS_VERSION" >/dev/null; then TALOSCTL=talosctl-$TALOS_VERSION; fi
fi
# A client that is missing or fails leaves have empty, and the refusal below
# reports it, so the failure must not end the script here under set -e.
have=$("$TALOSCTL" version --client --short 2>/dev/null | awk '/Talos/ {print $2}') || have=
if [[ $have != "$TALOS_VERSION" ]]; then
  log "$TALOSCTL is ${have:-unknown}, want $TALOS_VERSION; to install it:"
  asset=talosctl-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
  cat >&2 <<EOF

cd "\$(mktemp -d)"
gh release download $TALOS_VERSION -R siderolabs/talos -p $asset -p sha256sum.txt
grep ' $asset\$' sha256sum.txt | shasum -a 256 -c -
mkdir -p ~/.local/bin
install -m 0755 $asset ~/.local/bin/talosctl-$TALOS_VERSION
EOF
  exit 1
fi

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

# pooled refuses the inventory $1 when it has a worker in no pool of the config,
# as it does when the config is another checkout's: the node would register
# without its pool's taints, and it cannot be given them afterwards. A config
# without pools has talosvm's default pool, which sets nothing.
pooled() {
  local stray
  stray=$(jq -r --argjson pools "$POOLS" '[.[] | select($pools != {} and .role == "worker" and ($pools[.pool // ""] == null))
    | "\(.name) (\(.pool // "none"))"] | join(", ")' "$1")
  [[ -z $stray ]] || die "workers whose pool $config does not have: $stray"
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
  id=$("$TALOSCTL" get extensions -n "$cp" --insecure -o json 2>/dev/null |
    jq -r 'select(.spec.metadata.name == "schematic") | .spec.metadata.version' || true)
  if [[ -z $id && -s $TALOSCONFIG ]]; then
    id=$("$TALOSCTL" get extensions -n "$cp" -e "$cp" -o json 2>/dev/null |
      jq -r 'select(.spec.metadata.name == "schematic") | .spec.metadata.version' || true)
  fi
  [[ $id =~ ^[0-9a-f]{64}$ ]] || die "cannot read the schematic from $cp; set INSTALLER to the image talosvm create printed"
  echo "factory.talos.dev/nocloud-installer/$id:$TALOS_VERSION"
}

gen() {
  # The cluster's own control plane patch, if it has one, committed beside
  # the shared patches. The platform's CUE writes nothing here: the base does
  # not reach into the Kubernetes layer (ADR 0003). The array expands with +
  # so that an empty one passes set -u in bash 3.2 too.
  local own=$here/clusters/$cluster/controlplane.yaml
  local -a own_patch=()
  if [[ -e $own ]]; then
    [[ -s $own ]] || die "$own is empty"
    own_patch=(--config-patch-control-plane "@$own")
  fi

  list "$state/nodes.json.tmp"
  pooled "$state/nodes.json.tmp"
  mv "$state/nodes.json.tmp" "$state/nodes.json"

  if [[ ! -s $state/secrets.yaml ]]; then
    log "generating secrets in $state/secrets.yaml"
    "$TALOSCTL" gen secrets -o "$state/secrets.yaml"
  fi

  local cp endpoint image base
  cp=$(controlplane)
  endpoint=https://${ENDPOINT:-$cp}:6443
  image=$(installer)
  log "endpoint $endpoint, Kubernetes $KUBERNETES_VERSION, installer $image"
  base=$(mktemp -d "$state/gen.XXXXXX")
  trap 'rm -rf "$base"' RETURN
  "$TALOSCTL" gen config "$cluster" "$endpoint" \
    --with-secrets "$state/secrets.yaml" \
    --talos-version "${TALOS_VERSION%.*}" \
    --kubernetes-version "$KUBERNETES_VERSION" \
    --install-image "$image" \
    --config-patch "@$patches/all.yaml" \
    --config-patch-control-plane "@$patches/controlplane.yaml" \
    ${own_patch[@]+"${own_patch[@]}"} \
    --output "$base" --force >/dev/null

  # talosctl stays on the address, so it works when the endpoint's name does
  # not resolve.
  "$TALOSCTL" --talosconfig "$base/talosconfig" config endpoint "$cp"
  "$TALOSCTL" --talosconfig "$base/talosconfig" config node "$cp"
  mv "$base/talosconfig" "$TALOSCONFIG"

  local node name role
  while read -r node; do
    name=$(jq -r .name <<<"$node")
    role=$(jq -r .role <<<"$node")
    # Standard topology labels: region is the Proxmox cluster, zone the
    # Proxmox node the VM runs on. Workers also carry their pool and what it
    # sets. A taint goes in the kubelet configuration, as registerWithTaints:
    # a KubeNodeConfig taint would also have Talos keep it up with the node's
    # own credentials, which may not change the node's taints.
    jq -r --arg pool "$POOL_LABEL" --argjson pools "$POOLS" '
      ((.pool | values | $pools[.]) // {labels: [], taints: []}) as $set |
      "apiVersion: v1alpha1",
      "kind: KubeNodeConfig",
      "labels:",
      "  topology.kubernetes.io/region: \(.region | @json)",
      "  topology.kubernetes.io/zone: \(.zone | @json)",
      (if .pool then "  \($pool): \(.pool | @json)" else empty end),
      ($set.labels[] | "  \(.key | @json): \(.value | @json)"),
      (if $set.taints == [] then empty else
        "---",
        "apiVersion: v1alpha1",
        "kind: KubeletConfig",
        "config:",
        "  registerWithTaints:",
        ($set.taints[] |
          "    - key: \(.key | @json)",
          "      value: \(.value | @json)",
          "      effect: \(.effect | @json)")
      end)' <<<"$node" >"$state/nodes/$name.patch.yaml"
    "$TALOSCTL" machineconfig patch "$base/$role.yaml" \
      --patch "@$state/nodes/$name.patch.yaml" \
      --output "$state/nodes/$name.yaml"
    "$TALOSCTL" validate --mode cloud --config "$state/nodes/$name.yaml" >/dev/null
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
    if "$TALOSCTL" get machinestatus -n "$addr" --insecure >/dev/null 2>&1; then
      log "$name ($addr): maintenance mode, installing"
      "$TALOSCTL" apply-config -n "$addr" --insecure --file "$state/nodes/$name.yaml"
    else
      log "$name ($addr): configured, applying"
      "$TALOSCTL" apply-config -n "$addr" -e "$addr" --file "$state/nodes/$name.yaml"
    fi
  done < <(nodes)
}

bootstrap() {
  inventory
  local cp i
  cp=$(controlplane)
  log "waiting for the Talos API on $cp"
  for i in $(seq 120); do
    "$TALOSCTL" version -n "$cp" >/dev/null 2>&1 && break
    [[ $i -lt 120 ]] || die "Talos API on $cp did not come up"
    sleep 5
  done
  # The API answers while Talos is still installing and rebooting, and
  # bootstrap says "not available yet" until etcd waits for it. It refuses a
  # second time with AlreadyExists, which is success here.
  local out
  for i in $(seq 120); do
    if out=$("$TALOSCTL" bootstrap -n "$cp" 2>&1); then break; fi
    if grep -q AlreadyExists <<<"$out"; then log "etcd already bootstrapped"; break; fi
    grep -qE 'not available yet|Unavailable|connection refused|deadline' <<<"$out" || die "bootstrap: $out"
    [[ $i -lt 120 ]] || die "bootstrap: $out"
    sleep 5
  done
  log "waiting for the Kubernetes API on $cp"
  for i in $(seq 120); do
    "$TALOSCTL" kubeconfig "$state/kubeconfig" -n "$cp" --force >/dev/null 2>&1 &&
      kubectl --kubeconfig "$state/kubeconfig" get --raw /readyz >/dev/null 2>&1 && break
    [[ $i -lt 120 ]] || die "Kubernetes API on $cp did not come up"
    sleep 5
  done
  chmod 0600 "$state/kubeconfig"
  log "export TALOSCONFIG=$TALOSCONFIG KUBECONFIG=$state/kubeconfig"
}

# kube is kubectl as this cluster's admin, whatever KUBECONFIG says.
kube() {
  kubectl --kubeconfig "$state/kubeconfig" --request-timeout=30s "$@" </dev/null
}

# joined prints the nodes of the node list on stdin that have an address yet,
# as one object from each name to its labels and addresses.
joined() {
  jq -c '[.items[] | {key: .metadata.name, value: {
      labels: (.metadata.labels // {}),
      addresses: [.status.addresses[]? | select(.type == "InternalIP") | .address]}}
    | select(.value.addresses != [])] | from_entries'
}

# labels sets the adminLabels of each pool on the pool's nodes, as the cluster's
# admin, since no node may set them on itself. A node that registers again
# comes back without them, and this sets them again. It removes none. A node
# that has not joined after ten minutes does not keep the others from theirs,
# and fails the run at the end.
labels() {
  inventory
  pooled "$state/nodes.json"
  local short want
  short=$(jq -r --argjson pools "$POOLS" '. as $nodes | [$pools | to_entries[] | select(.value.adminLabels != [])
    | .key as $pool | select(([$nodes[] | select(.pool == $pool)] | length) < .value.count) | $pool] | join(", ")' "$state/nodes.json")
  [[ -z $short ]] || die "the inventory lacks nodes of pool $short; run: cluster.sh gen $cluster"
  want=$(jq -c --argjson pools "$POOLS" '[.[] | ((.pool | values | $pools[.].adminLabels) // []) as $labels | select($labels != [])
    | {name, address, labels: ($labels | from_entries)}]' "$state/nodes.json")
  if [[ $want == '[]' ]]; then log "no pool sets adminLabels"; return; fi
  [[ -s $state/kubeconfig ]] || die "no kubeconfig; run: cluster.sh bootstrap $cluster"

  local i have left end=$((SECONDS + 600))
  for i in $(seq 120); do
    have=$(kube get nodes -o json 2>/dev/null | joined) || have={}
    left=$(jq -r --argjson have "$have" '[.[].name | select($have[.] == null)] | join(", ")' <<<"$want")
    [[ -n $left && $SECONDS -lt $end ]] || break
    [[ $i -gt 1 ]] || log "waiting for nodes to join: $left"
    [[ $i -eq 120 ]] || sleep 5
  done

  # A node of this name at another address is not the VM gen found, so the
  # kubeconfig may be another cluster's: nothing is labelled.
  local other name pairs
  other=$(jq -r --argjson have "$have" '[.[] | . as $n | $have[.name] // empty | select(.addresses | index($n.address) | not)
    | "\($n.name) is at \(.addresses | join(" ")), not \($n.address)"] | join(", ")' <<<"$want")
  [[ -z $other ]] || die "$other; run: cluster.sh gen $cluster, if this is the right cluster"

  local lacks='.[] | . as $n | $have[.name] // empty | .labels as $has
    | [$n.labels | to_entries[] | select($has[.key] != .value) | "\(.key)=\(.value)"] | select(. != [])
    | "\($n.name) \(join(" "))"'
  while read -r name pairs; do
    log "$name: setting $pairs"
    # $pairs is split into one argument a label; none holds a space or a glob.
    # shellcheck disable=SC2086
    kube label node "$name" --overwrite $pairs >/dev/null || log "$name: kubectl label failed"
  done < <(jq -r --argjson have "$have" "$lacks" <<<"$want")

  # What counts is what the API server has now.
  have=$(kube get nodes -o json | joined) || die "cannot read the nodes back"
  left=$(
    jq -r --argjson have "$have" '.[].name | select($have[.] == null) | "\(.) has not joined"' <<<"$want"
    jq -r --argjson have "$have" "$lacks" <<<"$want" | sed 's/ / lacks /'
  )
  if [[ -n $left ]]; then
    while read -r name; do log "$name"; done <<<"$left"
    die "nodes are without their admin labels; run: cluster.sh labels $cluster"
  fi
  log "admin labels: $(jq -r '[.[] | "\(.name) has \(.labels | to_entries | map("\(.key)=\(.value)") | join(" "))"] | join(", ")' <<<"$want")"
}

case $cmd in
  gen) gen ;;
  apply) apply ;;
  bootstrap) bootstrap ;;
  labels) labels ;;
  up) gen; apply; bootstrap; labels ;;
  *) die "unknown command: $cmd" ;;
esac
