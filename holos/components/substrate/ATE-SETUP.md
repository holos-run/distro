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
`475f49b023352b47b8504ffead596953f28d7e7f`.

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

## `DeployAteSystem` (`steps/deploy.go:57`)

| # | Step | Source | What it does | Holos |
|---|---|---|---|---|
| 1 | `RequireCanonicalNamespace` | `steps/deploy.go:62`, `steps/env.go:104` | Refuses a namespace other than `ate-system` | Not needed: the render is in `ate-system` (`Substrate.namespace`) |
| 2 | `Cfg.CredentialProvider` | `steps/deploy.go:67`, `cmd/ate-setup/internal/config/config.go:612` | Parses `--credential-provider`; `{"name":"k8s.io"}` is the bundled provider at `k8s-credential-provider.ate-system.svc:50051` | CUE: `CredentialProvider` is `k8s.io` at that address (rows 20 and 21) |
| 3 | `Cfg.RequireTransferServiceAccount` | `steps/deploy.go:72`, `cmd/ate-setup/internal/config/config.go:299` | Requires a GCS transfer service account for the credential exchange | Not needed: the backend is S3; `ATE_API_SNAPSHOT_TRANSFER_SERVICE_ACCOUNT` is `""`, as ate-setup writes it on kind (row 9b) |
| 4 | `CheckCSIDriver` | `steps/deploy.go:78`, `steps/csi.go:103` | Validates `--setup-csi` | Not used: no CSI driver for external volumes |
| 5 | `clusterSnapshotLocation` | `steps/deploy.go:83`, `steps/apienv.go:191` | Requires `--snapshot-location` | CUE: `s3://substrate/`, RustFS's bucket `substrate`, in `ate-api-server-envvars` (row 9b) |
| 6 | `requireNoWorkerPods` | `steps/deploy.go:86`, `steps/deploy.go:425` | Guards `--fake-data-plane` | Not used |
| 7 | `EnsureAteSystemNamespace` | `steps/deploy.go:91`, `steps/env.go:272` | Applies `ate-system-namespace.yaml` | Input: the same Namespace from `ate-controller.yaml`, in the base (kustomize refuses the file twice). Patch: `pod-security.kubernetes.io/enforce: privileged`, for atelet's host paths, and `argocd.argoproj.io/sync-options: Delete=false` on it and on `podcertificate-controller-system`, which hold the key pools and the database |
| 8 | `DeployCRDs` | `steps/deploy.go:98`, `steps/deploy.go:659` | Applies `generated/`, three CRDs and the controller's RBAC, and waits for them | Input: the four files. Argo CD: `SkipDryRunOnMissingResource` for the WorkerPool and SandboxConfig in the same sync |
| 9 | `EnsureAPIServerPrerequisites` | `steps/deploy.go:102`, `steps/prereqs.go:36` | Rows 9a to 9f | |
| 9a | `CreateJWTAuthorityPoolSecret`, `ensureSecret` actor-id-ca-pool, actor-id-ca-certs | `steps/prereqs.go:41-50`, `steps/create.go:61`, `:69`, `:122` | Creates `actor-id-jwt-pool` (`pool`, `jwks`), `actor-id-ca-pool` and `actor-id-ca-certs` (`ca.crt`) in `ate-system`, once | By hand: `ate-setup create jwt-authority-pool`, `actor-id-ca-pool`, `actor-id-ca-certs`, in that order |
| 9b | `CreateAPIServerEnvVars` | `steps/prereqs.go:53`, `steps/apienv.go:55` | Writes `ate-api-server-envvars` (roles, JWT issuer, transfer service account, snapshot location) and `ate-api-server-secret-envvars` (both DSNs, schema) | CUE: `EnvVars` as the ConfigMap; `DSNs` as the template of ExternalSecret `ate-api-server-secret-envvars`, from the generated `substrate-db-users` through SecretStore `substrate-db-users`; `sslmode=verify-full` |
| 9c | `applyPostgresServerCA` | `steps/apienv.go:154`, `steps/apienv.go:277` | Writes Secret `postgres-server-ca`, key `server-ca.pem`, from a local file | Patch: ate-api-server's `postgres-server-ca` volume is the `private-ca` ConfigMap's `ca.crt` as `server-ca.pem`, since the database's certificate is from the private CA |
| 9d | `ensureAPIConfig` | `steps/prereqs.go:57`, `steps/prereqs.go:74`, `steps/create.go:138` | Writes `ate-api-config`, `apiconfig.textproto`, log level `info` | CUE: `APIConfig` |
| 9e | `CreateAPIAuthenticationConfig` | `steps/prereqs.go:61-66`, `steps/create.go:174`, `:199`, `:223` | Writes `ate-api-authentication` with the discovered issuer, adding the CA and token files only for `https://kubernetes.default.svc` | CUE: `Authentication`, issuer `Cluster.serviceAccountIssuer` (`https://10.20.0.50:6443` on treasury) with both files, since Talos turns anonymous discovery off |
| 10 | `DeployPodCertificateController` | `steps/deploy.go:108`, `steps/deploy.go:213` | Rows 10a to 10c | |
| 10a | `EnsurePodCertificateCAs` | `steps/deploy.go:216`, `steps/prereqs.go:90`, `steps/create.go:102` | Creates `service-dns-ca-pool`, `pod-identity-ca-pool`, `postgres-ca-pool` in `podcertificate-controller-system` | By hand: `ate-setup create podcertificate-controller-cas`, first |
| 10b | Apply `pod-certificate-controller.yaml`, size10 overlay, `WORKERS_PER_SIGNER` | `steps/deploy.go:219-239` | The controller, its namespace and RBAC | Input: the base file. size10 and `--podcert-workers-per-signer` are not used; the file's `WORKERS_PER_SIGNER` is 1 |
| 10c | Rollout and `WaitForPodCertificateTrustBundles` | `steps/deploy.go:240-243`, `steps/prereqs.go:105` | Waits for the three ClusterTrustBundles | Argo CD: health and retries; every pod that projects a bundle waits in ContainerCreating until it exists. README check lists them |
| 11 | `SetupCSI` | `steps/deploy.go:111`, `steps/csi.go:116` | Installs a CSI driver for external volumes | Not used |
| 12 | `DeploySandboxConfig` | `steps/deploy.go:115`, `steps/deploy.go:586` | Applies `sandboxconfig-validation.yaml`, the CEL ValidatingAdmissionPolicy, then `sandboxconfig-gvisor.yaml`, `gvisor-default` | Input: both files. Its assets are `gs://gvisor/...`, read anonymously |
| 13 | `applyOtelConfig` | `steps/deploy.go:122`, `steps/overlay.go:592` | Applies `ate-otel-config.yaml`, GKE's managed collector | Input: the base's copy. Patch: its data replaced with `OTel`, every exporter `none` and logs `console`, and `holos.run/config-hash` over it on every reader: ate-api-server, ate-controller, atelet, atenet-router and atenet-egress |
| 14 | `planPostgres`, `deployPostgres` | `steps/deploy.go:131-137`, `steps/postgres.go:127`, `:143` | With no DSN, applies the bundled StatefulSet `postgres/postgres.yaml` and runs `pkg/postgressetup` in it with psql | CUE: CloudNativePG Cluster `substrate-db` (one instance, `enablePDB: false`, server certificate from `private-ca`), and Job `substrate-db-setup`, an Argo CD Sync hook running `pkg/postgressetup/setup.sql` (Input: ConfigMap `substrate-db-setup`) with `Config.PSQLArgs`'s variables (`pkg/postgressetup/setup.go:52`) in one transaction, as `Script` (`:73`) does |
| 15 | `renderSystemManifests` | `steps/deploy.go:139`, `steps/overlay.go:150` | Rows 15a to 15e | |
| 15a | `SystemOverlay` | `steps/overlay.go:88`, `:151` | The envoy, non-kind overlay: `manifests/ate-install/base` | Input: the base. Patch: its PodMonitoring `atenet-router-envoy` deleted, and its NetworkPolicy `postgres`, for the bundled database, which is not installed |
| 15b | `setIDPServerIssuer` | `steps/overlay.go:155`, `steps/idpserver.go:56` | Appends `--issuer=<actorJWT.issuer>` to ate-idp-server | Patch: `--issuer=https://idp.ate-system.svc` (`Substrate.issuer`) |
| 15c | `patchAtenetRouterAllowedSPIFFEIDs` | `steps/overlay.go:162`, `:302`, `:314` | Appends `--ingress-allowed-spiffe-ids` to `atenet-router` containers/0, after a test of its name | Patch: the same JSON 6902 shape, with `AteGateway.spiffeID` and `Kagent.controller.spiffeID` |
| 15d | `dockerfileImage`, `patchEnvoyDataplaneImage` | `steps/overlay.go:166-170`, `:355` | Replaces `${ENVOY_DATAPLANE_IMAGE}` | Patch: atenet-router containers/1 `image`, tested by name, set to `envoy-dataplane` by digest (kustomize's `images` cannot match the placeholder) |
| 15e | `ResolveManifestBytes`, `injectPreviewArg` | `steps/overlay.go:172`, `steps/env.go:239`, `steps/preview.go:53` | Builds each `ko://` image and adds `--preview=` | Images: each `ko://go.ate.dev/substrate/cmd/<path>` to `ghcr.io/holos-run/substrate/<name>@<digest>` (`Substrate.digests`). No preview gates, so nothing to add |
| 16 | `removeFakeWorkersync` | `steps/deploy.go:144`, `:465` | Removes the fake data plane | Not used |
| 17 | `applyWithAPIServerEnvHash` | `steps/deploy.go:147`, `steps/apienv.go:343` | Rows 17a to 17c, then applies the bundle | Input and Argo CD |
| 17a | `stampAPIServerEnvHash` | `steps/apienv.go:352`, `:413` | `ate.dev/env-hash` on ate-api-server's pod template, over the envvars ConfigMap and Secret | Patch: `holos.run/config-hash`, over `EnvVars`, `DSNs`, `Authentication`, `APIConfig` and `OTel` as written in CUE. A password rotation needs a rollout restart by hand |
| 17b | `setAPIServerAuthzArgs` | `steps/apienv.go:355`, `:370` | Appends `--authz-bootstrap-owners` | Patch: `system:serviceaccount:ate-system:ate-client,spiffe://cluster.local/ns/kagent/sa/kagent-controller` |
| 17c | `sharedBootstrapOwnerWarning` | `steps/apienv.go:358`, `:172` | Warns that the `ate-client` ksa is an owner | README, Owners: who may mint an ate-client ksa token |
| 18 | `reconcileCloudSQLProxySidecar` | `steps/deploy.go:152`, `steps/cloudsql.go:215` | Cloud SQL Auth Proxy sidecar | Not used |
| 19 | `EnsureEgressMITMCAPoolSecret` | `steps/deploy.go:157`, `steps/create.go:96`, `:75` | Creates `egress-mitm-ca-pool` | By hand: `ate-setup create egress-mitm-ca-pool` |
| 20 | `deployK8sCredentialProvider` | `steps/deploy.go:162`, `steps/credprovider.go:43` | Applies `egress-credential-injection/namespace-policy.yaml` only if missing, then `k8s-credential-provider.yaml`, whose ClusterRoleBinding lets the provider get every Secret in the cluster | Input: both. Patch: the policy's `namespace-policy.yaml` replaced with `NamespacePolicy`, atespace `kagent` to namespace `kagent`, which git holds, so an edit by hand is reverted; `holos.run/config-hash` over it on the provider; and ClusterRoleBinding `k8s-credential-provider-secret-reader` deleted. The ClusterRole stays, for a RoleBinding in each allowed namespace, which that namespace's component renders (kagent's for `kagent`) |
| 21 | `applyAtenetEgress` | `steps/deploy.go:170`, `steps/overlay.go:554`, `:231` | Rows 21a and 21b, then a rollout restart of a gateway already running whenever a provider is set | Input: `atenet-egress.yaml`. A change to the flags, the image or `OTel` changes the pod template, which rolls it. A change to ConfigMap `atenet-egress`, or the router's `atenet-router-envoy-config`, does not: the input stage is a command's output, which CUE cannot hash. README.md, Substrate, Bumping the pin, restarts both by hand when a bump changes them |
| 21a | `patchAtenetEgressInject` | `steps/overlay.go:274`, `:363`, `:411` | Replaces the `#ATE_EGRESS_INJECT_FLAGS` YAML comment with five `--credential-provider-*` flags | Patch: the five flags appended to `ext-proc`, containers/1, tested by name; kustomize drops the comment |
| 21b | `patchEnvoyDataplaneImage` | `steps/overlay.go:278` | `${ENVOY_DATAPLANE_IMAGE}` in the egress Deployment | Patch: atenet-egress containers/0 `image` (`envoy`) |
| 22 | Rollout waits | `steps/deploy.go:174-192` | ate-api-server, ate-idp-server, ate-controller, atenet-router, atenet-egress, atelet, k8s-credential-provider | Argo CD: health |
| 23 | `waitFakeWorkersync` | `steps/deploy.go:193` | Fake data plane | Not used |
| 24 | `applyOtelEndpointOverride` | `steps/deploy.go:196`, `steps/overlay.go:621` | Benchmark collector override | Not used |

## Beyond `deploy ate-system`

| Step | Source | Holos |
|---|---|---|
| atelet without the GKE image credential provider | `manifests/ate-install/kind/atelet/kustomization.yaml` | Patch: the two `--image-credential-provider-*` args (the first two, tested), their two mounts and their two host-path volumes removed. The `cloud.google.com/compute-class` toleration stays: it tolerates a taint no node has |
| atelet trusting the private root | None upstream: a GKE install pulls from public registries | Patch: the `private-ca` ConfigMap mounted at `/etc/ssl/private-ca` and `SSL_CERT_DIR=/etc/ssl/certs:/etc/ssl/private-ca` on the atelet container, so it pulls actor images from Quay |
| The object store plugin on S3 | `manifests/ate-install/kind/atelet/kustomization.yaml`, `manifests/ate-install/kind/ate-api-server/kustomization.yaml` | Patch: `ATE_STORAGE_BACKEND=s3`, `AWS_REGION=us-east-1`, `AWS_ENDPOINT_URL=http://rustfs-svc.rustfs.svc:9000`, `AWS_S3_USE_PATH_STYLE=true` and the keys from the copy of `rustfs/rustfs-substrate` (CUE: ExternalSecret and SecretStore `rustfs`) on both `objectstore-plugin` sidecars |
| A WorkerPool | `ate-setup deploy demo ...` makes one per demo | CUE: WorkerPool `gvisor` in the privileged namespace `ate-workers`, `ateworker-gvisor` by digest, on `holos.run/nodepool: general`, with kagent's two labels |
| The atespace, actor templates and actors | `kubectl ate create ...` | By hand: README.md, Substrate |
| `--preview` gates (`ATE_PREVIEW`) | `steps/preview.go:53` | None are enabled |
