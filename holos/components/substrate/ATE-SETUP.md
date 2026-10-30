# ate-setup, step by step

The `substrate` component renders what `go run ./cmd/ate-setup deploy
ate-system` installs, without running it: ate-setup needs a cluster to render
and its rendering packages are internal. This table maps every step of
`DeployAteSystem` to the stage of the component that reproduces it, or to an
imperative step in [README.md, Substrate](../../README.md#substrate), or says
why it does not apply.

Paths are relative to the submodule, `holos/vendor/substrate`, at the pin in
`Substrate.commit` (`holos/substrate.cue`), and `steps/` is
`cmd/ate-setup/internal/steps/`. The pin is
`f475d8b4cc8ad071bac7ba8fcace30212f1b56b0`.

**Re-read this table against the new ate-setup on every bump.** Walk
`DeployAteSystem` in `steps/deploy.go` from the top, and the functions it
calls, and check each row: a new step, a new flag appended to a container,
a new file applied on its own, a new ConfigMap key or a file added to or
removed from `manifests/ate-install/base` each need a row and, usually, a
change to the component. Then update the line numbers and the pin above.

The stages, in `components/substrate/substrate.cue`:

- **Input**: `upstream/kustomization.yaml`, built by the Command generator.
- **CUE**: the Resources generator.
- **Patch**: the Kustomize transformer's `patches`.
- **Images**: the Kustomize transformer's `images`.
- **Argo CD**: the Application's sync options, retries and health.
- **By hand**: an imperative step in README.md, Substrate.

## `DeployAteSystem` (`steps/deploy.go:58`)

| # | Step | Source | What it does | Holos |
|---|---|---|---|---|
| 1 | `RequireCanonicalNamespace` | `steps/deploy.go:63`, `steps/env.go:104` | Refuses a namespace other than `ate-system` | Not needed: the render is in `ate-system` (`Substrate.namespace`) |
| 2 | `Cfg.CredentialProviders` | `steps/deploy.go:68`, `cmd/ate-setup/internal/config/config.go:677`, `:613` | Parses `--credential-provider`, one JSON object or an array of them, each a provider by name; `{"name":"k8s.io"}` is the bundled provider at `k8s-credential-provider.ate-system.svc:50051`. `HasKubernetesProvider` decides whether the bundled provider is deployed or removed (row 20) | CUE: one provider, `CredentialProvider`, `k8s.io` at that address (rows 20 and 21) |
| 3 | `Cfg.RequireTransferServiceAccount` | `steps/deploy.go:73`, `cmd/ate-setup/internal/config/config.go:308` | Requires a GCS transfer service account for the credential exchange | Not needed: the backend is S3; `ATE_API_SNAPSHOT_TRANSFER_SERVICE_ACCOUNT` is `""`, as ate-setup writes it on kind (row 9b) |
| 4 | `CheckCSIDriver` | `steps/deploy.go:79`, `steps/csi.go:98` | Validates `--setup-csi` | Not used: no CSI driver for external volumes |
| 5 | `clusterSnapshotLocation` | `steps/deploy.go:84`, `steps/apienv.go:193`, `internal/resources/validate.go:282` | Requires `--snapshot-location` unless the `PerTemplateSnapshotLocation` gate is on, and validates it: a bucket, no query or fragment, and each path segment ASCII letters, digits, `_` and `-`, none `atespaces` | CUE: `s3://substrate/`, RustFS's bucket `substrate` with an empty path, in `ate-api-server-envvars` (row 9b). ate-api-server checks the same at start (`cmd/ateapi/main.go`) |
| 6 | `requireNoWorkerPods` | `steps/deploy.go:87`, `steps/deploy.go:426` | Guards `--fake-data-plane` | Not used |
| 7 | `EnsureAteSystemNamespace` | `steps/deploy.go:92`, `steps/env.go:272` | Applies `ate-system-namespace.yaml` | Input: the same Namespace from `ate-controller.yaml`, in the base (kustomize refuses the file twice). Patch: `pod-security.kubernetes.io/enforce: privileged`, for atelet's host paths, and `argocd.argoproj.io/sync-options: Delete=false` on it and on `podcertificate-controller-system`, which hold the key pools and the database |
| 8 | `DeployCRDs` | `steps/deploy.go:99`, `steps/deploy.go:660` | Applies `generated/`, three CRDs and the controller's RBAC, and waits for them | Input: the four files. Argo CD: `SkipDryRunOnMissingResource` for the WorkerPool and SandboxConfig in the same sync |
| 9 | `EnsureAPIServerPrerequisites` | `steps/deploy.go:103`, `steps/prereqs.go:36` | Rows 9a to 9e | |
| 9a | `CreateJWTAuthorityPoolSecret`, `ensureSecret` actor-id-ca-pool, actor-id-ca-certs | `steps/prereqs.go:41-50`, `steps/create.go:61`, `:69`, `:122` | Creates `actor-id-jwt-pool` (`pool`, `jwks`), `actor-id-ca-pool` and `actor-id-ca-certs` (`ca.crt`) in `ate-system`, once | By hand: `ate-setup create jwt-authority-pool`, `actor-id-ca-pool`, `actor-id-ca-certs`, in that order |
| 9b | `CreateAPIServerEnvVars` | `steps/prereqs.go:53`, `steps/apienv.go:55` | Writes `ate-api-server-envvars` (roles, JWT issuer, transfer service account, snapshot location) and `ate-api-server-secret-envvars` (both DSNs, schema) | CUE: `EnvVars` as the ConfigMap; `DSNs` as the template of ExternalSecret `ate-api-server-secret-envvars`, from the generated `substrate-db-users` through SecretStore `substrate-db-users`; `sslmode=verify-full` |
| 9c | `applyPostgresServerCA` | `steps/apienv.go:154`, `steps/apienv.go:279` | Writes Secret `postgres-server-ca`, key `server-ca.pem`, from a local file | Patch: ate-api-server's `postgres-server-ca` volume is the `private-ca` ConfigMap's `ca.crt` as `server-ca.pem`, since the database's certificate is from the private CA |
| 9d | `ensureAPIConfig` | `steps/prereqs.go:57`, `steps/prereqs.go:74`, `steps/create.go:138` | Writes `ate-api-config`, `apiconfig.textproto`, log level `info` | CUE: `APIConfig` |
| 9e | `CreateAPIAuthenticationConfig` | `steps/prereqs.go:61-66`, `steps/create.go:174`, `:199`, `:223` | Writes `ate-api-authentication` with the discovered issuer, adding the CA and token files only for `https://kubernetes.default.svc` | CUE: `Authentication`, issuer `Cluster.serviceAccountIssuer` (`https://10.20.0.50:6443` on treasury) with both files, since Talos turns anonymous discovery off |
| 10 | `DeployPodCertificateController` | `steps/deploy.go:109`, `steps/deploy.go:214` | Rows 10a to 10c | |
| 10a | `EnsurePodCertificateCAs` | `steps/deploy.go:217`, `steps/prereqs.go:90`, `steps/create.go:102` | Creates `service-dns-ca-pool`, `pod-identity-ca-pool`, `postgres-ca-pool` in `podcertificate-controller-system` | By hand: `ate-setup create podcertificate-controller-cas`, first |
| 10b | Apply `pod-certificate-controller.yaml`, size10 overlay, `WORKERS_PER_SIGNER` | `steps/deploy.go:220-240` | The controller, its namespace and RBAC | Input: the base file. size10 and `--podcert-workers-per-signer` are not used; the file's `WORKERS_PER_SIGNER` is 1 |
| 10c | Rollout and `WaitForPodCertificateTrustBundles` | `steps/deploy.go:241-244`, `steps/prereqs.go:105` | Waits for the three ClusterTrustBundles | Argo CD: health and retries; every pod that projects a bundle waits in ContainerCreating until it exists. README check lists them |
| 11 | `SetupCSI` | `steps/deploy.go:112`, `steps/csi.go:111` | Installs a CSI driver for external volumes | Not used |
| 12 | `DeploySandboxConfig` | `steps/deploy.go:116`, `steps/deploy.go:587` | Applies `sandboxconfig-validation.yaml`, the CEL ValidatingAdmissionPolicy, then `sandboxconfig-gvisor.yaml`, `gvisor-default` | Input: both files. Its assets are `gs://gvisor/...`, read anonymously |
| 13 | `applyOtelConfig` | `steps/deploy.go:123`, `steps/overlay.go:601` | Applies `ate-otel-config.yaml`, GKE's managed collector | Input: the base's copy. Patch: its data replaced with `OTel`, every exporter `none` and logs `console`, and `holos.run/config-hash` over it on every reader: ate-api-server, ate-controller, atelet, atenet-router and atenet-egress |
| 14 | `planPostgres`, `deployPostgres` | `steps/deploy.go:132-138`, `steps/postgres.go:127`, `:143` | With no DSN, applies the bundled StatefulSet `postgres/postgres.yaml` and runs `pkg/postgressetup` in it with psql | CUE: CloudNativePG Cluster `substrate-db` (one instance, `enablePDB: false`, server certificate from `private-ca`), and Job `substrate-db-setup`, an Argo CD Sync hook running `pkg/postgressetup/setup.sql` (Input: ConfigMap `substrate-db-setup`) with `Config.PSQLArgs`'s variables (`pkg/postgressetup/setup.go:52`) in one transaction, as `Script` (`:73`) does |
| 15 | `renderSystemManifests` | `steps/deploy.go:140`, `steps/overlay.go:150` | Rows 15a to 15e | |
| 15a | `SystemOverlay` | `steps/overlay.go:88`, `:151` | The envoy, non-kind overlay: `manifests/ate-install/base`. At this pin atelet adds `CHOWN`, `FOWNER` and `FSETID` beside `DAC_OVERRIDE` (`manifests/ate-install/atelet.yaml:287-290`), for image layers owned by other uids, and the router's Envoy bootstrap `atenet-router-envoy-config` has `ads_config.api_type: DELTA_GRPC` (`manifests/ate-install/atenet-router.yaml:92`) | Input: the base, both changes with it. Patch: its PodMonitoring `atenet-router-envoy` deleted, and its NetworkPolicy `postgres`, for the bundled database, which is not installed. The ConfigMap change rolls nothing (row 21): README.md, Substrate, Bumping the pin, restarts the router by hand |
| 15b | `setIDPServerIssuer` | `steps/overlay.go:155`, `steps/idpserver.go:56` | Appends `--issuer=<actorJWT.issuer>` to ate-idp-server | Patch: `--issuer=https://idp.ate-system.svc` (`Substrate.issuer`) |
| 15c | `patchAtenetRouterAllowedSPIFFEIDs` | `steps/overlay.go:162`, `:302`, `:314` | Appends `--ingress-allowed-spiffe-ids` to `atenet-router` containers/0, after a test of its name | Patch: the same JSON 6902 shape, with `AteGateway.spiffeID` and `Kagent.controller.spiffeID` |
| 15d | `dockerfileImage`, `patchEnvoyDataplaneImage` | `steps/overlay.go:166-170`, `:355` | Replaces `${ENVOY_DATAPLANE_IMAGE}` | Patch: atenet-router containers/1 `image`, tested by name, set to `envoy-dataplane` by digest (kustomize's `images` cannot match the placeholder) |
| 15e | `ResolveManifestBytes`, `injectPreviewArg` | `steps/overlay.go:172`, `steps/env.go:239`, `steps/preview.go:53` | Builds each `ko://` image and adds `--preview=` | Images: each `ko://go.ate.dev/substrate/cmd/<path>` to `ghcr.io/holos-run/substrate/<name>@<digest>` (`Substrate.digests`). Patch: `--preview=PerTemplateSnapshotLocation` (`PreviewGates`) appended to ate-api-server alone: every ko binary accepts the flag (`internal/preview`), and ate-api-server is the one that reads this gate (`cmd/ateapi/main.go`); see `--preview` gates, below |
| 16 | `removeFakeWorkersync` | `steps/deploy.go:145`, `:466` | Removes the fake data plane | Not used |
| 17 | `applyWithAPIServerEnvHash` | `steps/deploy.go:148`, `steps/apienv.go:345` | Rows 17a to 17d, then applies the bundle | Input and Argo CD |
| 17a | `stampAPIServerEnvHash` | `steps/apienv.go:354`, `:449` | `ate.dev/env-hash` on ate-api-server's pod template, over the envvars ConfigMap and Secret | Patch: `holos.run/config-hash`, over `EnvVars`, `DSNs`, `Authentication`, `APIConfig` and `OTel` as written in CUE. A password rotation needs a rollout restart by hand |
| 17b | `setAPIServerAuthzArgs` | `steps/apienv.go:357`, `:374`, `:406` | Through `setAPIServerFlag`, replaces every `--authz-bootstrap-owners` on the ate-api-server container with one | Patch: `--authz-bootstrap-owners=system:serviceaccount:ate-system:ate-client,spiffe://cluster.local/ns/kagent/sa/kagent-controller`, appended; the base carries none |
| 17c | `setAPIServerEgressGatewayArgs` | `steps/apienv.go:360`, `:389`, `:406` | With `ATE_EGRESS_GATEWAY_EXTRA_SPIFFE_IDS` set, passes `--egress-gateway-spiffe-id=` for atenet-egress's own ID (`internal/installdefaults/installdefaults.go:123`) and then each extra, one flag each; with none, removes the flag, so ate-api-server's default, atenet-egress's ID alone, applies (`cmd/ateapi/main.go:97`) | Not needed: no client but atenet-egress holds the egress gateway role, the base carries no flag, and the default is the same ID |
| 17d | `sharedBootstrapOwnerWarning` | `steps/apienv.go:363`, `:172` | Warns that the `ate-client` ksa is an owner | README, Owners: who may mint an ate-client ksa token |
| 18 | `reconcileCloudSQLProxySidecar` | `steps/deploy.go:153`, `steps/cloudsql.go:215` | Cloud SQL Auth Proxy sidecar | Not used |
| 19 | `EnsureEgressMITMCAPoolSecret` | `steps/deploy.go:158`, `steps/create.go:96`, `:75` | Creates `egress-mitm-ca-pool` | By hand: `ate-setup create egress-mitm-ca-pool` |
| 20 | `deployK8sCredentialProvider` | `steps/deploy.go:163-167`, `steps/credprovider.go:43`, `:60` | With the bundled provider on the list (row 2), applies `egress-credential-injection/namespace-policy.yaml` only if missing, then `k8s-credential-provider.yaml`, whose ClusterRoleBinding lets the provider get every Secret in the cluster; without it, `removeK8sCredentialProvider` deletes a provider an earlier install left | Input: both. Patch: the policy's `namespace-policy.yaml` replaced with `NamespacePolicy`, atespace `kagent` to namespace `kagent`, which git holds, so an edit by hand is reverted; `holos.run/config-hash` over it on the provider; and ClusterRoleBinding `k8s-credential-provider-secret-reader` deleted. The ClusterRole stays, for a RoleBinding in each allowed namespace, which that namespace's component renders (kagent's for `kagent`) |
| 21 | `applyAtenetEgress` | `steps/deploy.go:171`, `steps/overlay.go:563`, `:231` | Rows 21a and 21b, then a rollout restart of a gateway already running whenever a provider is set | Input: `atenet-egress.yaml`. A change to the flags, the image or `OTel` changes the pod template, which rolls it. A change to ConfigMap `atenet-egress`, or the router's `atenet-router-envoy-config`, does not: the input stage is a command's output, which CUE cannot hash. README.md, Substrate, Bumping the pin, restarts both by hand when a bump changes them |
| 21a | `patchAtenetEgressInject`, `emitEgressInjectFlags` | `steps/overlay.go:274`, `:363`, `:416` | Replaces the `#ATE_EGRESS_INJECT_FLAGS` YAML comment with, for each provider in order, `--credential-provider-name`, `--credential-provider-address` and `--credential-provider-server-name`, then `--credential-provider-ca-file` and `--credential-provider-client-cert` once, which every provider shares | Patch: the five flags, in that order, appended to `ext-proc`, containers/1, tested by name; kustomize drops the comment |
| 21b | `patchEnvoyDataplaneImage` | `steps/overlay.go:278` | `${ENVOY_DATAPLANE_IMAGE}` in the egress Deployment | Patch: atenet-egress containers/0 `image` (`envoy`) |
| 22 | Rollout waits | `steps/deploy.go:175-193` | ate-api-server, ate-idp-server, ate-controller, atenet-router, atenet-egress, atelet, k8s-credential-provider | Argo CD: health |
| 23 | `waitFakeWorkersync` | `steps/deploy.go:194` | Fake data plane | Not used |
| 24 | `applyOtelEndpointOverride` | `steps/deploy.go:197`, `steps/overlay.go:630` | Benchmark collector override | Not used |

## Beyond `deploy ate-system`

| Step | Source | Holos |
|---|---|---|
| atelet without the GKE image credential provider | `manifests/ate-install/kind/atelet/kustomization.yaml` | Patch: the two `--image-credential-provider-*` args (the first two, tested), their two mounts and their two host-path volumes removed. The `cloud.google.com/compute-class` toleration stays: it tolerates a taint no node has |
| atelet trusting the private root | None upstream: a GKE install pulls from public registries | Patch: the `private-ca` ConfigMap mounted at `/etc/ssl/private-ca` and `SSL_CERT_DIR=/etc/ssl/certs:/etc/ssl/private-ca` on the atelet container, so it pulls actor images from Quay |
| The object store plugin on S3 | `manifests/ate-install/kind/atelet/kustomization.yaml`, `manifests/ate-install/kind/ate-api-server/kustomization.yaml` | Patch: `ATE_STORAGE_BACKEND=s3`, `AWS_REGION=us-east-1`, `AWS_ENDPOINT_URL=http://rustfs-svc.rustfs.svc:9000`, `AWS_S3_USE_PATH_STYLE=true` and the keys from the copy of `rustfs/rustfs-substrate` (CUE: ExternalSecret and SecretStore `rustfs`) on both `objectstore-plugin` sidecars |
| A WorkerPool | `ate-setup deploy demo ...` makes one per demo | CUE: WorkerPool `gvisor` in the privileged namespace `ate-workers`, `ateworker-gvisor` by digest, on `holos.run/nodepool: general`, with kagent's two labels |
| The atespace, actor templates and actors | `kubectl ate create ...` | By hand: README.md, Substrate |
| `--preview` gates (`ATE_PREVIEW`) | `steps/preview.go:53` | Patch: `PerTemplateSnapshotLocation` on ate-api-server (`PreviewGates`), the gate kagent's own installer enables (kagent `go/core/pkg/install/plan.go`). Since upstream #3357 (`d86746d8`) the API server refuses an ActorTemplate that sets `snapshotConfig.storageLocation` while `PerTemplateSnapshotLocation` is off (`api/ateapi/v1/ateapi.proto`, `+k8s:ifDisabled(PerTemplateSnapshotLocation)=+k8s:forbidden`), where before it accepted and ignored the field. kagent sets it on every template from the Harness's `substrate.snapshotPolicy.location`, a required field (README.md, kagent, Agents and the worker pool), so without the gate the controller could not create an agent's template on this pin. With it, an agent's snapshots go under the Harness's location, `s3://substrate/kagent/`, which the allowlist (#2784) accepts, instead of the cluster `s3://substrate/` |
| The installer scripts | `hack/install-ate.sh`, `hack/install-ate-kind.sh` | Deleted upstream at this pin; `cmd/ate-setup` is the one installer, and the manifests' comments name it |
