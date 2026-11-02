// Command contract-check checks a rendered tree against the control plane to
// pod network Service contract of ADR 0003
// (docs/adr/0003-control-plane-service-contract.md). It is what CI's Render
// job runs over holos/deploy, and it runs the same way by hand from the
// repository root:
//
//	go run ./cmd/contract-check holos/deploy
//
// The path holds one clusters/<cluster> directory per cluster, and each
// cluster's tree is read and checked on its own, so a Service rendered for one
// cluster never satisfies a webhook rendered for another. Every YAML file in
// the tree is read, every document in it, whichever component rendered it: a
// webhook configuration often names a Service another component renders, as
// istio-base's istiod-default-validator names istiod's.
//
// The configurations checked are every ValidatingWebhookConfiguration and
// MutatingWebhookConfiguration, every CustomResourceDefinition whose
// spec.conversion.strategy is Webhook and every APIService with a
// spec.service. Each is held to the three rules ADR 0003 numbers:
//
//  1. Every webhook entry, conversion stanza and APIService names a Service
//     by service:, never a url:.
//  2. The Service it names is in the cluster's tree, in the namespace named,
//     with a non-empty spec.selector, and is not headless (clusterIP: None).
//  3. At least one pod template in that namespace matches the selector, and
//     none that does sets hostNetwork: true. Pod templates are those of
//     Deployments, DaemonSets, StatefulSets, Jobs and CronJobs, and bare Pods.
//
// A Service the tree does not hold, and a selector matching no pod template,
// fail: a backend made at runtime is not in Git to be checked. A Service or
// workload is in the namespace its metadata.namespace names; one with none is
// in no namespace, since what the cluster would put it in depends on how it
// is applied, and a finding it might have satisfied says so. The Service's
// port, the serving certificate and CA injection are the recommended form,
// not the contract, and are not checked. ValidatingAdmissionPolicy and
// MutatingAdmissionPolicy need no network and are not read.
//
// A configuration that cannot comply carries the holos.run/contract-exception
// annotation, whose value is the reason. It is reported, and its findings do
// not fail the run, unless the reason names neither an ADR, as "ADR 0001",
// nor a Planboard item, as "Talos_Kubernetes_Layer/rebuild-treasury-on-the-new-layer"
// (a project name of two or more capitalized words joined by underscores, a
// slash, and an item slug of lowercase words joined by hyphens), or the
// configuration already satisfies all three rules: the exception is no longer
// needed. Either is a violation.
//
// Output is plain text for a CI log, one line per finding:
//
//	<path>: <Kind> <name>[ webhook <webhook name>]: rule <n>, <short name>: <what was found>; <what to do>
//	<path>: <Kind> <name>: exception: <reason>
//
// with the path of the configuration's file, rule 1 once per webhook entry
// and rules 2 and 3 once per Service a configuration names, then a summary per
// cluster. The configurations, CRDs and APIServices are cluster scoped, so
// the name has no namespace. The exit status is 1 if any cluster has a
// violation, and 0 otherwise.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
)

const usage = `usage: contract-check <path>

Checks every clusters/<cluster> tree under <path>, such as holos/deploy,
against the Service contract of ADR 0003.
`

// violationsError is run's error when the tree was read and checked and a
// cluster has a violation; the findings are already printed.
type violationsError int

func (n violationsError) Error() string {
	if n == 1 {
		return "1 violation"
	}
	return fmt.Sprintf("%d violations", int(n))
}

func main() {
	err := run(os.Args[1:], os.Stdout, os.Stderr)
	if errors.Is(err, flag.ErrHelp) {
		return
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "contract-check:", err)
		os.Exit(1)
	}
}

func run(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("contract-check", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.Usage = func() { fmt.Fprint(stderr, usage) }
	if err := fs.Parse(args); err != nil {
		return err
	}
	switch fs.NArg() {
	case 0:
		fs.Usage()
		return errors.New("no path")
	case 1:
	default:
		return fmt.Errorf("unexpected argument %q", fs.Arg(1))
	}

	clusters, err := findClusters(fs.Arg(0))
	if err != nil {
		return err
	}
	violations := 0
	for _, c := range clusters {
		t, err := load(c.name, c.dir)
		if err != nil {
			return err
		}
		r := t.check()
		for _, line := range r.lines {
			fmt.Fprintln(stdout, line)
		}
		fmt.Fprintln(stdout, r.summary())
		violations += r.violations
	}
	if violations > 0 {
		return violationsError(violations)
	}
	return nil
}
