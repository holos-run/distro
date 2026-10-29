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

Whoever can push to a `holos-*` branch decides what the
[Publish images](#images) workflow builds and Argo CD deploys, so each fork
has a repository ruleset on `refs/heads/holos-*` that:

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

8. Update the pins in this document and the Substrate submodule, and publish
   the images at the new pins ([Images](#images)).

The old dated branches stay as they are, so a pin to an older commit can
still be fetched and rebuilt.

## Images

The images and charts built from the forks are published to ghcr.io under
holos-run by the Publish images workflow,
[`.github/workflows/publish-images.yaml`](../.github/workflows/publish-images.yaml),
which runs [`cmd/publish-images`](../cmd/publish-images) on a GitHub-hosted
runner. ghcr.io is their origin, not a mirror: they are holos-run's builds of
holos-run's forks. They are public, so a cluster pulls them anonymously, and
they outlive the treasury cluster, whose Quay is rebuilt with it. Quay holds
none of them.

| Fork | Published | Built by |
| --- | --- | --- |
| Substrate | `ghcr.io/holos-run/substrate/<name>` | the fork's `ate-setup publish release-images` |
| kagent | `ghcr.io/holos-run/kagent/controller`, `ghcr.io/holos-run/kagent/ui` | the fork's `make build-controller` and `make build-ui` |
| kagent | `oci://ghcr.io/holos-run/kagent/helm/kagent`, `oci://ghcr.io/holos-run/kagent/helm/kagent-crds` | the fork's `make helm-version`, then `helm push` |

The Substrate images are ate-idp-server, ateapi, atecontroller, atelet,
atenet, ateworker-gvisor, ateworker-microvm, kubernetes-secrets,
objectstore-plugin, podcertcontroller and envoy-dataplane at the pin. The
program does not keep its own list: it reads the set from the checked-out
fork's `cmd/ate-setup/internal/images/images.go`, the `released` import paths
and the `releasedDockerfiles` images, and fails if what `ate-setup` reports
pushing differs from it. A rebase that adds or drops an image changes what is
published, and the platform's pins have to follow.

Every image is built for `linux/amd64` and `linux/arm64`. kagent's sandbox
guest and harness images and its CLI are not built: they carry no fork
change, and the platform pins kagent's own at the nearest release. The charts
are kagent's as packaged, so their default image values still name
kagent-dev's images; the platform sets the image values by digest.

### Versions

Each fork's images and charts are tagged
`0.0.0-holos.<YYYYMMDD>.<7-character SHA>`, with a `v` in front for
Substrate, whose publish command accepts only a `vMAJOR.MINOR.PATCH[-PRERELEASE]`
tag. Helm wants a chart version without the `v`. At the pins above they are
`v0.0.0-holos.20261028.475f49b` and `0.0.0-holos.20261028.fa2cb23`.

The date is the commit's committer date in UTC, not the day of the run, so
publishing one pin again gives the same tag. SemVer forbids a leading zero in
an all-digit identifier and Helm enforces it, so an abbreviation such as
`0412345` is written `g0412345`, as `git describe` writes every abbreviation.
The version claims no upstream release; it only sorts by date and differs for
every pin. The platform deploys digests, never tags.

Every run builds and pushes everything it reports, so it attests only what it
built. The program runs Substrate's publish command with overwrite on, which
otherwise builds nothing when the registry already holds the tag. Publishing a
pin again therefore moves its tags to new digests. A digest pinned earlier
stays in the registry, untagged.

### Publishing

Dispatch the workflow with the pins, each a full commit SHA on a `holos-*`
branch of its fork:

```sh
gh workflow run publish-images.yaml --repo holos-run/distro \
  -f substrate_sha=475f49b023352b47b8504ffead596953f28d7e7f \
  -f kagent_sha=fa2cb2361ee45da4b3e757a618128c298680d458
gh run watch --repo holos-run/distro \
  "$(gh run list --repo holos-run/distro --workflow publish-images.yaml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

Either input may be left out to republish one fork alone, such as
`-f kagent_sha=<pin>` by itself; the run fails if both are empty. The program
refuses a SHA that is not on one of the fork's `holos-*` branches before
building anything. GitHub serves any commit in a fork network from
every fork in it, so a commit fetched by SHA alone could be anyone's.

The Publish job pushes with the job's `GITHUB_TOKEN`, so no secret is stored
for it. Its summary lists every reference it pushed, as
`<name>:<tag>@<digest>`, and the Attest jobs, one per image and chart, attest
those digests.

ghcr.io refuses writes to a package for a moment after the push that creates
it, with `DENIED: requested access to the resource is denied`. The first
dispatch failed that way on each new package in turn. So the program retries
a publish whose output carries that message, up to 16 times, 20 seconds
apart. Each retry rebuilds from the job's warm cache and pushes the same
content again. Any other failure is not retried.

### Where the digests go

The run's output is the source of the digests: the Publish job's summary
lists each `<name>:<tag>@<digest>`, and the program writes the same subjects
as JSON with `-out`. A person copies them by hand into a CUE pin file and
commits it; the run never commits. The pin file does not exist yet: the
Substrate package and kagent items create it, under `holos/`, and their
components read it. Everything in the platform names these images and charts
by digest, pulled anonymously, with no pull secret and no private CA.

### Package visibility, once

A package created in the organization by a workflow is not necessarily
public. After the first run, list the packages and their visibility. Listing
packages needs the `read:packages` scope, which a `gh` login does not have by
default:

```sh
gh auth refresh -h github.com -s read:packages
gh api --paginate 'orgs/holos-run/packages?package_type=container' \
  --jq '.[] | select(.name | test("^(substrate|kagent)/")) | "\(.visibility)\t\(.name)"'
```

Make each private one public under the package's settings, Danger Zone,
Change visibility; the API cannot. In the same settings, check that Manage
Actions access gives holos-run/distro write access, which the next run needs
to push to a package that already exists. Then check an anonymous pull with
an empty docker config:

```sh
DOCKER_CONFIG="$(mktemp -d)" docker pull ghcr.io/holos-run/kagent/ui@sha256:<digest>
```

Checked on 2026-10-29, after
[run 40798960644](https://github.com/holos-run/distro/actions/runs/40798960644)
published the 2026-10-28 pins:

- **Public.** All 15 packages were public with no change in their settings.
  Their manifests resolve with an empty docker config. `docker pull` of
  `kagent/ui` and `helm pull` of the `kagent` chart work anonymously from the
  claude VM. A pod on `treasury-general-3` pulled `substrate/atelet` by digest
  with no pull secret.
- **Distro can write.** The run pushed to `substrate/envoy-dataplane` and
  `substrate/ate-idp-server`, which an earlier failed run had created, so
  holos-run/distro has write access to packages that already exist.
- **Not run.** The `gh api` listing above, which needs `read:packages`.

### Attestations

Each image and chart has a build provenance attestation from
`actions/attest-build-provenance`, pushed to the registry beside it. Verify
one by digest:

```sh
gh attestation verify oci://ghcr.io/holos-run/substrate/ateapi@sha256:<digest> \
  --repo holos-run/distro \
  --signer-workflow holos-run/distro/.github/workflows/publish-images.yaml
```

`--owner holos-run` instead of `--repo` accepts any holos-run repository's
workflow. The attestation records this repository's commit and the workflow
run that built the subject; the fork commit is the run's input. The images
carry it in their `org.opencontainers.image.revision` label; the charts carry
no revision, only their version, whose 7-character SHA names the commit.

### Running it locally

The program runs against any registry docker can push to, which is how it is
tested before a change to it merges. With a registry on localhost and a
docker-container builder on the host network, so BuildKit reaches the
registry:

```sh
docker run -d --name registry -p 127.0.0.1:5000:5000 registry:2
docker buildx create --name publish-images --driver docker-container \
  --driver-opt network=host --bootstrap
BUILDX_BUILDER=publish-images go run ./cmd/publish-images \
  -substrate-sha <sha> -kagent-sha <sha> \
  -registry localhost:5000/holos-run -platforms linux/amd64 -plain-http
```

`-plain-http` is for `helm push`; ko, buildx and imagetools already use plain
HTTP for localhost. kagent's controller image needs QEMU to build for arm64 on
an amd64 host, and the program checks the builder has it before building
anything. kagent's Makefile runs `docker buildx use` on the builder, which
makes it docker's current builder afterwards.
