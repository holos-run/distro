# The Planboard product's three images. The vendor's source is not in the
# distro: the build context is a checkout of Planboard, so this file works only
# with one, at the tag the build names (README.md, Building the Planboard
# images).
#
#   board   alpine with planboard and git, the actor's sync and board containers
#   agent   kagent's Claude harness with planboard copied in
#   plugin  scratch with the planboard plugin at /plugin, an image volume
#
# Nothing here pulls from Docker Hub: its anonymous limit is per public IP, which
# the VM shares with the garage's clusters, so a build could stop for an hour. The
# bases are on quay.io and ghcr.io. ko is not used because it replaces its base's
# entrypoint, which the harness needs. Every base is pinned by digest; the harness
# digest is the one kagent.cue pins as harnessImages.claude, and has to move with
# it, since an older harness cannot start under the controller.

# build compiles planboard. Static, so the same binary runs on alpine and on the
# harness image, and -trimpath and -buildvcs=false keep the path and the state of
# the checkout out of it, so a second build reproduces it.
FROM quay.io/projectquay/golang:1.27@sha256:ca79dfd71bc54f5bbec651a6cedbd0673f3e6d436b67781b8ea41bb7e0ec4233 AS build
ARG VERSION
WORKDIR /src
COPY . .
RUN test -n "$VERSION" \
    && CGO_ENABLED=0 GOTOOLCHAIN=local go build -trimpath -buildvcs=false \
        -ldflags "-X main.version=$VERSION" -o /out/planboard ./

# shared is what board and agent both add, as one layer. The extraheader is a
# placeholder: Substrate's egress gateway replaces a header only when the request
# carries one, and git sends Authorization only when challenged. The credential
# never enters the image or the sandbox.
FROM scratch AS shared
COPY --from=build /out/planboard /usr/local/bin/planboard
COPY <<'GITCONFIG' /etc/gitconfig
[http "https://github.com/"]
	extraheader = Authorization: Basic x
GITCONFIG

# board has no entrypoint of its own: the actor's template gives each container
# its command, since sync clones and board waits for the clone. uid 65532 is the
# uid kagent's harness binds port 80 as under gVisor.
FROM quay.io/lib/alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 AS board
RUN apk upgrade --no-cache && apk add --no-cache git
COPY --from=shared / /
ENV HOME=/data
USER 65532:65532

# agent adds to the harness and changes nothing else. The harness already has
# git and USER 65532.
FROM ghcr.io/kagent-dev/kagent/claude-harness:1.0.0-rc3@sha256:216613bf155d3d437765675144fee19c9045cb21cd2e481189f2dcae36c24b3b AS agent
COPY --from=shared / /

# plugin-files normalizes the modes, which come from the umask of whoever made
# the checkout, keeping the execute bit on the plugin's scripts.
FROM quay.io/lib/alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 AS plugin-files
COPY plugins/planboard /plugin
RUN chmod -R u=rwX,go=rX /plugin

# plugin is the plugin as kagent mounts it: the AgentTemplate's source names this
# image by digest with path plugin, the directory holding .claude-plugin/plugin.json.
FROM scratch AS plugin
COPY --from=plugin-files /plugin /plugin
