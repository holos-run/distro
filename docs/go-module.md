# Go module prerequisites

The distro is the Go module `go.holos.run/distro`. Its programs run from a
checkout of the repository root with `go run`, for example:

```sh
go run ./providers/proxmox/cmd/<name>
```

The module path is under the project's own domain, so renaming the repository
or making it public changes no import path. `https://go.holos.run/distro`
serves a `go-import` tag that points the go command at
`https://github.com/holos-run/private-distro`. If the repository is renamed,
that tag changes with it; see [Serving go.holos.run](#serving-goholosrun).

## While the repository is private

The repository will be public soon. Until then, working in a checkout needs
nothing beyond a Go toolchain, but fetching the module by its path, for example
with `go get` or `go install` from another module, needs two more things.

1. Tell Go the module is private, so it skips the public module proxy and
   checksum database. `GOPRIVATE` also sets `GONOPROXY` and `GONOSUMDB`.

   ```sh
   go env -w GOPRIVATE=go.holos.run/distro
   ```

   or, for one shell, `export GOPRIVATE=go.holos.run/distro`. `go env -w`
   replaces any existing value; list several patterns comma-separated.

2. Give git credentials for github.com. Go runs git with
   `GIT_TERMINAL_PROMPT=0`, so an HTTPS fetch without credentials fails
   without asking for a password. Use either the GitHub CLI as a credential
   helper, once you have logged in with it:

   ```sh
   gh auth login
   gh auth setup-git
   ```

   or rewrite the organization's HTTPS URLs to SSH, which uses your SSH key.
   Scoping the rewrite to `holos-run/` leaves your other GitHub fetches alone:

   ```sh
   git config --global url."git@github.com:holos-run/".insteadOf "https://github.com/holos-run/"
   ```

Once the repository is public, drop `go.holos.run/distro` from `GOPRIVATE`
(`go env -u GOPRIVATE` if it was the only entry) and the credentials are no
longer needed for it.

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

It is deployed by a Cloudflare Pages project connected to this repository:

| Setting | Value |
| --- | --- |
| Production branch | `main` |
| Framework preset | None |
| Build command | empty |
| Build output directory | `sites/go.holos.run` |
| Custom domain | `go.holos.run` |

Check a deployment, or a preview deployment's URL in place of the host:

```sh
curl -sL 'https://go.holos.run/distro?go-get=1' | grep go-import
curl -s 'https://go.holos.run/distro/providers/proxmox?go-get=1' | grep go-import
```
