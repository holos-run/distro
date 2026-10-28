# The Substrate and kagent forks

Holos builds Agent Substrate and kagent from forks in the holos-run
organization, not from the upstream repositories directly. A fork gives Holos
a place to carry a change upstream has not taken yet, and a commit it controls
for every pin.

| Fork | Upstream |
| --- | --- |
| [holos-run/substrate](https://github.com/holos-run/substrate) | [agent-substrate/substrate](https://github.com/agent-substrate/substrate) |
| [holos-run/kagent](https://github.com/holos-run/kagent) | [kagent-dev/kagent](https://github.com/kagent-dev/kagent) |

Both forks are public, since a fork of a public repository cannot be private.

## Pins

| Fork | Branch | Commit |
| --- | --- | --- |
| holos-run/substrate | `holos-2026-10-28` | `475f49b023352b47b8504ffead596953f28d7e7f` |
| holos-run/kagent | `holos-2026-10-28` | `fa2cb2361ee45da4b3e757a618128c298680d458` |

The Substrate pin is upstream `main` on 2026-10-28 with nothing added. It
will also be the submodule commit the platform vendors Substrate from, once
the Substrate package adds the submodule.

The kagent pin is the commit kagent's images are built from. It is upstream
`main` at `d9cc3a826511e80c7621ff55b6341d469c6bb8c1` with the two commits
described below.

A pin is always a full commit SHA in a fork, never a tag or a branch name. A
branch moves and a tag can be moved, so neither says what was built.

## What each fork carries

The Substrate fork carries nothing yet. It is the place for a patch Substrate
needs to run on Talos, such as a `certificates.k8s.io/v1beta1` fallback or an
optional credential provider mount, and the branch a pull request to upstream
starts from.

The kagent fork carries two commits on top of upstream:

- **The router dialers do mutual TLS.** Substrate's Atenet router has accepted
  only mutual TLS since October 21, but kagent's two router dialers, the A2A
  gateway's and the sandbox guest's, built an `https` TLS config with no roots
  and no client certificate. The commit shares the ate-api client's TLS config
  as `substrate.ClientTLSConfig` and uses it in both dialers with the existing
  `substrate.caFile` and `substrate.clientCertFile` settings. The CA file
  verifies the router, and the pod certificate is read at each handshake, so
  a rotated certificate is used without a restart. An `http` router URL works
  as before. This change is meant to go upstream.
- **kagent builds against the Substrate fork.** Upstream kagent's `go/go.mod`
  replaces `go.ate.dev/substrate` with kagent-dev's own Substrate fork at a
  sync tag. The commit points the replace at `github.com/holos-run/substrate`
  at the Substrate pin, so kagent's ate-api client and the Substrate it talks
  to come from one tree. Upstream Substrate renamed `SnapshotStorage.status` to
  `state`, which kagent-dev's fork did not have yet, so the commit also follows
  that rename in kagent's Go code. The field numbers did not change, so the
  vendored `proto/` copy and the UI's generated TypeScript, which still use
  the old names, decode the new messages correctly over binary protobuf.

The replace commit leaves one thing stale. kagent's `Makefile` and
`go/Makefile` derive `SUBSTRATE_VERSION` from the `kagent-dev/substrate` line
in `go/go.mod`, which is gone, so a `make` build sets it empty. Only the CLI
reads it, as the default Substrate chart and worker image version for
`kagent install`, so a CLI built that way installs broken defaults. The
controller and UI images do not use it, and Holos deploys Substrate itself
rather than through `kagent install`.

## Branches

Each fork has dated branches named `holos-<date>`, such as
`holos-2026-10-28`. A dated branch is cut from the upstream head on that date
and carries the Holos commits on top. Once pushed, it is never rewritten,
force pushed or deleted, and no tag is moved to it. A rebase makes a new
dated branch instead.

The newest dated branch is the fork's default branch, so a clone of the fork
checks out what Holos builds. There is no separate moving `holos` branch,
because it would have to be rewritten at each rebase.

## Protection

Whoever can push to a `holos-*` branch decides what the garage runner builds
and Argo CD deploys, so each fork has a repository ruleset on
`refs/heads/holos-*` that:

- blocks deletion,
- blocks force pushes (non-fast-forward updates), and
- requires signed commits.

Pull requests are not required. Creating a new `holos-*` branch is allowed,
which is how a rebase lands.

The signed commit rule applies to commits new to the fork, which for a
rebase are the upstream commits since the last one as well as the Holos
commits. Older upstream history has unsigned commits: about 330 in Substrate,
the latest on 2026-09-15, and 232 in kagent, the latest on 2026-09-02. Those
were copied in when the forks were made, so they do not count. Every upstream
commit since mid-September is a squash merge that GitHub signed with its
web-flow key, so rebases pass for now. If an upstream lands an unsigned
commit again, pushing the next dated branch fails, and the rule has to be
revisited.

The ruleset is created with the GitHub API, once per fork:

```sh
gh api -X POST repos/holos-run/<fork>/rulesets --input - <<'EOF'
{
  "name": "holos branches",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/heads/holos-*"], "exclude": []}},
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "required_signatures"}
  ]
}
EOF
```

## Rebasing on upstream

A rebase moves both forks to the upstream heads of the day. Substrate goes
first, since kagent's replace points at it. Commits are signed and carry a
DCO sign-off (`git commit -s`).

1. Fetch upstream in each fork's clone. The upstream remote is
   `https://github.com/agent-substrate/substrate.git` for Substrate and
   `https://github.com/kagent-dev/kagent.git` for kagent:

   ```sh
   git remote add upstream <upstream URL>  # once per clone, unless gh made it
   git fetch upstream
   ```

2. Cut the new dated branch from the upstream head:

   ```sh
   git switch -c holos-<date> upstream/main
   ```

3. Bring the Holos commits over from the previous dated branch, and drop any
   upstream has since taken:

   ```sh
   git cherry-pick upstream/main..holos-<previous date>
   ```

   For Substrate, while it carries nothing, there is nothing to pick.

4. In kagent, point the replace at the new Substrate pin. Given a commit SHA,
   `go mod tidy` writes the matching pseudo-version:

   ```sh
   cd go
   go mod edit -replace go.ate.dev/substrate=github.com/holos-run/substrate@<substrate pin>
   go mod tidy
   ```

   Keep the commit to the replace, `go.sum` and any change the new Substrate
   needs; leave unrelated `go mod tidy` changes to upstream. Amend the
   replace commit rather than adding a new one, so the fork keeps one commit
   per change.

5. Build and test in `go/`:

   ```sh
   go build ./...
   go vet ./...
   go test ./core/internal/substrate/... ./core/internal/a2agateway/... \
     ./core/internal/service/sandbox/... ./core/pkg/app/...
   ```

   If upstream Substrate changed an API kagent uses, fix kagent's use of it
   in the replace commit and say so in its message.

6. Push the new branch. The ruleset lets a new `holos-*` branch be created
   and checks that every commit new to the fork is signed.

   ```sh
   git push origin holos-<date>
   ```

7. Make it the fork's default branch:

   ```sh
   gh repo edit holos-run/<fork> --default-branch holos-<date>
   ```

8. Update the pins in this document, and the Substrate submodule and kagent
   image builds that use them.

The old dated branches stay as they are, so a pin to an older commit can
still be fetched and rebuilt.
