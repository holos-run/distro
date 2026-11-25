#!/usr/bin/env bash
# etcd-snapshot.sh snapshots a cluster's etcd to the garage export, with an
# encrypted copy of the cluster's Talos state directory beside it.
#
#   etcd-snapshot.sh run   <cluster>   take a snapshot and prune the old ones
#   etcd-snapshot.sh check <cluster>   print the newest one's name and age, and
#                                      fail when there is none to rely on
#
# The files are <dir>/<cluster>/<cluster>-<UTC timestamp>.snapshot and
# .secrets.tar.gpg, with one timestamp for the pair, in the form
# 20261125T101700Z, so the last in a listing is the newest. The archive is in
# place before the snapshot is, so a snapshot that is there has its archive.
#
# run is for the systemd user unit etcd-snapshot@<cluster>.service, which sets
# these; the settings of one cluster are in its drop-in:
#
#   ETCD_SNAPSHOT_TALOSCTL    the talosctl of the cluster's Talos version
#   ETCD_SNAPSHOT_NODE        the control plane's address
#   ETCD_SNAPSHOT_RECIPIENT   full fingerprint of the key to encrypt to
#   ETCD_SNAPSHOT_KEEP        how many snapshots to keep
#
# and both verbs take these, whose defaults are the garage's:
#
#   ETCD_SNAPSHOT_MOUNT       the mount that must be there
#   ETCD_SNAPSHOT_DIR         the directory on it
#   ETCD_SNAPSHOT_MAX_AGE     the age in seconds check fails past
#   HOLOS_TALOS_DIR           as for cluster.sh
#
# Nothing is ever written to local disk in the mount's place: without the
# mount both verbs fail, and run never makes the directory above
# ETCD_SNAPSHOT_DIR.
set -euo pipefail

die() { echo "etcd-snapshot.sh: $*" >&2; exit 1; }
log() { echo "etcd-snapshot.sh: $*" >&2; }

[[ $# -eq 2 ]] || die "usage: etcd-snapshot.sh run|check <cluster>"
cmd=$1 cluster=$2
[[ $cluster =~ ^[a-z][a-z0-9-]{0,30}$ ]] || die "invalid cluster name: $cluster"

umask 077
mount=${ETCD_SNAPSHOT_MOUNT:-/mnt/pve/garage}
root=${ETCD_SNAPSHOT_DIR:-$mount/backups/etcd}
dir=$root/$cluster
state_root=${HOLOS_TALOS_DIR:-$HOME/.config/holos/talos}
max_age=${ETCD_SNAPSHOT_MAX_AGE:-172800}

STAMP='[0-9]{8}T[0-9]{6}Z'

# mounted fails unless the mount is there. The export is mounted hard, so a
# server that is away blocks every call on it: the timeout makes that a
# failure too.
mounted() {
  timeout -k 5 60 mountpoint -q "$mount" || die "$mount is not mounted, or does not answer"
  case $root in "$mount"/*) ;; *) die "$root is not under $mount" ;; esac
}

# stamps prints the timestamps of the cluster's files with the suffix $1,
# oldest first. Only the exact form counts, so a partial file or one someone
# put there is never listed, and never pruned.
stamps() {
  local name listing
  listing=$(timeout -k 5 60 ls -1 "$dir") || return 1
  while read -r name; do
    if [[ $name =~ ^"$cluster"-($STAMP)"$1"$ && -f $dir/$name && ! -L $dir/$name ]]; then
      echo "${BASH_REMATCH[1]}"
    fi
  done <<<"$listing" | LC_ALL=C sort
}

# complete reports whether $1 is a whole etcd snapshot: etcd ends one with the
# SHA-256 of everything before it, whose length is a multiple of 512.
complete() {
  local want have size
  size=$(stat -c %s -- "$1") || return 1
  [[ $size -gt 32 && $((size % 512)) -eq 32 ]] || return 1
  want=$(tail -c 32 -- "$1" | od -An -v -tx1 | tr -d ' \n')
  have=$(head -c -32 -- "$1" | sha256sum)
  [[ ${have%% *} == "$want" ]]
}

run() {
  local talosctl=${ETCD_SNAPSHOT_TALOSCTL:?set by the unit} node=${ETCD_SNAPSHOT_NODE:?set by the unit}
  local recipient=${ETCD_SNAPSHOT_RECIPIENT:?set by the unit} keep=${ETCD_SNAPSHOT_KEEP:?set by the unit}
  local state=$state_root/$cluster f
  [[ $recipient =~ ^[0-9A-F]{40}$ ]] || die "recipient $recipient: want a full fingerprint"
  [[ $keep =~ ^[1-9][0-9]{0,3}$ ]] || die "keep $keep: want a number from 1"
  [[ -x $talosctl ]] || die "$talosctl is not there"
  # An archive without these could not restore anything.
  for f in secrets.yaml talosconfig nodes.json "nodes/$cluster-cp-1.yaml"; do
    [[ -s $state/$f ]] || die "$state/$f is missing or empty"
  done

  mounted
  [[ -d ${root%/*} ]] || die "${root%/*} does not exist; it is made by hand"
  mkdir -p "$dir"

  # One timestamp for the pair, taken before the snapshot, so its age is
  # never understated.
  local stamp
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  local snapshot=$dir/$cluster-$stamp.snapshot archive=$dir/$cluster-$stamp.secrets.tar.gpg
  [[ ! -e $snapshot && ! -e $archive ]] || die "$cluster-$stamp already exists"

  # The partial files are hidden and end in .partial, so nothing takes them
  # for the newest; talosctl writes beside its own, with .part added. These
  # are global for the trap: placed is an archive in place whose snapshot is
  # not yet.
  partial=$dir/.$cluster-$stamp.$$
  placed=
  trap cleanup EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT

  tar -C "$state_root" -cf - "$cluster" |
    gpg --batch --trust-model always --encrypt --recipient "$recipient" >"$partial.archive.partial" ||
    die "could not write the archive"
  [[ -s $partial.archive.partial ]] || die "the archive is empty"

  "$talosctl" --talosconfig "$state/talosconfig" -e "$node" -n "$node" \
    etcd snapshot "$partial.snapshot.partial" || die "talosctl etcd snapshot failed"
  complete "$partial.snapshot.partial" || die "the snapshot is missing, empty or incomplete"

  # ln, unlike mv, refuses a name that has appeared since.
  ln -T -- "$partial.archive.partial" "$archive"
  placed=$archive
  ln -T -- "$partial.snapshot.partial" "$snapshot"
  placed=
  log "wrote $snapshot ($(stat -c %s -- "$snapshot") bytes) and $archive ($(stat -c %s -- "$archive") bytes)"

  prune "$keep" "$stamp"
}

cleanup() {
  rm -f -- "${partial:?}.archive.partial" "${partial:?}.snapshot.partial" "${partial:?}.snapshot.partial.part"
  if [[ -n $placed ]]; then rm -f -- "${placed:?}"; fi
}

# prune keeps the newest $1 snapshots, and deletes the older ones and the
# archives older than all of those kept. $2 is this run's, which stays
# whatever the clock did.
prune() {
  local keep=$1 own=$2 suffix stamp oldest all
  all=$(stamps .snapshot) || die "cannot list $dir"
  [[ $(wc -l <<<"$all") -gt $keep ]] || return 0
  oldest=$(tail -n "$keep" <<<"$all" | head -n 1)
  for suffix in .snapshot .secrets.tar.gpg; do
    all=$(stamps "$suffix") || die "cannot list $dir"
    for stamp in $all; do
      if [[ $stamp < $oldest && $stamp != "$own" ]]; then
        rm -- "${dir:?}/${cluster:?}-${stamp:?}${suffix:?}"
        log "pruned $cluster-$stamp$suffix"
      fi
    done
  done
}

# check takes the age from the name, the time the run began. An mtime moves
# when a file is copied or touched, and the name does not.
check() {
  mounted
  local all stamp age iso name
  [[ -d $dir ]] || die "no snapshots: $dir does not exist"
  all=$(stamps .snapshot) || die "cannot list $dir"
  stamp=$(tail -n 1 <<<"$all")
  [[ -n $stamp ]] || die "no snapshots in $dir"
  name=$cluster-$stamp
  iso=${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:9:2}:${stamp:11:2}:${stamp:13:2}Z
  age=$(date -u -d "$iso" +%s) || die "$name.snapshot: not a time"
  age=$(($(date -u +%s) - age))
  echo "$dir/$name.snapshot, $((age / 3600))h$((age % 3600 / 60))m old"
  complete "$dir/$name.snapshot" || die "$name.snapshot is empty or not whole"
  [[ -s $dir/$name.secrets.tar.gpg ]] || die "$name.secrets.tar.gpg, beside it, is missing or empty"
  [[ $age -ge 0 ]] || die "$name.snapshot is from the future; check the clock"
  [[ $age -le $max_age ]] || die "$name.snapshot is more than $((max_age / 3600)) hours old: systemctl --user status etcd-snapshot@$cluster.timer etcd-snapshot@$cluster.service"
}

case $cmd in
  run) run ;;
  check) check ;;
  *) die "unknown command: $cmd" ;;
esac
