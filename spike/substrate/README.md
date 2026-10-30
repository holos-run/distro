# Substrate spike on bare Talos

Throwaway. These files rerun the milestone "Substrate runs on Talos" by hand on
the `spike` cluster (Talos 1.14.4, Kubernetes 1.37.1, Cilium 1.20.4 with the
platform's CoreDNS). That cluster is built by
[providers/talos/README.md](../../providers/talos/README.md)
and the bootstrap procedure in [holos/README.md](../../holos/README.md). Nothing
here is a Holos component; the cluster is rebuilt afterwards. Tags without a
digest below (curl, busybox, aws-cli, the Istio charts, the Gateway API and
local-path URLs) are pinned by version only, which is enough for a throwaway.

Pins used on 2026-10-23:

| What | Version | Digest / commit |
|---|---|---|
| kagent-dev/substrate (no holos-run fork exists yet) | v0.7.0-alpha1 | commit 3c6b9adbf593a4a84308ae9f5a488622ecb76494 |
| chart substrate-crds | 0.7.0-alpha1 | sha256:a3584166a0c15f2e7a8c631d340394ea6aa9bb185d011723df5d663281a2004d |
| chart substrate-podcert | 0.7.0-alpha1 | sha256:fbae60edb5daef77a04e33b52b803ff0a1aa3eb0714ef8272bbc43df52642979 |
| chart substrate | 0.7.0-alpha1 | sha256:afa9fd33893193d2d4b26e3e3606e28d4e5fcc3e9f073d02d95fb8c85cebf758 |
| kubectl-ate (release asset, linux-amd64) | v0.7.0-alpha1 | sha256 8ce90703b8de18e4e271b31cda57d161b9595cc73333f5d387e19e1abbe24a89 |
| Istio charts base, istiod, cni, ztunnel | 1.31.3 | from oci://ghcr.io/istio/release/charts |
| Gateway API CRDs (standard) | v1.6.1 | |
| local-path-provisioner | v0.0.37 | |

## Setup

```bash
export KUBECONFIG=~/.config/holos/talos/spike/kubeconfig
cd spike/substrate                      # this directory
SPIKE=$PWD
OCI=oci://ghcr.io/kagent-dev/substrate/helm
V=0.7.0-alpha1

# A checkout of the fork at the pin, for ate-setup and the Postgres script.
git clone https://github.com/kagent-dev/substrate.git /tmp/substrate
git -C /tmp/substrate checkout v$V
(cd /tmp/substrate && go build -o /tmp/ate-setup ./cmd/ate-setup)

# kubectl ate
gh release download v$V -R kagent-dev/substrate -p kubectl-ate-linux-amd64 -O ~/.local/bin/kubectl-ate
chmod +x ~/.local/bin/kubectl-ate
```

## Substrate

```bash
# 0. A default StorageClass: the dev Postgres and the bundled RustFS need PVCs.
kubectl apply -k prereq

# 1. CRDs
helm upgrade --install substrate-crds $OCI/substrate-crds --version $V

# 2. Key pools: the six create commands the fork's helm-e2e workflow runs.
#    podcertificate-controller-cas creates its own namespace;
#    api-authentication-config creates ate-system, so it runs before the
#    ate-system pools, which fail without the namespace.
cd /tmp/substrate
/tmp/ate-setup --no-dev-env create podcertificate-controller-cas
/tmp/ate-setup --no-dev-env create api-authentication-config
/tmp/ate-setup --no-dev-env create jwt-authority-pool
/tmp/ate-setup --no-dev-env create actor-id-ca-pool
/tmp/ate-setup --no-dev-env create actor-id-ca-certs
/tmp/ate-setup --no-dev-env create egress-mitm-ca-pool
# Talos: replace the authentication config ate-setup wrote (see the file).
kubectl apply -f $SPIKE/ate-api-authentication.yaml

# 3. Pod certificate controller; it publishes the three trust bundles.
helm upgrade --install substrate-podcert $OCI/substrate-podcert --version $V \
  -n podcertificate-controller-system --wait

# 4. Dev PostgreSQL and the two connection Secrets.
./hack/install-postgres.sh
cd $SPIKE

# 5. Substrate with the bundled RustFS, which runs with the chart's default
#    credentials (rustfsadmin/rustfsadmin). atelet and the workers use hostPath.
kubectl label ns ate-system pod-security.kubernetes.io/enforce=privileged --overwrite
helm upgrade --install substrate $OCI/substrate --version $V -n ate-system \
  -f values-substrate.yaml --wait --timeout 10m

# 6. gVisor WorkerPool, atespace, template, actor.
kubectl apply -f workerpool.yaml
kubectl ate create atespace spike
kubectl ate create actor-template -f actor-template.yaml
kubectl ate get actor-templates -a spike      # wait for a GOLDEN TAG
kubectl ate create actor alpha -a spike --template whoami

# 7. Through the router's plaintext port from a pod in the cluster.
kubectl create ns spike-client
kubectl -n spike-client run curl --image=docker.io/curlimages/curl:8.11.1 \
  --restart=Never --command -- sleep 86400
kubectl -n spike-client exec curl -- \
  curl -sS -H 'ate-target-actor: spike/alpha' http://atenet-router.ate-system.svc/
kubectl ate get actors -a spike               # alpha ACTOR_STATE_RUNNING
# Every whoami actor reports Hostname "actor"; the router's access log
# (ate.actor.name=...) shows which actor answered.
```

## External RustFS (second pass)

```bash
K=$(openssl rand -hex 10); S=$(openssl rand -hex 20)
kubectl create ns rustfs
for ns in rustfs:rustfs-credentials ate-system:substrate-s3; do
  kubectl -n ${ns%%:*} create secret generic ${ns##*:} \
    --from-literal=AWS_ACCESS_KEY_ID=$K --from-literal=AWS_SECRET_ACCESS_KEY=$S
done
kubectl apply -f rustfs-external.yaml
kubectl -n rustfs wait --for=condition=complete job/bucket-init --timeout=180s

# Snapshots of existing actors and templates live in the bundled store; drop
# them before switching.
kubectl ate delete actor alpha -a spike
kubectl ate delete actor-template whoami -a spike
helm upgrade substrate $OCI/substrate --version $V -n ate-system \
  -f values-substrate.yaml -f values-substrate-external-s3.yaml --wait --timeout 10m
kubectl ate create actor-template -f actor-template.yaml
kubectl ate get actor-templates -a spike      # wait for a GOLDEN TAG
kubectl ate create actor gamma -a spike --template whoami
kubectl -n spike-client exec curl -- \
  curl -sS -o /dev/null -w '%{http_code}\n' -H 'ate-target-actor: spike/gamma' http://atenet-router.ate-system.svc/
# --mode sync: the default async suspend leaves the durable snapshot PENDING.
kubectl ate suspend actor gamma -a spike --mode sync
kubectl -n rustfs run s3ls --rm -i --restart=Never --image=amazon/aws-cli:2.17.0 \
  --overrides='{"spec":{"containers":[{"name":"s3ls","image":"amazon/aws-cli:2.17.0","args":["--endpoint-url","http://rustfs.rustfs.svc:9000","s3","ls","--recursive","s3://substrate-snapshots/"],"envFrom":[{"secretRef":{"name":"rustfs-credentials"}}],"env":[{"name":"AWS_REGION","value":"us-east-1"}]}]}}'
```

## Istio ambient and the Gateway

```bash
IOCI=oci://ghcr.io/istio/release/charts
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
kubectl create ns istio-system
kubectl label ns istio-system pod-security.kubernetes.io/enforce=privileged
helm upgrade --install istio-base $IOCI/base --version 1.31.3 -n istio-system --wait
helm upgrade --install istiod $IOCI/istiod --version 1.31.3 -n istio-system -f istio/values-istiod.yaml --wait
helm upgrade --install istio-cni $IOCI/cni --version 1.31.3 -n istio-system -f istio/values-cni.yaml --wait
helm upgrade --install ztunnel $IOCI/ztunnel --version 1.31.3 -n istio-system -f istio/values-ztunnel.yaml --wait

# Step 6
kubectl apply -f istio/ambient-test.yaml
kubectl -n ambient-test exec client -- curl -sS -o /dev/null -w '%{http_code}\n' http://whoami/
kubectl -n istio-system logs -l app=ztunnel --tail=50 | grep 'connection complete' | grep ambient-test

# Step 7
kubectl apply -f istio/gateway.yaml
P=$(kubectl -n istio-ingress get pod -l gateway.networking.k8s.io/gateway-name=spike -o jsonpath='{.items[0].metadata.name}')
# proxyv2 1.31 is distroless (no cat), so read the file from an ephemeral
# container running as the proxy's UID; baseline PSA refuses the default
# debug profile, which adds SYS_PTRACE.
echo '{"securityContext":{"runAsUser":1337,"runAsGroup":1337}}' > /tmp/dbg.json
kubectl -n istio-ingress debug $P --profile=baseline --custom=/tmp/dbg.json \
  --image=docker.io/library/busybox:1.36 --target=istio-proxy --container=certdump -- sleep 3600
kubectl -n istio-ingress exec $P -c certdump -- \
  cat /proc/1/root/run/podidentity.podcert.ate.dev/chain.pem | \
  openssl x509 -noout -subject -issuer -dates -ext subjectAltName
kubectl get podcertificaterequests -n istio-ingress   # SIGNERNAME podidentity.podcert.ate.dev/identity, Issued
```

The run on 2026-10-23 also recreated actor `alpha` from the new template after
the external-store switch, so the cluster ended with both `alpha` and `gamma`
Running; the commands above end with `gamma` only.
