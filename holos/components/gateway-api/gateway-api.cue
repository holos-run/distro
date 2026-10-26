package holos

// The Gateway API CRDs, standard channel, installed ahead of Istio so the
// cluster's Gateway API version is the platform's choice rather than a side
// effect of the mesh.
//
// v1.6 is the release Istio 1.31 is built against (sigs.k8s.io/gateway-api
// v1.6.0 in its go.mod; istio.io names v1.6.0 on release-1.31 and v1.6.1 on
// master). v1.6.3 is the latest patch of that minor; its CRDs differ from
// v1.6.1's only in description text. Move with Istio, not ahead of it.
//
// The standard channel serves ListenerSet as gateway.networking.k8s.io/v1,
// and TLSRoute as v1 too. Istio 1.31 watches ListenerSet v1 without a
// feature flag.
//
// vendor/v1.6.3/standard-install.yaml is the release asset, unmodified:
// https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/standard-install.yaml
// sha256:356c2b8e286a964dc20995435659ad1095386329974793af10bbfe3eff977fe5
//
// Besides the CRDs it holds the safe-upgrades ValidatingAdmissionPolicy and
// its binding, which the API server evaluates itself (CEL, no webhook): it
// refuses replacing these CRDs with an older bundle version or with the
// experimental channel.
GatewayAPIVersion: "v1.6.3"

holos: spec: artifacts: [(#FileArtifact & {
	file: "vendor/\(GatewayAPIVersion)/standard-install.yaml"
}).artifact]
