# Holos Distro

The Holos Distribution, as Debian is to Linux the Holos Distro is to
Kubernetes.  The problem Holos aims to solve is distributing new capabilities
as broadly and openly as possible to secure our future.

As with Debian, effective governance is a primary concern of the project.

## Ecosystem

- Holos is built with the invaluable Planboard from [R.I. Pienaar](https://github.com/ripienaar).
- Configuration is handled by [CUE](https://github.com/cue-lang/cue).
- Integration tools are written in [Go](https://github.com/golang).
- Platforms are built and customized with [Kubernetes](https://github.com/kubernetes/kubernetes).

## Code

The repository is the Go module `go.holos.run/distro`. Providers live under
`providers/`, starting with `providers/proxmox/`; each provider's programs live
under `providers/<provider>/cmd/<name>` and run from a checkout with
`go run ./providers/<provider>/cmd/<name>`. Programs that work on the platform
rather than a provider live under `cmd/<name>`, such as `cmd/quay-bootstrap`,
which mints holos-controller's Quay token and the registry's robots
([holos/README.md](holos/README.md), Quay). See [the Go module](docs/go-module.md)
for how `go.holos.run/distro` resolves to this repository.

The Holos platform, its components and the rendered manifests live under
[`holos/`](holos/README.md), a CUE module of its own beside the Go code.
