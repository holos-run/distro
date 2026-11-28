# Getting started

The distro is climbed in three rungs, each a choice to go further: look at a
render, build a cluster on your own machine, then run it for real. This guide
is where the commands for the climb are written. Terms with a meaning of
their own here are in the [glossary](glossary.md).

## Rung 1: look

Clone, render, and read the manifests. There is no cluster on this rung, and
nothing is installed outside the clone.

The platform is CUE in `holos/`. A render turns it into plain Kubernetes
manifests in `holos/deploy/`, one file per resource, which are committed
beside the CUE and are what Argo CD syncs to a cluster. So a render of an
unchanged clone reproduces what is committed, and a render after an edit
shows, as a diff, everything the edit changes on every cluster.

You need git, curl, tar and bash, on Linux (x86_64 or arm64) or macOS (arm64),
and about 500 MB of disk.

### Render

```sh
git clone https://github.com/holos-run/distro.git
cd distro/holos
./tools.sh
./render.sh
git status
```

`tools.sh` downloads the four tools a render runs, holos, cue, helm and
kubectl, at the versions the committed manifests were rendered with, checks
each against its SHA-256, and puts them in `.tools/bin` at the top of the
clone. It also checks out the Substrate submodule under `holos/vendor/`,
whose install manifests one component renders from. It takes under a minute
and can be run again at any time; it downloads only what is missing.

`render.sh` checks those tools and the submodule first, and stops there,
having changed nothing, if one is missing or at another version. Then it
runs `cue vet ./...`, removes `deploy/clusters`, and runs
`holos render platform`: about 7 seconds for the vet and 10 for the render.

`git status` then prints nothing to commit. That is the result: the
manifests in git are exactly what the CUE renders, and CI holds every pull
request to it.

What was rendered is in `deploy/clusters/<cluster>/components/<component>/`.
The three clusters, `treasury`, `cartography` and `marina`, are the ones the
project runs in its own garage; `clusters.cue` describes them. A good first
read is one small component and the CUE it came from:

```sh
ls deploy/clusters/treasury/components/
ls deploy/clusters/treasury/components/cert-manager/
less components/cert-manager/cert-manager.cue
```

### Change the brand

Every name the distribution chooses for itself, its controllers'
namespaces, its Keycloak client and users, the titles a person reads, is
built from one value, `Brand` in `brand.cue`. An unchanged clone renders
Bank of the Salish Sea, with the slug `seabank`. Set your own in a file
beside it, as `brand.cue` describes, and render:

```sh
cat > my-brand.cue <<'EOF'
package holos

Brand: {name: "Example Bank", slug: "example-bank"}
EOF
./render.sh
git status --short -uall | less
```

Every file whose name held `seabank` is listed as deleted, and the same
file appears as new with `example-bank` in its place: the
`seabank-controller` and `seabank-authenticator` components' directories,
their Argo CD Applications, the management namespaces, the controller's
Keycloak and Quay credentials. About half as many are modified where
they stand, because they refer to one of those names. One of them shows both
fields at work:

```sh
git diff deploy/clusters/treasury/components/keycloak-realm/keycloakrealmimport-default.yaml
```

The realm's `displayName` goes from Bank of the Salish Sea to Example Bank,
and the client named `seabank-controller`, its service user and the Secrets they
read take the new slug. Nothing of the old name is left in the render:

```sh
grep -r seabank deploy | wc -l    # 0
```

Put the clone back as it was:

```sh
rm my-brand.cue
git restore deploy/clusters
git clean -fdq deploy/clusters
git status                        # nothing to commit
```

### Add a claim

A tenant gets its place on a cluster through a claim, one small file in
`projects/` that names the project, the clusters it lands on and its owners.
`projects/checkout.cue` is a sample. Copy it under a new name and render:

```sh
sed 's/"checkout"/"my-project"/' projects/checkout.cue > projects/my-project.cue
cat projects/my-project.cue
./render.sh
git status --short
```

The claim selects `treasury`, and only `treasury` changes. New there:

- `deploy/clusters/treasury/components/project-my-project/`, what the
  platform makes for the project: its namespace, the owners' RoleBinding,
  its Keycloak groups and the owner's user, its Quay organization, its Argo
  CD AppProject and Application, its wildcard certificate and listener, and
  its Substrate atespace;
- `components/argocd-apps/application-project-my-project.yaml`, the
  Application that syncs that directory;
- `deploy/clusters/treasury/projects/my-project/`, the directory the
  project's own Application syncs.

Changed there: the authenticator's allowlist gains the project's owner
group, in two files, and the Applications that sync after the new one each
move one sync wave later.

```sh
ls deploy/clusters/treasury/components/project-my-project/
git diff
```

Put the clone back:

```sh
rm projects/my-project.cue
git restore deploy/clusters
git clean -fdq deploy/clusters
git status                        # nothing to commit
```

`holos/README.md` is the reference for everything rendered here, and the
runbook of the garage's clusters: Projects for a claim's fields, and
`brand.cue` itself for what the brand does and does not name.
