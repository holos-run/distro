#!/usr/bin/env bash
# stage-microvm-assets.sh stages the microVM sandbox class's guest assets into a
# cluster's asset bucket, as ate-setup's prepareMicroVMDeps and its staging step
# do (cmd/ate-setup/internal/steps/microvm.go), from the operator's machine:
#
#   stage-microvm-assets.sh [-w <dir>] <cluster> [<arch>...]
#
# The SandboxConfig microvm (components/substrate) names four files for each
# architecture, at s3://<bucket>/microvm-assets/<arch>/<sha256>. Their digests
# are not of the release archives but of the files upstream takes out of them:
# vmlinux, the root image and virtiofsd from the Kata static archive, and the
# Cloud Hypervisor static binary. For each architecture, amd64 and arm64 unless
# named, this
#
#  1. downloads both releases from GitHub, at the versions ate-setup's
#     microvm.go pins at the cluster's Substrate commit;
#  2. assembles the four files as microvm.go does, and checks each sha256
#     against upstream's template at that commit,
#     manifests/ate-install/sandboxconfig-microvm.yaml.tmpl, and its URL
#     against the cluster's rendered SandboxConfig, which must name the same;
#  3. uploads each file that is not in the bucket yet through a port-forward to
#     RustFS, with the bucket's write key, Secret rustfs/rustfs-<bucket>;
#  4. reads every file back and checks its sha256 again.
#
# It runs from a checkout of the platform, with KUBECONFIG naming the
# cluster, and needs bash, curl (8.x, for --aws-sigv4), zstd, GNU tar, jq,
# sha256sum, kubectl and cue. Nothing in the cluster reaches GitHub or holds
# the write key: the pods only read, through rustfs-substrate. A second run
# uploads nothing that is there. -w keeps the downloads in <dir> for a later
# run; without it they go in a new temporary directory, which is removed.
set -euo pipefail

die() { echo "stage-microvm-assets.sh: $*" >&2; exit 1; }
log() { echo "stage-microvm-assets.sh: $*" >&2; }

work=
while getopts w: opt; do
  case $opt in
    w) work=$OPTARG ;;
    *) die "usage: stage-microvm-assets.sh [-w <dir>] <cluster> [<arch>...]" ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -ge 1 ]] || die "usage: stage-microvm-assets.sh [-w <dir>] <cluster> [<arch>...]"
cluster=$1
shift
[[ $cluster =~ ^[a-z][a-z0-9-]{0,30}$ ]] || die "invalid cluster name: $cluster"
arches=("$@")
[[ ${#arches[@]} -gt 0 ]] || arches=(amd64 arm64)

for tool in curl zstd tar jq sha256sum kubectl cue realpath; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH"
done

# The platform root, holos/, two directories up from this file.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
commit=$(cd "$root" && cue export . -e "clusters.$cluster.pins.substrate.commit" --out text) ||
  die "no cluster $cluster in clusters.cue"
tree=$root/vendor/substrate-$commit
tmpl=$tree/manifests/ate-install/sandboxconfig-microvm.yaml.tmpl
steps=$tree/cmd/ate-setup/internal/steps/microvm.go
rendered=$root/deploy/clusters/$cluster/components/substrate/sandboxconfig-microvm.yaml
[[ -f $tmpl && -f $steps ]] || die "$tree is not checked out: git submodule update --init"
[[ -f $rendered ]] || die "$rendered is not rendered: $cluster does not run the microvm class"

# The releases microvm.go assembles from, at the pin.
version() { sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\1/p" "$steps"; }
kata=$(version defaultKataVersion)
ch=$(version defaultCloudHypervisorVersion)
[[ -n $kata && -n $ch ]] || die "no Kata or Cloud Hypervisor version in $steps"

# assets prints "<arch> <asset> <sha256> <url>" for the default version of a
# SandboxConfig, one line per file.
assets() {
  cue export "yaml:" "$1" --out json | jq -r '
    .spec as $s | $s.versions[] | select(.name == $s.defaultVersion and .state == "Enabled") |
    .assets | to_entries[] | .key as $arch | .value | to_entries[] |
    "\($arch) \(.key) \(.value.sha256) \(.value.url)"' | LC_ALL=C sort
}
want=$(assets "$tmpl")
have=$(assets "$rendered")
[[ -n $want ]] || die "no enabled default version in $tmpl"
# The rendered SandboxConfig is the template with the bucket in its URLs, so
# the two agree on every file and digest.
[[ $(cut -d' ' -f1-3 <<<"$want") == $(cut -d' ' -f1-3 <<<"$have") ]] ||
  die "$rendered does not name the files of $tmpl: render the platform"
bucket=
while read -r arch name sha url; do
  [[ $url =~ ^s3://([a-z0-9][a-z0-9.-]+)/microvm-assets/$arch/$sha$ ]] ||
    die "$name for $arch is at $url, not s3://<bucket>/microvm-assets/$arch/$sha"
  [[ -z $bucket || $bucket == "${BASH_REMATCH[1]}" ]] || die "$rendered names more than one bucket"
  bucket=${BASH_REMATCH[1]}
done <<<"$have"

# The file microvm.go assembles for each of the template's assets.
declare -A file=([cloud-hypervisor]=cloud-hypervisor [virtiofsd]=virtiofsd [kata-kernel]=vmlinux [kata-image]=rootfs.img)

# KUBECONFIG must be the cluster's: its nodes are named for it.
kubectl get nodes -o name | grep -q "^node/$cluster-" ||
  die "the current kubeconfig is not $cluster's: export KUBECONFIG=~/.config/holos/talos/$cluster/kubeconfig"

# cleanup stops the port-forward and removes a temporary work directory.
tmpwork= pf=
cleanup() {
  if [[ -n $pf ]]; then kill "$pf" 2>/dev/null || true; fi
  if [[ -n $tmpwork ]]; then rm -rf -- "$tmpwork"; fi
}
trap cleanup EXIT
if [[ -z $work ]]; then
  work=$(mktemp -d)
  tmpwork=$work
fi
mkdir -p "$work"
work=$(realpath "$work")

# assemble downloads the releases for $1 into $work/<arch> and takes the four
# files out, as assembleMicroVMAssets does, into $work/<arch>/assets.
assemble() {
  local arch=$1 dir=$work/$1 chname src out
  case $arch in
    amd64) chname=cloud-hypervisor-static ;;
    arm64) chname=cloud-hypervisor-static-aarch64 ;;
    *) die "unsupported arch $arch" ;;
  esac
  mkdir -p "$dir"
  local kurl=https://github.com/kata-containers/kata-containers/releases/download/$kata/kata-static-$kata-$arch.tar.zst
  local churl=https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/$ch/$chname
  for u in "$kurl" "$churl"; do
    if [[ ! -f $dir/${u##*/} ]]; then
      log "downloading $u"
      curl -fsSL --retry 3 -o "$dir/${u##*/}.part" "$u"
      mv "$dir/${u##*/}.part" "$dir/${u##*/}"
    fi
  done
  # Only the guest's files and virtiofsd, as extractKataTarZst takes. GNU tar
  # strips leading slashes and refuses members that climb out with ..; each
  # file is resolved below and must stay inside the extraction.
  rm -rf -- "$dir/x" "$dir/assets"
  mkdir -p "$dir/x" "$dir/assets"
  zstd -dc "$dir/kata-static-$kata-$arch.tar.zst" |
    tar -x -C "$dir/x" --no-same-owner --no-same-permissions --wildcards \
      '*opt/kata/share/kata-containers/*' '*opt/kata/libexec/virtiofsd'
  for pair in \
    opt/kata/share/kata-containers/vmlinux.container:vmlinux \
    opt/kata/share/kata-containers/kata-containers.img:rootfs.img \
    opt/kata/libexec/virtiofsd:virtiofsd; do
    src=$(realpath -e "$dir/x/${pair%%:*}") || die "${pair%%:*} is not in the $arch archive"
    case $src in "$dir/x/"*) ;; *) die "${pair%%:*} resolves outside the archive: $src" ;; esac
    [[ -f $src ]] || die "${pair%%:*} is not a regular file"
    out=$dir/assets/${pair##*:}
    cp -- "$src" "$out"
  done
  cp -- "$dir/$chname" "$dir/assets/cloud-hypervisor"
  rm -rf -- "$dir/x"
}

for arch in "${arches[@]}"; do
  grep -q "^$arch " <<<"$want" || die "the template names no assets for $arch"
  assemble "$arch"
  while read -r a name sha _; do
    [[ $a == "$arch" ]] || continue
    got=$(sha256sum "$work/$arch/assets/${file[$name]}" | cut -d' ' -f1)
    if [[ $got != "$sha" ]]; then
      die "$arch/${file[$name]} ($name): sha256 $got, the template's $sha"
    fi
    log "$arch/${file[$name]} ($name): sha256 $got matches the template"
  done <<<"$want"
done

# The write key. It goes to curl in a config file on a pipe, never on a
# command line.
secret=rustfs-$bucket
ak=$(kubectl -n rustfs get secret "$secret" -o jsonpath='{.data.access-key}' | base64 -d)
sk=$(kubectl -n rustfs get secret "$secret" -o jsonpath='{.data.secret-key}' | base64 -d)
[[ -n $ak && -n $sk ]] || die "Secret rustfs/$secret has no keys: sync rustfs"
s3() { curl -fsS --aws-sigv4 "aws:amz:us-east-1:s3" -K <(printf 'user = "%s:%s"\n' "$ak" "$sk") "$@"; }

# RustFS has no route from outside the cluster, so the upload goes through a
# port-forward to its Service.
pf_log=$work/port-forward.log
kubectl -n rustfs port-forward svc/rustfs-svc :9000 >"$pf_log" 2>&1 &
pf=$!
port=
for _ in $(seq 1 30); do
  port=$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+) .*/\1/p' "$pf_log" | head -1)
  [[ -n $port ]] && break
  sleep 1
done
[[ -n $port ]] || die "port-forward to rustfs failed: $(cat "$pf_log")"
endpoint=http://127.0.0.1:$port

while read -r arch name sha url; do
  [[ " ${arches[*]} " == *" $arch "* ]] || continue
  key=${url#s3://"$bucket"/}
  if s3 -o /dev/null -I "$endpoint/$bucket/$key" 2>/dev/null; then
    log "$arch/${file[$name]} is already at s3://$bucket/$key"
  else
    log "uploading $arch/${file[$name]} to s3://$bucket/$key"
    s3 -o /dev/null -T "$work/$arch/assets/${file[$name]}" "$endpoint/$bucket/$key"
  fi
  got=$(s3 "$endpoint/$bucket/$key" | sha256sum | cut -d' ' -f1)
  [[ $got == "$sha" ]] || die "s3://$bucket/$key reads back with sha256 $got"
  log "s3://$bucket/$key reads back with sha256 $got"
done <<<"$have"
log "staged ${arches[*]} for $cluster in s3://$bucket/microvm-assets/"
