// Command quay-bootstrap makes the few things in Quay that holos-controller
// cannot make for itself, and writes holos-controller's token as a platform
// secret, so bringing Quay up needs no browser. Ported from aavis-ops'
// hack/quay-bootstrap.
//
//	go run ./cmd/quay-bootstrap token [flags]
//
// token mints holos-controller's OAuth token. A Quay OAuth Application lives
// in an organization, platform-automation here, and its token acts as the user
// who generated it, svc-quay-controller, a Quay superuser. The program logs
// in to Quay as that user through Keycloak's ordinary login form, with the
// password from Secret keycloak/svc-quay-controller, makes the organization
// and the Application if they are missing, takes a token through the
// implicit grant, and writes Secret quay-controller-token (url, token,
// username) in holos-prj-platform, which the quay component copies to
// holos-controller/holos-controller-quay-creds. A stored token is probed
// first and replaced only when Quay refuses it, 401 or 403: a token stays
// live until someone revokes it, so minting on any other failure would leave
// another live superuser token behind. To replace it on purpose, delete the Secret.
//
// Platform secrets carry the label app.kubernetes.io/managed-by=holos.run and
// the platform owners' grant, so they show under Platform in the Secrets
// Manager. The command converges: a second run reports no change and writes
// nothing. The program talks to the cluster through kubectl, with its current
// context unless -context is given, and trusts the cluster's private root,
// from ConfigMap private-ca, or -ca-file, beside the system roots.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
)

const usage = `usage: quay-bootstrap <command> [flags]

commands:
  token  mint holos-controller's Quay token into platform secret quay-controller-token

Run quay-bootstrap <command> -h for the flags.
`

// scopes are the token's, kept as aavis-ops measured them: the Organization
// reconciler needs super:user, org:admin and repo:create, and the Repository
// reconciler updates and deletes repositories and their notifications.
var scopes = []string{"super:user", "org:admin", "repo:create", "repo:read", "repo:write", "repo:admin", "user:admin", "user:read"}

type options struct {
	context     string
	quayURL     string
	caFile      string
	caNamespace string
	namespace   string

	// token
	username          string
	passwordNamespace string
	automationOrg     string
	application       string
	tokenSecret       string
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err := run(ctx, os.Args[1:], os.Stderr)
	stop()
	if errors.Is(err, flag.ErrHelp) {
		return
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "quay-bootstrap:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, stderr io.Writer) error {
	if len(args) == 0 || strings.HasPrefix(args[0], "-") {
		fmt.Fprint(stderr, usage)
		return errors.New("no command")
	}
	cmd, args := args[0], args[1:]
	o := &options{}
	fs := flag.NewFlagSet("quay-bootstrap "+cmd, flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&o.context, "context", "", "kubectl context (default: the current one)")
	fs.StringVar(&o.quayURL, "quay-url", "https://quay.bank.internal", "Quay's URL")
	fs.StringVar(&o.caFile, "ca-file", "", "PEM file of the private root (default: ConfigMap private-ca from the cluster)")
	fs.StringVar(&o.caNamespace, "ca-namespace", "default", "namespace of ConfigMap private-ca")
	fs.StringVar(&o.namespace, "namespace", "holos-prj-platform", "namespace of the platform secrets")
	fs.StringVar(&o.tokenSecret, "token-secret", "quay-controller-token", "platform secret holding holos-controller's token")
	fs.StringVar(&o.automationOrg, "automation-org", "platform-automation", "organization holding the OAuth Application")
	switch cmd {
	case "token":
		fs.StringVar(&o.username, "username", "svc-quay-controller", "realm user to log in as; a Quay superuser")
		fs.StringVar(&o.passwordNamespace, "password-namespace", "keycloak", "namespace of the user's password Secret, named after the user")
		fs.StringVar(&o.application, "application", "holos-controller", "OAuth Application name")
	default:
		fmt.Fprint(stderr, usage)
		return fmt.Errorf("unknown command %q", cmd)
	}
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return fmt.Errorf("unexpected argument %q", fs.Arg(0))
	}
	o.quayURL = strings.TrimRight(o.quayURL, "/")

	k := &kubectl{context: o.context}
	name, err := k.currentContext(ctx)
	if err != nil {
		return err
	}
	logf("kubectl context %s", name)
	roots, err := privateRoot(ctx, k, o)
	if err != nil {
		return err
	}
	return runToken(ctx, k, o, roots)
}

// privateRoot returns the PEM the Quay client trusts beside the system's:
// -ca-file, or the root trust-manager keeps in every namespace.
func privateRoot(ctx context.Context, k kube, o *options) ([]byte, error) {
	if o.caFile != "" {
		return os.ReadFile(o.caFile)
	}
	pem, err := k.configMapValue(ctx, o.caNamespace, "private-ca", "ca.crt")
	return []byte(pem), err
}

// credential is the token platform secret's content.
type credential struct{ url, token, username string }

func readCredential(ctx context.Context, k kube, namespace, name string) (*credential, error) {
	s, err := k.getSecret(ctx, namespace, name)
	if err != nil || s == nil {
		return nil, err
	}
	c := &credential{url: string(s.data["url"]), token: string(s.data["token"]), username: string(s.data["username"])}
	if c.url == "" || c.token == "" {
		return nil, nil
	}
	return c, nil
}

func (o *options) credentialSecret(c *credential) *secret {
	return platformSecret(o.namespace, o.tokenSecret, "Opaque", map[string][]byte{
		"url":      []byte(c.url),
		"token":    []byte(c.token),
		"username": []byte(c.username),
	})
}

func runToken(ctx context.Context, k kube, o *options, roots []byte) error {
	if have, err := readCredential(ctx, k, o.namespace, o.tokenSecret); err != nil {
		return err
	} else if have != nil {
		// The stored token is checked against -quay-url, not the url it was
		// stored with, so the flag decides which Quay the controller is
		// pointed at: a token another Quay refuses is minted anew there.
		if have.url != o.quayURL {
			logf("the stored url is %s; checking its token against %s", have.url, o.quayURL)
		}
		q, err := newQuayClient(o.quayURL, roots)
		if err != nil {
			return err
		}
		user, err := q.verifyToken(ctx, have.token, o.automationOrg)
		switch {
		case errors.Is(err, errRejected):
			logf("the stored token is refused (%v); minting another", err)
		case err != nil:
			return fmt.Errorf("cannot check the stored token, and will not mint a second on a maybe: %w\n"+
				"resolve the fault and run again; to replace the token on purpose, delete Secret %s/%s first",
				err, o.namespace, o.tokenSecret)
		case user.Username != o.username:
			logf("the stored token acts as %s, not %s; minting another", user.Username, o.username)
		default:
			// Written from what was verified, so a Secret with another url
			// or no username is repaired.
			c := &credential{url: o.quayURL, token: have.token, username: user.Username}
			changed, err := applySecret(ctx, k, o.credentialSecret(c))
			if err == nil && !changed {
				logf("secret %s/%s holds a working token for %s: no change", o.namespace, o.tokenSecret, user.Username)
			}
			return err
		}
	}

	pw, err := k.getSecret(ctx, o.passwordNamespace, o.username)
	if err != nil {
		return err
	}
	if pw == nil || len(pw.data["password"]) == 0 {
		return fmt.Errorf("no password in Secret %s/%s", o.passwordNamespace, o.username)
	}
	q, err := newQuayClient(o.quayURL, roots)
	if err != nil {
		return err
	}
	if err := q.login(ctx, o.username, string(pw.data["password"])); err != nil {
		return err
	}
	if _, err := q.ensureOrganization(ctx, o.automationOrg, orgEmail(o.quayURL, o.username, o.automationOrg)); err != nil {
		return err
	}
	app, err := q.ensureApplication(ctx, o.automationOrg, o.application)
	if err != nil {
		return err
	}
	token, err := q.mintToken(ctx, app.ClientID, scopes)
	if err != nil {
		return err
	}
	// Probe it as the next run will, so a token minted with the wrong
	// scopes fails here rather than in the reconciler.
	user, err := q.verifyToken(ctx, token, o.automationOrg)
	if err != nil {
		return fmt.Errorf("the new token does not work: %w", err)
	}
	if user.Username != o.username {
		return fmt.Errorf("the new token acts as %s, want %s", user.Username, o.username)
	}
	logf("minted a token for %s acting as %s", o.application, user.Username)
	_, err = applySecret(ctx, k, o.credentialSecret(&credential{url: o.quayURL, token: token, username: user.Username}))
	return err
}

// orgEmail is the automation organization's email: Quay wants one unique to
// each namespace, so not the user's own.
func orgEmail(quayURL, username, org string) string {
	domain := "localhost"
	if u, err := url.Parse(quayURL); err == nil {
		if _, d, ok := strings.Cut(u.Hostname(), "."); ok {
			domain = d
		}
	}
	return fmt.Sprintf("%s+%s@%s", username, org, domain)
}

// logf prints one progress line. Every change prints one, so a first run and
// a second differ visibly.
func logf(format string, args ...any) {
	fmt.Printf(format+"\n", args...)
}
