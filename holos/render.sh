#!/usr/bin/env bash
# render.sh renders the platform into deploy/, from any directory:
#
#   render.sh
#
# It is `cue vet ./...`, `rm -rf deploy/clusters` and `holos render platform`,
# in that order, with two checks in front so a render that cannot work stops
# before anything is removed:
#
#  1. `tools.sh check`: holos, cue, helm and kubectl are the versions deploy/
#     is rendered with, and every Substrate submodule is checked out. Where
#     one is not, it says so and names tools.sh, which installs them.
#  2. `cue vet ./...`, because the render does not report every error in
#     clusters.cue or projects/ (README.md, Adding a project).
#
# deploy/clusters is removed because `holos render platform` writes files but
# never removes one a component no longer renders. The tools tools.sh
# installed, in .tools/bin at the repository's root, come first on PATH, for
# holos too, which runs helm and kubectl itself.
#
# An unchanged clone renders to exactly what is committed, so `git status` is
# clean afterwards, and after an edit `git status` and `git diff` show what
# the edit changed. A render that fails part way, on an error in a component
# that `cue vet` does not see, leaves deploy/clusters part written: fix the
# error and render again, or put back what is committed with
# `git restore deploy/clusters && git clean -fdq deploy/clusters`.
set -euo pipefail

die() { echo "render.sh: $*" >&2; exit 1; }
log() { echo "render.sh: $*" >&2; }

[[ $# -eq 0 ]] || die "usage: render.sh"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

"$here/tools.sh" check || die "nothing was removed or rendered"
PATH=$("$here/tools.sh" bin):$PATH

cd "$here"
log "cue vet ./..."
cue vet ./... || die "cue vet failed; nothing was removed or rendered"
rm -rf deploy/clusters
log "holos render platform"
holos render platform ||
  die "the render failed and deploy/clusters is part written; fix the error and run render.sh again"
log "rendered; git status shows what changed"
