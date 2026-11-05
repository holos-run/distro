# Holos Base Distribution

This repository represents the Holos base distribution branded as the fictional
Bank of the Salish Sea.  Holos is a Kubernetes distribution: as Debian is to
Linux and GNU, this distribution is to Kubernetes and the CNCF. The problems
Holos solves are:

 1. Distributing new platform capabilities as broadly and openly as possible to
    secure our future.
 2. Enable vendors and their customers to integrate software holistically and
    efficient into a cohesive and coherent platform, complete with rapid
    security updates and trustworthy provenance.

Bank of the Salish Sea is a fictional brand, not the software: every name the
distribution chooses for itself, its namespaces, its Keycloak client and users,
its product titles, is built from `Brand` in
[`holos/brand.cue`](holos/brand.cue), so a vendor's distribution built from
this repository sets its own brand in one place and the names follow.

As with Debian, effective governance is a primary concern of the project.
Derivative distributions are explicitly encouraged to serve customer in their
markets.

## Ecosystem

- The distribution is built with the invaluable Planboard from [R.I. Pienaar](https://github.com/ripienaar).
- Configuration is handled by [CUE](https://github.com/cue-lang/cue), and
  rendered into manifests by the [holos](https://github.com/holos-run/holos) CLI.
- Integration tools are written in [Go](https://github.com/golang).
- Platforms are built and customized with [Kubernetes](https://github.com/kubernetes/kubernetes).

## Demonstration

This repository demonstrates the integration of the following independent
projects into a holistic platform for the fictional Bank of the Salish Sea:

1. [agent-substrate](https://github.com/agent-substrate/substrate) - Zero-trust
   sandboxing for millions of agents on Kubernetes.
2. [kagent](https://github.com/kagent-dev/kagent) - Kubernetes native framework
   for building AI agents.
3. [toolhive](https://github.com/stacklok/toolhive) - The open source MCP
   platform trusted by developers and enterprises.
4. [CUE](https://cue.dev/) - The open source language thousands of
   organizations use to define, check, and generate configuration.
5. [istio](https://github.com/istio/istio) - Connect, secure, control, and
   observe services.
6. [secrets-manager](https://github.com/holos-run/secrets-manager) - Secrets
   Management integrated into the base platform so that everyone else can
   depend on reliable, consistent, and ubiquitous secrets management from the
   onset.
7. Integrated OIDC/SAML identity provider designed for federation with existing
   enterprise SSO identity providers.  Product engineering teams customize
   authorization behavior, customer security teams define authentication
   behavior.
8. Integrated OCI image repository for product engineering teams to customize
   and distribute their own software.
9. Integrated multi-tenant project structure modeled after GCP projects. Offers
   least-privilege owner / editor / viewer roles to start with.  Enables a
   clear path for product engineering teams to implement fine grained
   permissions as needed, and for their customers to claim ownership of their
   own project resources.


## The Path Forward

The component definition today are proven in production in regulated
environments for the use case of deploying and updating software capabilities.
However, three main gaps urgently need to be filled to support agentic
products.  Agentic workflows need well defined interfaces at the component
integration layer for:

1. Controls that meet regulatory obligations, and what specifically it means
   for vendors and customers to provide the implementation of zero or more
   controls.
2. Evaluations of the controls at runtime, and what specifically it means for
   vendors and customers to provide tests that verify the system is operating
   as it should be.
3. Evidence collected by observing the running system.  How customers
   efficiently collect and record durable evidence the system is well-behaved
   at a given point in time.

The path forward for Holos and the base distribution is to develop well
defined, composeable interfaces for each of these gaps at the platform
integration layer.  Open source projects and commercial vendors will then have
a well defined target to provide custom, differentiated implementations.

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
