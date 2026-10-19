# Holos Distro

The Holos Distribution, as Debian is to Linux the Holos Distro is to
Kubernetes.  The problem Holos aims to solve is distributing new capabilities
as broadly and openly as possible to secure our future.

As with Debian, effective governance is a primary concern of the project.

## Code

The repository is the Go module `go.holos.run/distro`. Providers live under
`providers/`, starting with `providers/proxmox/`; each provider's programs live
under `providers/<provider>/cmd/<name>` and run from a checkout with
`go run ./providers/<provider>/cmd/<name>`. The repository is private for now
and will be public soon; see [Go module prerequisites](docs/go-module.md) to
fetch the module by its path.
