#!/usr/bin/env bash
# tools.sh gets a clone ready to render: the four tools a render runs, at the
# versions deploy/ is rendered with, and the Substrate submodules it reads.
#
#   tools.sh          install the tools and check out the submodules
#   tools.sh check    say what a render lacks, and exit 1 if it lacks anything
#   tools.sh bin      print the directory the tools are installed in
#
# The tools are holos, which runs helm for the charts and kubectl's kustomize
# for the patches, and cue for `cue vet`. Each is downloaded from its
# project's release, checked against the SHA-256 below and installed in
# .tools/bin at the repository's root, which git ignores. Nothing outside the
# clone is written, and nothing needs root. A tool already there at its
# pinned version is left alone, so a second run downloads nothing.
#
# The pins are here and nowhere else: render.sh checks the tools with
# `tools.sh check` before it removes anything, and CI's Render job
# (.github/workflows/ci.yaml) installs them with this script. To bump a tool,
# change its version and its three checksums, from the release's own
# checksum file, and render.
#
# The submodules are the Substrate fork, one per commit a cluster pins, in
# vendor/substrate-<commit>. The substrate component builds upstream's
# install tree from the cluster's with kubectl kustomize, so no render works
# without them. One that is not checked out is fetched at its commit alone,
# without history; one that is checked out is left as it is.
#
# check looks for the tools in .tools/bin and then on PATH, so tools
# installed some other way pass when they are the pinned versions.
#
# It needs bash, git, curl, tar, gzip and sha256sum or shasum, and runs on
# Linux x86_64 and arm64 and on macOS arm64.
set -euo pipefail

# The checksums are read by name, as ${!sum}.
HOLOS_VERSION=0.106.0
HOLOS_SHA256_linux_amd64=4a8de6339dc00df3321bf634fc1830cb4b22e83c4d8efc5deccd43c6d5611478
HOLOS_SHA256_linux_arm64=7e7b005b7a7f35b22abc710c154d0c285f662cd7a3ceb3aee0d0104bc5277f01
HOLOS_SHA256_darwin_arm64=119d7d796e1f7a369f97cc75b439056a8a657c70a9f8287664ea31aa583a2954

CUE_VERSION=v0.17.1
CUE_SHA256_linux_amd64=a39b0c97695069d95d276d99be0f5dbabb081d801bfdc9ba49b76efaf94e2369
CUE_SHA256_linux_arm64=0d729be30d52c952ca38fc9dcb692caa09d8463fa0b64df5781312779183fbcd
CUE_SHA256_darwin_arm64=64921403f012a97f89494c03605db2fbf7d9daa77dc2631819ac4406cb2e8074

HELM_VERSION=v3.17.3
HELM_SHA256_linux_amd64=ee88b3c851ae6466a3de507f7be73fe94d54cbf2987cbaa3d1a3832ea331f2cd
HELM_SHA256_linux_arm64=7944e3defd386c76fd92d9e6fec5c2d65a323f6fadc19bfb5e704e3eee10348e
HELM_SHA256_darwin_arm64=89aec43ce07b06239f1bba4a6507236bb48ae487bc5065a8e254d3ce58a16997

KUBECTL_VERSION=v1.37.1
KUBECTL_SHA256_linux_amd64=65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8
KUBECTL_SHA256_linux_arm64=ff749f4b78d9c4f1ec87307df9b50119ed819e2094aa9810cb9acffc3286c8c7
KUBECTL_SHA256_darwin_arm64=fd65982c97ddad3106754b69ffa196d0e543aa591930ae52aed1adfb92f8c77f

TOOLS="holos cue helm kubectl"

die() { echo "tools.sh: $*" >&2; exit 1; }
log() { echo "tools.sh: $*" >&2; }

# Physical paths, since git reports the clone's top level that way and a clone
# reached through a symlink has to compare equal.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(cd "$here/.." && pwd -P)
bin=$repo/.tools/bin

# want <tool> is the tool's pinned version, as have prints it.
want() {
  case $1 in
    holos) echo "$HOLOS_VERSION" ;;
    cue) echo "$CUE_VERSION" ;;
    helm) echo "$HELM_VERSION" ;;
    kubectl) echo "$KUBECTL_VERSION" ;;
  esac
}

# have <tool> [<path>] is the version of the tool at path, or of the first
# one on PATH, and empty when there is none or it does not run.
have() {
  local exe=${2:-$1}
  command -v "$exe" >/dev/null || return 0
  case $1 in
    holos) "$exe" --version 2>/dev/null | head -n 1 ;;
    cue) "$exe" version 2>/dev/null | sed -n '1s/^cue version //p' ;;
    helm) "$exe" version --template '{{.Version}}' 2>/dev/null ;;
    kubectl) "$exe" version --client 2>/dev/null | sed -n 's/^Client Version: //p' ;;
  esac || true
}

# missing_submodules prints the path, from the repository's root, of every submodule
# that is not checked out.
missing_submodules() {
  git -C "$repo" submodule status | sed -n 's/^-[0-9a-f]* \([^ ]*\).*/\1/p'
}

in_a_clone() {
  [[ $(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) == "$repo" ]]
}

check() {
  local tool got failed=0
  PATH=$bin:$PATH
  for tool in $TOOLS; do
    got=$(have "$tool")
    if [[ -z $got ]]; then
      log "$tool is not installed; a render needs $tool $(want "$tool")"
      failed=1
    elif [[ $got != "$(want "$tool")" ]]; then
      log "$(command -v "$tool") is $tool $got; a render needs $tool $(want "$tool")"
      failed=1
    fi
  done
  if ! in_a_clone; then
    log "$repo is not a git clone; a render reads the Substrate submodules, which only a clone has"
    failed=1
  else
    for tree in $(missing_submodules); do
      log "$tree is not checked out; the substrate component renders from it"
      failed=1
    done
  fi
  if [[ $failed -ne 0 ]]; then
    log "run $here/tools.sh to install the tools and check out the submodules"
    return 1
  fi
}

sha256() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# fetch <url> <sha256> <file> downloads url to file in $dl and checks it.
fetch() {
  local got
  curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -o "$dl/$3" "$1" || die "could not download $1"
  got=$(sha256 "$dl/$3")
  [[ $got == "$2" ]] || die "$1 has sha256 $got, want $2"
}

install_tool() {
  local tool=$1 sum
  if [[ $(have "$tool" "$bin/$tool") == "$(want "$tool")" ]]; then
    log "$tool $(want "$tool") is installed"
    return
  fi
  log "installing $tool $(want "$tool")"
  case $tool in
    holos)
      sum=HOLOS_SHA256_${os}_${arch}
      # holos names its archives as uname does.
      local hos=Linux harch=$arch
      [[ $os == linux ]] || hos=Darwin
      [[ $arch == arm64 ]] || harch=x86_64
      fetch "https://github.com/holos-run/holos/releases/download/v${HOLOS_VERSION}/holos_${hos}_${harch}.tar.gz" "${!sum}" holos.tar.gz
      tar -xzf "$dl/holos.tar.gz" -C "$dl" holos
      ;;
    cue)
      sum=CUE_SHA256_${os}_${arch}
      fetch "https://github.com/cue-lang/cue/releases/download/${CUE_VERSION}/cue_${CUE_VERSION}_${os}_${arch}.tar.gz" "${!sum}" cue.tar.gz
      tar -xzf "$dl/cue.tar.gz" -C "$dl" cue
      ;;
    helm)
      sum=HELM_SHA256_${os}_${arch}
      fetch "https://get.helm.sh/helm-${HELM_VERSION}-${os}-${arch}.tar.gz" "${!sum}" helm.tar.gz
      tar -xzf "$dl/helm.tar.gz" -C "$dl" "${os}-${arch}/helm"
      mv "$dl/${os}-${arch}/helm" "$dl/helm"
      ;;
    kubectl)
      sum=KUBECTL_SHA256_${os}_${arch}
      fetch "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${os}/${arch}/kubectl" "${!sum}" kubectl
      ;;
  esac
  chmod 0755 "$dl/$tool"
  mv "$dl/$tool" "$bin/$tool"
  [[ $(have "$tool" "$bin/$tool") == "$(want "$tool")" ]] ||
    die "$bin/$tool reports version '$(have "$tool" "$bin/$tool")', want $(want "$tool")"
}

install() {
  local tool
  case $(uname -s)/$(uname -m) in
    Linux/x86_64) os=linux arch=amd64 ;;
    Linux/aarch64 | Linux/arm64) os=linux arch=arm64 ;;
    Darwin/arm64) os=darwin arch=arm64 ;;
    *) die "no pinned tools for $(uname -s)/$(uname -m): Linux x86_64, Linux arm64 and macOS arm64 only" ;;
  esac
  for tool in git curl tar gzip; do
    command -v "$tool" >/dev/null || die "$tool is not on PATH"
  done
  command -v sha256sum >/dev/null || command -v shasum >/dev/null ||
    die "neither sha256sum nor shasum is on PATH"
  in_a_clone || die "$repo is not a git clone; a render reads the Substrate submodules, which only a clone has"

  mkdir -p "$bin"
  dl=$(mktemp -d "$repo/.tools/dl.XXXXXX")
  trap 'rm -rf "$dl"' EXIT
  for tool in $TOOLS; do
    install_tool "$tool"
  done

  # Each missing submodule at the commit the repository records, and no more
  # of its history: the fork's is over 100 MB, and a render reads one tree.
  for tree in $(missing_submodules); do
    log "checking out $tree"
    git -C "$repo" submodule update --init --depth 1 -- "$tree" ||
      die "could not check out $tree"
  done

  check
  log "ready: $here/render.sh renders the platform"
}

case ${1:-install} in
  install) [[ $# -le 1 ]] || die "usage: tools.sh [check|bin]"; install ;;
  check) [[ $# -eq 1 ]] || die "usage: tools.sh [check|bin]"; check ;;
  bin) [[ $# -eq 1 ]] || die "usage: tools.sh [check|bin]"; echo "$bin" ;;
  *) die "usage: tools.sh [check|bin]" ;;
esac
