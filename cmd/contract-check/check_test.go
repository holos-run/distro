package main

import (
	"bytes"
	"errors"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// reason is the exception treasury's webhook configurations carried while
// they took ADR 0001's Gateway path; the fixtures keep it.
const reason = "ADR 0001's Gateway webhook path, kept on treasury until its rebuild; see ADR 0003 and Talos_Kubernetes_Layer/rebuild-treasury-on-the-new-layer"

// TestRun checks each fixture tree under testdata. In want, $C/ stands for the
// case's clusters directory, testdata/<case>/clusters/.
func TestRun(t *testing.T) {
	for _, tc := range []struct {
		name       string
		violations int // 0 for a passing run
		want       string
	}{
		{
			name: "compliant",
			want: `
cluster treasury: 1 configuration, 1 Service and 1 pod template checked; 0 violations, 0 exceptions
`,
		},
		{
			// istio-base's configuration names the Service istiod renders.
			name: "cross-component",
			want: `
cluster treasury: 1 configuration, 1 Service and 1 pod template checked; 0 violations, 0 exceptions
`,
		},
		{
			// The compliant case in one file, with empty documents and a
			// Knative Service, which is not a core Service.
			name: "multi-document",
			want: `
cluster treasury: 1 configuration, 1 Service and 1 pod template checked; 0 violations, 0 exceptions
`,
		},
		{
			// Rule 1 once per webhook entry, a url: or no Service at all.
			name:       "url",
			violations: 3,
			want: `
$C/treasury/components/webhook/mutatingwebhookconfiguration-webhook.yaml: MutatingWebhookConfiguration webhook webhook mutate.webhook.example.com: rule 1, service not url: clientConfig.url is https://webhook.example.com:9443/mutate; name the Service by clientConfig.service instead
$C/treasury/components/webhook/mutatingwebhookconfiguration-webhook.yaml: MutatingWebhookConfiguration webhook webhook default.webhook.example.com: rule 1, service not url: clientConfig.url is https://webhook.example.com:9443/default; name the Service by clientConfig.service instead
$C/treasury/components/webhook/mutatingwebhookconfiguration-webhook.yaml: MutatingWebhookConfiguration webhook webhook none.webhook.example.com: rule 1, service not url: clientConfig names no Service; name the Service by clientConfig.service
cluster treasury: 1 configuration, 0 Services and 0 pod templates checked; 3 violations, 0 exceptions
`,
		},
		{
			// Two entries name the Service, and it is reported once. A
			// Service of its name with no namespace does not count.
			name:       "missing-service",
			violations: 1,
			want: `
$C/treasury/components/webhook/validatingwebhookconfiguration-webhook.yaml: ValidatingWebhookConfiguration webhook: rule 2, selector and not headless: Service webhook/webhook is not in the tree of cluster treasury ($C/treasury/components/other/service-webhook.yaml has a Service webhook with no metadata.namespace); render the Service, with a selector on the pods that serve it, in namespace webhook
cluster treasury: 1 configuration, 0 Services and 0 pod templates checked; 1 violation, 0 exceptions
`,
		},
		{
			// A Service with a hand-made EndpointSlice.
			name:       "selectorless",
			violations: 1,
			want: `
$C/treasury/components/webhook/validatingwebhookconfiguration-webhook.yaml: ValidatingWebhookConfiguration webhook: rule 2, selector and not headless: Service webhook/webhook ($C/treasury/components/webhook/service-webhook.yaml) has no spec.selector; give it a selector on the pods that serve it, not hand-made endpoints
cluster treasury: 1 configuration, 1 Service and 0 pod templates checked; 1 violation, 0 exceptions
`,
		},
		{
			name:       "headless",
			violations: 1,
			want: `
$C/treasury/components/webhook/validatingwebhookconfiguration-webhook.yaml: ValidatingWebhookConfiguration webhook: rule 2, selector and not headless: Service webhook/webhook ($C/treasury/components/webhook/service-webhook.yaml) is headless, clusterIP: None; give it a cluster IP
cluster treasury: 1 configuration, 1 Service and 1 pod template checked; 1 violation, 0 exceptions
`,
		},
		{
			// The only template the selector matches is in another
			// namespace.
			name:       "no-template",
			violations: 1,
			want: `
$C/treasury/components/webhook/validatingwebhookconfiguration-webhook.yaml: ValidatingWebhookConfiguration webhook: rule 3, pod network not hostNetwork: no pod template in namespace webhook matches Service webhook/webhook's selector app=webhook; render the workload that serves it in namespace webhook
cluster treasury: 1 configuration, 1 Service and 0 pod templates checked; 1 violation, 0 exceptions
`,
		},
		{
			// One of the two templates behind the Service is on hostNetwork.
			name:       "hostnetwork",
			violations: 1,
			want: `
$C/treasury/components/webhook/validatingwebhookconfiguration-webhook.yaml: ValidatingWebhookConfiguration webhook: rule 3, pod network not hostNetwork: DaemonSet webhook/webhook-node ($C/treasury/components/webhook/daemonset-webhook-node.yaml), behind Service webhook/webhook, sets hostNetwork: true; run the pods that serve it on the pod network
cluster treasury: 1 configuration, 1 Service and 2 pod templates checked; 1 violation, 0 exceptions
`,
		},
		{
			// treasury's exception, folded over lines as ADR 0003 shows it.
			name: "exception",
			want: `
$C/treasury/components/webhook/validatingwebhookconfiguration-webhook.yaml: ValidatingWebhookConfiguration webhook: exception: ` + reason + `
cluster treasury: 1 configuration, 0 Services and 0 pod templates checked; 0 violations, 1 exception
`,
		},
		{
			name:       "exception-stale",
			violations: 1,
			want: `
$C/treasury/components/webhook/validatingwebhookconfiguration-webhook.yaml: ValidatingWebhookConfiguration webhook: exception no longer needed: it satisfies rules 1 to 3; remove its holos.run/contract-exception annotation
cluster treasury: 1 configuration, 1 Service and 1 pod template checked; 1 violation, 0 exceptions
`,
		},
		{
			// A bare "needed" excepts nothing, so rule 1 fails too.
			name:       "exception-unnamed",
			violations: 2,
			want: `
$C/treasury/components/webhook/validatingwebhookconfiguration-webhook.yaml: ValidatingWebhookConfiguration webhook: exception names no ADR and no Planboard item: "needed"; name the ADR or Planboard item that keeps it and removes it
$C/treasury/components/webhook/validatingwebhookconfiguration-webhook.yaml: ValidatingWebhookConfiguration webhook webhook validate.webhook.example.com: rule 1, service not url: clientConfig.url is https://webhook.example.com:9443/validate; name the Service by clientConfig.service instead
cluster treasury: 1 configuration, 0 Services and 0 pod templates checked; 2 violations, 0 exceptions
`,
		},
		{
			// treasury's Service does not satisfy payments' webhook.
			name:       "two-clusters",
			violations: 1,
			want: `
$C/payments/components/webhook/validatingwebhookconfiguration-webhook.yaml: ValidatingWebhookConfiguration webhook: rule 2, selector and not headless: Service webhook/webhook is not in the tree of cluster payments; render the Service, with a selector on the pods that serve it, in namespace webhook
cluster payments: 1 configuration, 0 Services and 0 pod templates checked; 1 violation, 0 exceptions
cluster treasury: 1 configuration, 1 Service and 1 pod template checked; 0 violations, 0 exceptions
`,
		},
		{
			// A conversion webhook by url: and one by Service; a CRD
			// converting with strategy None is not checked.
			name:       "conversion",
			violations: 1,
			want: `
$C/treasury/components/widgets/customresourcedefinition-gadgets.example.com.yaml: CustomResourceDefinition gadgets.example.com: rule 1, service not url: spec.conversion.webhook.clientConfig.url is https://widgets.example.com/convert; name the Service by spec.conversion.webhook.clientConfig.service instead
cluster treasury: 2 configurations, 1 Service and 1 pod template checked; 1 violation, 0 exceptions
`,
		},
		{
			// An aggregated API whose Service is not rendered; a local
			// APIService, with no spec.service, is not checked.
			name:       "apiservice",
			violations: 1,
			want: `
$C/treasury/components/metrics/apiservice-v1beta1.metrics.k8s.io.yaml: APIService v1beta1.metrics.k8s.io: rule 2, selector and not headless: Service kube-system/metrics-server is not in the tree of cluster treasury; render the Service, with a selector on the pods that serve it, in namespace kube-system
cluster treasury: 1 configuration, 0 Services and 0 pod templates checked; 1 violation, 0 exceptions
`,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := filepath.Join("testdata", tc.name)
			var stdout, stderr bytes.Buffer
			err := run([]string{dir}, &stdout, &stderr)
			want := strings.TrimPrefix(strings.ReplaceAll(tc.want, "$C/", filepath.Join(dir, "clusters")+"/"), "\n")
			if got := stdout.String(); got != want {
				t.Errorf("output:\n%s\nwant:\n%s", got, want)
			}
			if stderr.Len() > 0 {
				t.Errorf("stderr: %s", stderr.String())
			}
			var v violationsError
			switch {
			case tc.violations == 0 && err != nil:
				t.Errorf("run: %v, want no error", err)
			case tc.violations > 0 && !errors.As(err, &v):
				t.Errorf("run: %v, want %d violations", err, tc.violations)
			case tc.violations > 0 && int(v) != tc.violations:
				t.Errorf("run: %v, want %d violations", err, tc.violations)
			}
		})
	}
}

func TestRunErrors(t *testing.T) {
	for _, tc := range []struct {
		args []string
		want string
	}{
		{nil, "no path"},
		{[]string{"testdata/compliant", "testdata/url"}, `unexpected argument "testdata/url"`},
		{[]string{"testdata/no-clusters"}, "testdata/no-clusters: no clusters directory"},
		{[]string{"testdata/absent"}, "testdata/absent: no clusters directory"},
		{[]string{"testdata/bad-yaml"}, "testdata/bad-yaml/clusters/treasury/components/broken/service.yaml: yaml: line 1: did not find expected ',' or ']'"},
	} {
		var stdout, stderr bytes.Buffer
		err := run(tc.args, &stdout, &stderr)
		if err == nil || err.Error() != tc.want {
			t.Errorf("run(%q) = %v, want %s", tc.args, err, tc.want)
		}
		var v violationsError
		if errors.As(err, &v) {
			t.Errorf("run(%q) reported violations, want an error", tc.args)
		}
	}
}

// TestPodTemplates reads one file holding every kind a pod template comes
// from, beside a ConfigMap, which is not one.
func TestPodTemplates(t *testing.T) {
	tr, err := load("treasury", filepath.Join("testdata", "pod-kinds", "clusters", "treasury"))
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, p := range tr.templates["pods"] {
		s := p.kind + " " + p.name + " app=" + p.labels["app"]
		if p.hostNetwork {
			s += " hostNetwork"
		}
		got = append(got, s)
	}
	want := []string{
		"Deployment deployment app=deployment",
		"DaemonSet daemonset app=daemonset hostNetwork",
		"StatefulSet statefulset app=statefulset",
		"Job job app=job",
		"CronJob cronjob app=cronjob hostNetwork",
		"Pod pod app=pod",
	}
	if !slices.Equal(got, want) {
		t.Errorf("templates:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	if len(tr.templates) != 1 {
		t.Errorf("templates in %d namespaces, want 1", len(tr.templates))
	}
}

func TestNamesReason(t *testing.T) {
	for _, tc := range []struct {
		reason string
		want   bool
	}{
		{reason, true},
		{"the chart has no setting for it; ADR 0003", true},
		{"see Talos_Kubernetes_Layer/rebuild-treasury-on-the-new-layer", true},
		{"until [[Agent_Substrate_Day_MVP/argo-cd-bootstrap]] lands", true},
		{"needed", false},
		{"", false},
		{"ADR 1", false},               // not an ADR number
		{"ADR-0001", false},            // not how the ADRs are named
		{"adr 0001", false},            // nor this
		{"see Gateway/webhook", false}, // one word is not a project's name
		{"see Talos_Kubernetes_Layer", false},
		{"see talos_kubernetes_layer/rebuild", false},
	} {
		if got := namesReason(tc.reason); got != tc.want {
			t.Errorf("namesReason(%q) = %v, want %v", tc.reason, got, tc.want)
		}
	}
}

// TestCommittedDeploy checks the rendered tree committed in holos/deploy,
// which CI's Render job also checks, so a change to the checker that would
// fail CI fails here first.
func TestCommittedDeploy(t *testing.T) {
	dir := filepath.Join("..", "..", "holos", "deploy")
	var stdout, stderr bytes.Buffer
	if err := run([]string{dir}, &stdout, &stderr); err != nil {
		t.Errorf("run(%s): %v\n%s", dir, err, stdout.String())
	}
	// A tree that read nothing would pass too, so the treasury summary must
	// name the webhook configurations the Gateway path still excepts.
	if !strings.Contains(stdout.String(), "cluster treasury: ") ||
		strings.Contains(stdout.String(), "cluster treasury: 0 configurations") {
		t.Errorf("run(%s) checked no treasury configurations:\n%s", dir, stdout.String())
	}
}
