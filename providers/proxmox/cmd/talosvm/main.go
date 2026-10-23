// Command talosvm creates, lists and destroys the Talos VMs of one cluster on
// Proxmox VE.
//
//	go run ./providers/proxmox/cmd/talosvm create  -cluster <name> [-config file] [-snippets-dir dir] [-dry-run]
//	go run ./providers/proxmox/cmd/talosvm list    -cluster <name> [-json]
//	go run ./providers/proxmox/cmd/talosvm destroy -cluster <name> [-yes]
//	go run ./providers/proxmox/cmd/talosvm check
//
// The VMs boot an Image Factory nocloud ISO carrying the qemu-guest-agent,
// gvisor and kata-containers extensions, take a static /32 address from a
// cloud-init network snippet, and wait in Talos maintenance mode; talosctl
// applies machine configuration afterwards. The snippets are files written
// into the garage NFS export, mounted at -snippets-dir on the machine that
// runs talosvm, because the Proxmox API cannot upload them. See
// providers/proxmox/README.md.
//
// The Proxmox endpoint and API token come from the environment, never from
// the config file or a flag, so the secret stays out of shell history and out
// of git:
//
//	PROXMOX_URL           https://r620a.lan:8006
//	PROXMOX_TOKEN_ID      holos@pve!distro
//	PROXMOX_TOKEN_SECRET  the token's secret
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"go.holos.run/distro/providers/proxmox/internal/pve"
	"go.holos.run/distro/providers/proxmox/internal/talosvm"
)

const usage = `usage: talosvm <command> [flags]

commands:
  create   create and start the VMs the config asks for that do not exist yet
  list     list this cluster's VMs, their addresses and Proxmox nodes
  destroy  print, or with -yes send, the calls that delete this cluster's VMs
  check    check that the API token holds every privilege talosvm needs

Run talosvm <command> -h for the flags of one command.
`

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err := run(ctx, os.Args[1:], os.Stdout, os.Stderr, os.Getenv)
	stop()
	if errors.Is(err, flag.ErrHelp) {
		return
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "talosvm:", err)
		os.Exit(1)
	}
}

// defaultCAFile is where the README puts a copy of the cluster's
// /etc/pve/pve-root-ca.pem. It is used when it exists and -ca-file is not
// given, so the usual run verifies TLS without a flag.
func defaultCAFile(getenv func(string) string) string {
	home := getenv("HOME")
	if home == "" {
		return ""
	}
	p := filepath.Join(home, ".config", "holos", "pve-root-ca.pem")
	if _, err := os.Stat(p); err != nil {
		return ""
	}
	return p
}

func run(ctx context.Context, args []string, stdout, stderr io.Writer, getenv func(string) string) error {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return errors.New("no command")
	}
	cmd, args := args[0], args[1:]
	fs := flag.NewFlagSet("talosvm "+cmd, flag.ContinueOnError)
	fs.SetOutput(stderr)
	var configPath, cluster, snippetsDir *string
	if cmd != "check" {
		configPath = fs.String("config", "", "JSON config file over the built-in garage defaults")
		cluster = fs.String("cluster", "", "cluster name; overrides the config's cluster")
		snippetsDir = fs.String("snippets-dir", talosvm.DefaultSnippetsDir, "local mount of the snippet storage's snippets directory, where network snippets are written")
	}
	caFile := fs.String("ca-file", "", "PEM CA bundle to verify the Proxmox certificate (default ~/.config/holos/pve-root-ca.pem when it exists)")
	insecure := fs.Bool("insecure", false, "skip TLS verification of the Proxmox certificate; never the default")
	var dryRun, asJSON, yes *bool
	var firstAddress *string
	var workers *int
	switch cmd {
	case "create":
		dryRun = fs.Bool("dry-run", false, "print the API calls create would send and send none")
		firstAddress = fs.String("first-address", "", "first node address; overrides the config's firstAddress")
		workers = fs.Int("workers", -1, "worker count of the first pool; overrides the config")
	case "list":
		asJSON = fs.Bool("json", false, "print JSON instead of a table")
	case "destroy":
		yes = fs.Bool("yes", false, "send the calls; without it destroy only prints them")
	case "check":
	case "-h", "-help", "--help", "help":
		fmt.Fprint(stdout, usage)
		return nil
	default:
		fmt.Fprint(stderr, usage)
		return fmt.Errorf("unknown command %q", cmd)
	}
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return fmt.Errorf("%s takes no arguments, got %q", cmd, fs.Args())
	}

	cfg := talosvm.Default()
	if configPath != nil {
		var err error
		if cfg, err = talosvm.Load(*configPath); err != nil {
			return err
		}
		if *cluster != "" {
			cfg.Cluster = *cluster
		}
	}
	if firstAddress != nil && *firstAddress != "" {
		cfg.FirstAddress = *firstAddress
	}
	if workers != nil && *workers >= 0 {
		if len(cfg.Pools) == 0 {
			return errors.New("-workers: the config has no pools")
		}
		cfg.Pools[0].Count = *workers
	}
	if cmd == "create" {
		// Validate before reading the token, so a config mistake shows
		// up even without credentials in the environment.
		if err := cfg.Validate(); err != nil {
			return err
		}
	}

	endpoint := getenv("PROXMOX_URL")
	if u, err := url.Parse(endpoint); endpoint == "" || err != nil || u.Scheme != "https" || u.Host == "" {
		// The value itself is not echoed: it could carry credentials.
		return errors.New("PROXMOX_URL: want https://host:8006 (set -a; . ~/.config/holos/proxmox.env; set +a)")
	}
	ca := *caFile
	if ca == "" && !*insecure {
		ca = defaultCAFile(getenv)
	}
	hc, err := pve.NewHTTPClient(ca, *insecure)
	if err != nil {
		return err
	}
	client, err := pve.New(endpoint, getenv("PROXMOX_TOKEN_ID"), getenv("PROXMOX_TOKEN_SECRET"), hc)
	if err != nil {
		return fmt.Errorf("%w (set PROXMOX_TOKEN_ID and PROXMOX_TOKEN_SECRET)", err)
	}
	r := &talosvm.Runner{
		PVE:     client,
		Factory: talosvm.Factory{BaseURL: talosvm.FactoryURL, HTTP: &http.Client{Timeout: time.Minute}},
		Config:  cfg,
		Out:     stdout,
	}
	if snippetsDir != nil {
		r.SnippetsDir = *snippetsDir
	}
	switch cmd {
	case "create":
		r.DryRun = *dryRun
		return r.Create(ctx)
	case "list":
		return r.List(ctx, *asJSON)
	case "destroy":
		r.DryRun = !*yes
		return r.Destroy(ctx)
	default:
		if err := r.Check(ctx); err != nil {
			return err
		}
		fmt.Fprintln(stdout, "the token holds every privilege in providers/proxmox/preflight/privileges.txt")
		return nil
	}
}
