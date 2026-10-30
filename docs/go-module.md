# The Go module

The distro is the Go module `go.holos.run/distro`. Its programs run from a
checkout of the repository root with `go run`, for example:

```sh
go run ./providers/talos/cmd/<name>
```

The module path is under the project's own domain, so renaming or moving the
repository changes no import path. `https://go.holos.run/distro` serves a
`go-import` tag that points the go command at
`https://github.com/holos-run/distro`. If the repository is renamed, that tag
changes with it; see [Serving go.holos.run](#serving-goholosrun).

The repository is public, so fetching the module by its path, for example
with `go get` or `go install` from another module, needs only a Go toolchain:
the public module proxy and checksum database serve it like any other module.
If you set `GOPRIVATE=go.holos.run/distro` while the repository was private,
remove it (`go env -u GOPRIVATE` if it was the only entry).

## Serving go.holos.run

`sites/go.holos.run/` is the whole site, plain HTML with no build step:

- `distro/index.html` carries the `go-import` and `go-source` tags.
- `distro/404.html` is the same page. Cloudflare Pages serves the nearest
  `404.html` for a missing path, and the go command reads `go-import` tags
  whatever the status code, so every package path under `go.holos.run/distro`
  resolves.
- `404.html` at the top keeps Pages from treating the site as a single-page
  application, which would answer every path with `index.html`.

CI checks that both `distro` pages name the module path in `go.mod`.

It is deployed by a Cloudflare Pages project whose git source is this
repository, `holos-run/distro`:

| Setting | Value |
| --- | --- |
| Git repository | `holos-run/distro` |
| Production branch | `main` |
| Framework preset | None |
| Build command | empty |
| Build output directory | `sites/go.holos.run` |
| Custom domain | `go.holos.run` |

Check a deployment, or a preview deployment's URL in place of the host:

```sh
curl -sL 'https://go.holos.run/distro?go-get=1' | grep go-import
curl -s 'https://go.holos.run/distro/providers/talos?go-get=1' | grep go-import
```
