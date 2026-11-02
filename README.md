# Bank of Pinky

Bank of Pinky is a Kubernetes distribution: as Debian is to Linux, this
distribution is to Kubernetes. The problem it aims to solve is distributing
new capabilities as broadly and openly as possible to secure our future.

Bank of Pinky is a brand, not the software: every name the distribution
chooses for itself, its namespaces, its Keycloak client and users, its
product titles, is built from `Brand` in [`holos/brand.cue`](holos/brand.cue),
so a vendor's distribution built from this repository sets its own brand in
one place and the names follow.

As with Debian, effective governance is a primary concern of the project.

## Ecosystem

- The distribution is built with the invaluable Planboard from [R.I. Pienaar](https://github.com/ripienaar).
- Configuration is handled by [CUE](https://github.com/cue-lang/cue), and
  rendered into manifests by the [holos](https://github.com/holos-run/holos) CLI.
- Integration tools are written in [Go](https://github.com/golang).
- Platforms are built and customized with [Kubernetes](https://github.com/kubernetes/kubernetes).

## Code

The repository is the Go module `go.holos.run/distro`. Providers live under
`providers/`, in two layers with the contracts between them in
`providers/infra/`: infrastructure providers, starting with
`providers/proxmox/`, make VMs, and Kubernetes providers, starting with
`providers/talos/`, turn them into a cluster. Each provider's programs live
under `providers/<provider>/cmd/<name>` and run from a checkout with
`go run ./providers/<provider>/cmd/<name>`. Programs that work on the platform
rather than a provider live under `cmd/<name>`, such as `cmd/quay-bootstrap`,
which mints the platform controller's Quay token
([holos/README.md](holos/README.md), Quay). See [the Go module](docs/go-module.md)
for how `go.holos.run/distro` resolves to this repository.

The platform, its components and the rendered manifests live under
[`holos/`](holos/README.md), a CUE module of its own beside the Go code.

## Documentation

- [holos/README.md](holos/README.md), the platform and every component.
- [docs/glossary.md](docs/glossary.md), the distro's own terms, such as
  atespace, ksa and ate-client ksa token.
- [docs/forks.md](docs/forks.md), the Substrate and kagent forks.
- [docs/adr/](docs/adr/README.md), architecture decision records.
