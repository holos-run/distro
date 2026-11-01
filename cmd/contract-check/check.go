package main

import (
	"fmt"
	"regexp"
	"strings"
)

// The rules' short names, from the three promises ADR 0003 numbers: every
// webhook names a Service by service:, never a url:; the Service has a
// selector and is not headless; the pods behind it run on the pod network,
// never on hostNetwork.
const (
	rule1 = "rule 1, service not url"
	rule2 = "rule 2, selector and not headless"
	rule3 = "rule 3, pod network not hostNetwork"
)

// An exception's reason must name an ADR or a Planboard item. adrRef is an ADR
// by number, as "ADR 0001". itemRef is a Planboard item as
// Project_Name/item-slug: a project name of two or more capitalized words
// joined by underscores, as every Planboard project's is, and an item slug of
// lowercase words joined by hyphens, as every item's file name is.
var (
	adrRef  = regexp.MustCompile(`\bADR [0-9]{4}\b`)
	itemRef = regexp.MustCompile(`\b[A-Z][A-Za-z0-9]*(?:_[A-Z][A-Za-z0-9]*)+/[a-z0-9]+(?:-[a-z0-9]+)*\b`)
)

// namesReason reports whether an exception's reason names an ADR or a
// Planboard item.
func namesReason(reason string) bool {
	return adrRef.MatchString(reason) || itemRef.MatchString(reason)
}

// result is one cluster's check.
type result struct {
	cluster    string
	lines      []string
	subjects   int
	services   int
	templates  int
	violations int
	exceptions int
}

func (r *result) summary() string {
	return fmt.Sprintf("cluster %s: %s, %s and %s checked; %s, %s",
		r.cluster,
		count(r.subjects, "configuration"),
		count(r.services, "Service"),
		count(r.templates, "pod template"),
		count(r.violations, "violation"),
		count(r.exceptions, "exception"))
}

func count(n int, noun string) string {
	if n == 1 {
		return "1 " + noun
	}
	return fmt.Sprintf("%d %ss", n, noun)
}

// check applies the three rules to every subject in the tree, in the order
// the files were read.
func (t *tree) check() *result {
	r := &result{cluster: t.cluster, subjects: len(t.subjects)}
	services := map[*service]bool{}
	templates := map[*podTemplate]bool{}
	for _, s := range t.subjects {
		findings := t.checkSubject(s, services, templates)
		switch {
		case s.exception == nil:
			r.lines = append(r.lines, findings...)
			r.violations += len(findings)
		case len(findings) == 0:
			r.lines = append(r.lines, fmt.Sprintf("%s: %s: exception no longer needed: it satisfies rules 1 to 3; remove its %s annotation",
				s.path, s.title(), exceptionKey))
			r.violations++
		case !namesReason(*s.exception):
			// An exception that does not count excepts nothing.
			r.lines = append(r.lines, fmt.Sprintf("%s: %s: exception names no ADR and no Planboard item: %q; name the ADR or Planboard item that keeps it and removes it",
				s.path, s.title(), oneLine(*s.exception)))
			r.lines = append(r.lines, findings...)
			r.violations += 1 + len(findings)
		default:
			r.lines = append(r.lines, fmt.Sprintf("%s: %s: exception: %s", s.path, s.title(), oneLine(*s.exception)))
			r.exceptions++
		}
	}
	r.services = len(services)
	r.templates = len(templates)
	return r
}

// title is how a finding names its subject. Every subject is cluster
// scoped, so it has no namespace.
func (s *subject) title() string {
	return s.kind + " " + s.name
}

// checkSubject returns a subject's findings: rule 1 for each reference, and
// rules 2 and 3 once for each Service the subject names. It adds the Services
// and pod templates it checked to the sets given.
func (t *tree) checkSubject(s *subject, services map[*service]bool, templates map[*podTemplate]bool) []string {
	var findings []string
	seen := map[string]bool{}
	for _, r := range s.refs {
		at := s.path + ": " + s.title()
		if r.webhook != "" {
			at += " webhook " + r.webhook
		}
		switch {
		case r.url != "":
			findings = append(findings, fmt.Sprintf("%s: %s: %s.url is %s; name the Service by %s.service instead",
				at, rule1, r.field, r.url, r.field))
		case r.service == nil:
			findings = append(findings, fmt.Sprintf("%s: %s: %s names no Service; name the Service by %s.service",
				at, rule1, r.field, r.field))
		case r.service.Namespace == "" || r.service.Name == "":
			findings = append(findings, fmt.Sprintf("%s: %s: %s.service has no namespace or no name; name the Service by both",
				at, rule1, r.field))
		}
		if r.service == nil || r.service.Namespace == "" || r.service.Name == "" {
			continue
		}
		key := r.service.Namespace + "/" + r.service.Name
		if seen[key] {
			continue
		}
		seen[key] = true
		findings = append(findings, t.checkService(s.path+": "+s.title(), r.service, services, templates)...)
	}
	return findings
}

// checkService applies rules 2 and 3 to the Service a subject names.
func (t *tree) checkService(at string, ref *serviceRef, services map[*service]bool, templates map[*podTemplate]bool) []string {
	key := ref.Namespace + "/" + ref.Name
	svc, ok := t.services[key]
	if !ok {
		msg := fmt.Sprintf("%s: %s: Service %s is not in the tree of cluster %s", at, rule2, key, t.cluster)
		for _, u := range t.unnamespaced[ref.Name] {
			msg += fmt.Sprintf(" (%s has a Service %s with no metadata.namespace)", u.path, u.name)
		}
		return []string{msg + fmt.Sprintf("; render the Service, with a selector on the pods that serve it, in namespace %s", ref.Namespace)}
	}
	services[svc] = true

	var findings []string
	var problems, fixes []string
	if len(svc.selector) == 0 {
		problems = append(problems, "has no spec.selector")
		fixes = append(fixes, "give it a selector on the pods that serve it, not hand-made endpoints")
	}
	if svc.clusterIP == "None" {
		problems = append(problems, "is headless, clusterIP: None")
		fixes = append(fixes, "give it a cluster IP")
	}
	if len(problems) > 0 {
		findings = append(findings, fmt.Sprintf("%s: %s: Service %s (%s) %s; %s",
			at, rule2, key, svc.path, strings.Join(problems, " and "), strings.Join(fixes, " and ")))
	}
	if len(svc.selector) == 0 {
		return findings
	}

	var matched, host []*podTemplate
	for _, p := range t.templates[svc.namespace] {
		if matches(svc.selector, p.labels) {
			matched = append(matched, p)
			templates[p] = true
			if p.hostNetwork {
				host = append(host, p)
			}
		}
	}
	if len(matched) == 0 {
		msg := fmt.Sprintf("%s: %s: no pod template in namespace %s matches Service %s's selector %s",
			at, rule3, svc.namespace, key, formatSelector(svc.selector))
		for _, p := range t.templates[""] {
			if matches(svc.selector, p.labels) {
				msg += fmt.Sprintf(" (%s %s in %s matches it, with no metadata.namespace)", p.kind, p.name, p.path)
			}
		}
		findings = append(findings, msg+fmt.Sprintf("; render the workload that serves it in namespace %s", svc.namespace))
	}
	if len(host) > 0 {
		names := make([]string, len(host))
		for i, p := range host {
			names[i] = p.String()
		}
		verb := "sets"
		if len(host) > 1 {
			verb = "set"
		}
		findings = append(findings, fmt.Sprintf("%s: %s: %s, behind Service %s, %s hostNetwork: true; run the pods that serve it on the pod network",
			at, rule3, strings.Join(names, ", "), key, verb))
	}
	return findings
}

// oneLine folds a reason written over several lines into one.
func oneLine(s string) string {
	return strings.Join(strings.Fields(s), " ")
}
