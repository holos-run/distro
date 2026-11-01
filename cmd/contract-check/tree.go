package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

// exceptionKey is the annotation a configuration that cannot comply carries,
// with the reason as its value (ADR 0003, Enforcement).
const exceptionKey = "holos.run/contract-exception"

// cluster is one clusters/<cluster> directory.
type cluster struct {
	name string
	dir  string
}

// findClusters returns the clusters/<cluster> directories under root, in name
// order.
func findClusters(root string) ([]cluster, error) {
	dir := filepath.Join(root, "clusters")
	entries, err := os.ReadDir(dir)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, fmt.Errorf("%s: no clusters directory", root)
		}
		return nil, err
	}
	var clusters []cluster
	for _, e := range entries {
		if e.IsDir() {
			clusters = append(clusters, cluster{name: e.Name(), dir: filepath.Join(dir, e.Name())})
		}
	}
	if len(clusters) == 0 {
		return nil, fmt.Errorf("%s: no cluster directories", dir)
	}
	return clusters, nil
}

// tree is what one cluster's rendered tree holds that the contract is about.
type tree struct {
	cluster  string
	subjects []*subject
	// services is keyed by namespace/name. unnamespaced holds the Services
	// with no metadata.namespace, by name, only to say so in a finding.
	services     map[string]*service
	unnamespaced map[string][]*service
	// templates is keyed by namespace, "" for those with none.
	templates map[string][]*podTemplate
}

// subject is a configuration the rules apply to: a webhook configuration, a
// CRD with a conversion webhook, or an APIService with a Service.
type subject struct {
	path string
	kind string
	name string
	// exception is the holos.run/contract-exception annotation, if set.
	exception *string
	refs      []ref
}

// ref is one place in a subject that names how the API server reaches it:
// a webhook entry, a conversion stanza or an APIService's spec.
type ref struct {
	// webhook is the webhook entry's name, and empty for a CRD or APIService.
	webhook string
	// field is where the reference is, such as clientConfig, for a finding.
	field   string
	url     string
	service *serviceRef
}

type service struct {
	path      string
	namespace string
	name      string
	selector  map[string]string
	clusterIP string
}

type podTemplate struct {
	path        string
	kind        string
	namespace   string
	name        string
	labels      map[string]string
	hostNetwork bool
}

func (p *podTemplate) String() string {
	return fmt.Sprintf("%s %s/%s (%s)", p.kind, p.namespace, p.name, p.path)
}

// The parts of each kind the checker reads. Every other field is ignored.

type metadata struct {
	Name        string            `yaml:"name"`
	Namespace   string            `yaml:"namespace"`
	Labels      map[string]string `yaml:"labels"`
	Annotations map[string]string `yaml:"annotations"`
}

type header struct {
	APIVersion string   `yaml:"apiVersion"`
	Kind       string   `yaml:"kind"`
	Metadata   metadata `yaml:"metadata"`
}

type serviceRef struct {
	Namespace string `yaml:"namespace"`
	Name      string `yaml:"name"`
}

type clientConfig struct {
	URL     string      `yaml:"url"`
	Service *serviceRef `yaml:"service"`
}

type webhookConfiguration struct {
	Webhooks []struct {
		Name         string       `yaml:"name"`
		ClientConfig clientConfig `yaml:"clientConfig"`
	} `yaml:"webhooks"`
}

type crd struct {
	Spec struct {
		Conversion *struct {
			Strategy string `yaml:"strategy"`
			Webhook  *struct {
				ClientConfig clientConfig `yaml:"clientConfig"`
			} `yaml:"webhook"`
		} `yaml:"conversion"`
	} `yaml:"spec"`
}

type apiService struct {
	Spec struct {
		Service *serviceRef `yaml:"service"`
	} `yaml:"spec"`
}

type serviceDoc struct {
	Spec struct {
		Selector  map[string]string `yaml:"selector"`
		ClusterIP string            `yaml:"clusterIP"`
	} `yaml:"spec"`
}

type podSpec struct {
	HostNetwork bool `yaml:"hostNetwork"`
}

type templateSpec struct {
	Metadata metadata `yaml:"metadata"`
	Spec     podSpec  `yaml:"spec"`
}

// workload is a Deployment, DaemonSet, StatefulSet or Job; a CronJob's
// spec.jobTemplate is one too.
type workload struct {
	Spec struct {
		Template templateSpec `yaml:"template"`
	} `yaml:"spec"`
}

type cronJob struct {
	Spec struct {
		JobTemplate workload `yaml:"jobTemplate"`
	} `yaml:"spec"`
}

type pod struct {
	Spec podSpec `yaml:"spec"`
}

// load reads every .yaml and .yml file under dir, in lexical order.
func load(name, dir string) (*tree, error) {
	t := &tree{
		cluster:      name,
		services:     map[string]*service{},
		unnamespaced: map[string][]*service{},
		templates:    map[string][]*podTemplate{},
	}
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		switch filepath.Ext(path) {
		case ".yaml", ".yml":
		default:
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if err := t.add(path, data); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return t, nil
}

// add reads each document of one file.
func (t *tree) add(path string, data []byte) error {
	dec := yaml.NewDecoder(bytes.NewReader(data))
	for i := 1; ; i++ {
		var doc yaml.Node
		if err := dec.Decode(&doc); err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
		if err := t.addDocument(path, &doc); err != nil {
			return fmt.Errorf("document %d: %w", i, err)
		}
	}
}

func (t *tree) addDocument(path string, doc *yaml.Node) error {
	// An empty document, between two separators or after the last one.
	if len(doc.Content) == 0 || doc.Content[0].Kind == yaml.ScalarNode && doc.Content[0].Tag == "!!null" {
		return nil
	}
	var h header
	if err := doc.Decode(&h); err != nil {
		return err
	}
	group, _, ok := strings.Cut(h.APIVersion, "/")
	if !ok {
		group = "" // the core group, apiVersion v1
	}
	m := h.Metadata
	switch group + " " + h.Kind {
	case "admissionregistration.k8s.io ValidatingWebhookConfiguration",
		"admissionregistration.k8s.io MutatingWebhookConfiguration":
		var w webhookConfiguration
		if err := doc.Decode(&w); err != nil {
			return err
		}
		s := t.newSubject(path, h)
		for _, wh := range w.Webhooks {
			s.refs = append(s.refs, ref{
				webhook: wh.Name,
				field:   "clientConfig",
				url:     wh.ClientConfig.URL,
				service: wh.ClientConfig.Service,
			})
		}
	case "apiextensions.k8s.io CustomResourceDefinition":
		var c crd
		if err := doc.Decode(&c); err != nil {
			return err
		}
		conv := c.Spec.Conversion
		if conv != nil && conv.Strategy == "Webhook" {
			r := ref{field: "spec.conversion.webhook.clientConfig"}
			if conv.Webhook != nil {
				r.url = conv.Webhook.ClientConfig.URL
				r.service = conv.Webhook.ClientConfig.Service
			}
			t.newSubject(path, h).refs = []ref{r}
		} else if _, ok := m.Annotations[exceptionKey]; ok {
			// Nothing to check, so an exception on it is not needed.
			t.newSubject(path, h)
		}
	case "apiregistration.k8s.io APIService":
		var a apiService
		if err := doc.Decode(&a); err != nil {
			return err
		}
		if a.Spec.Service != nil {
			t.newSubject(path, h).refs = []ref{{field: "spec.service", service: a.Spec.Service}}
		} else if _, ok := m.Annotations[exceptionKey]; ok {
			t.newSubject(path, h)
		}
	case " Service":
		var sd serviceDoc
		if err := doc.Decode(&sd); err != nil {
			return err
		}
		s := &service{
			path:      path,
			namespace: m.Namespace,
			name:      m.Name,
			selector:  sd.Spec.Selector,
			clusterIP: sd.Spec.ClusterIP,
		}
		if s.namespace == "" {
			t.unnamespaced[s.name] = append(t.unnamespaced[s.name], s)
		} else if _, dup := t.services[s.namespace+"/"+s.name]; !dup {
			t.services[s.namespace+"/"+s.name] = s
		}
	case "apps Deployment", "apps DaemonSet", "apps StatefulSet", "batch Job":
		var w workload
		if err := doc.Decode(&w); err != nil {
			return err
		}
		t.addTemplate(path, h, w.Spec.Template)
	case "batch CronJob":
		var c cronJob
		if err := doc.Decode(&c); err != nil {
			return err
		}
		t.addTemplate(path, h, c.Spec.JobTemplate.Spec.Template)
	case " Pod":
		var p pod
		if err := doc.Decode(&p); err != nil {
			return err
		}
		t.addTemplate(path, h, templateSpec{Metadata: m, Spec: p.Spec})
	}
	return nil
}

func (t *tree) newSubject(path string, h header) *subject {
	s := &subject{path: path, kind: h.Kind, name: h.Metadata.Name}
	if reason, ok := h.Metadata.Annotations[exceptionKey]; ok {
		s.exception = &reason
	}
	t.subjects = append(t.subjects, s)
	return s
}

func (t *tree) addTemplate(path string, h header, tmpl templateSpec) {
	p := &podTemplate{
		path:        path,
		kind:        h.Kind,
		namespace:   h.Metadata.Namespace,
		name:        h.Metadata.Name,
		labels:      tmpl.Metadata.Labels,
		hostNetwork: tmpl.Spec.HostNetwork,
	}
	t.templates[p.namespace] = append(t.templates[p.namespace], p)
}

// matches reports whether labels carry every key and value of a non-empty
// selector.
func matches(selector, labels map[string]string) bool {
	if len(selector) == 0 {
		return false
	}
	for k, v := range selector {
		if got, ok := labels[k]; !ok || got != v {
			return false
		}
	}
	return true
}

// formatSelector is a selector as k=v pairs in key order.
func formatSelector(selector map[string]string) string {
	keys := make([]string, 0, len(selector))
	for k := range selector {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	pairs := make([]string, len(keys))
	for i, k := range keys {
		pairs[i] = k + "=" + selector[k]
	}
	return strings.Join(pairs, ",")
}
