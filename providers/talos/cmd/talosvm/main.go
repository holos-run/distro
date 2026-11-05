// Command talosvm creates, lists, resizes, restarts and destroys the Talos
// VMs of one cluster on Proxmox VE.
//
//	go run ./providers/talos/cmd/talosvm create  -cluster <name> [-config file] [-workers n] [-first-address a] [-snippets-dir dir] [-dry-run]
//	go run ./providers/talos/cmd/talosvm list    -cluster <name> [-config file] [-json]
//	go run ./providers/talos/cmd/talosvm resize  -cluster <name> [-config file] [-workers n] [-nodes a,b] [-shrink] [-dry-run]
//	go run ./providers/talos/cmd/talosvm restart -cluster <name> [-config file] [-mode reboot|power-cycle] [-nodes a,b] [-timeout 15m] [-dry-run]
//	go run ./providers/talos/cmd/talosvm destroy -cluster <name> [-config file] [-yes]
//	go run ./providers/talos/cmd/talosvm check
//
// It is the one place that wires the two layers together: the Talos layer,
// providers/talos, decides what the VMs are, and the Proxmox provider,
// providers/proxmox, makes them through the infra.Compute contract. The
// subcommands, flags, environment and output are the program's from before
// the two were split.
//
// The VMs boot an Image Factory nocloud ISO carrying the qemu-guest-agent,
// gvisor and kata-containers extensions, take a static /32 address from a
// cloud-init network snippet, and wait in Talos maintenance mode; talosctl
// applies machine configuration afterwards. The snippets are files written
// into the garage NFS export, mounted at -snippets-dir on the machine that
// runs talosvm, because the Proxmox API cannot upload them. See
// providers/talos/README.md and providers/proxmox/README.md.
//
// Each cluster's config is committed at
// providers/talos/clusters/<cluster>/talosvm.json, and -cluster finds it from
// the repository root, wherever under the repository the program runs. -config
// names another file instead. create and resize refuse a cluster with no file,
// since building from the defaults would put a mistyped name at treasury's
// addresses. list, restart and destroy use the file when it is there and go on
// without it.
//
// resize sets the cores and memory of the cluster's existing VMs to the sizes
// the config gives them, with PUT /nodes/{node}/qemu/{vmid}/config. Proxmox
// holds the change to a running VM as pending until the VM is stopped and
// started, so resize ends by printing the restart -mode power-cycle command
// that applies it. It refuses to shrink a VM without -shrink, so a config that
// has fallen behind the VMs cannot take memory from a running cluster.
//
// restart restarts the cluster's workers one at a time, or the nodes -nodes
// names: it cordons each, reboots Talos (-mode reboot, the default) or shuts
// the VM down and starts it through Proxmox (-mode power-cycle, which a
// changed VM config such as new memory needs), waits until the node is back
// and Ready with its Cilium and ztunnel pods, uncordons it, deletes the
// Failed pods the restart left on it, and waits until every Deployment and
// StatefulSet that had a pod there is available again before the next node.
// It drives kubectl and talosctl, which act with the kubeconfig and
// talosconfig KUBECONFIG and TALOSCONFIG name.
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
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"go.holos.run/distro/providers/proxmox"
	"go.holos.run/distro/providers/talos"
)

const usage = `usage: talosvm <command> [flags]

commands:
  create   create and start the VMs the config asks for that do not exist yet
  list     list this cluster's VMs, their addresses and Proxmox nodes
  resize   set the cores and memory of this cluster's VMs to the config's sizes
  restart  restart the workers, or -nodes, one at a time, and wait for each to be back
  destroy  print, or with -yes send, the calls that delete this cluster's VMs
  check    check that the API token holds every privilege talosvm needs

Run talosvm <command> -h for the flags of one command.
`

// workersUsage describes -workers, which create and resize share, so that
// resize sees the same pool as the create that made the cluster.
const workersUsage = "worker count of the first pool; overrides the config"

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

// TalosConfig and ProxmoxConfig are the two halves of the config file: the
// cluster's shape, which the Talos layer reads, and the provider's settings.
// They are aliases so that config can embed both, which keeps the file's keys
// flat, as they were before the split.
type (
	TalosConfig   = talos.Config
	ProxmoxConfig = proxmox.Config
)

// config is the config file.
type config struct {
	TalosConfig
	ProxmoxConfig
}

// defaultConfig is the garage: the Talos layer's defaults, the provider's,
// and the node network and first address, which the Talos layer's config
// holds but which are the provider's facts.
func defaultConfig() config {
	cfg := config{TalosConfig: talos.Default(), ProxmoxConfig: proxmox.Default()}
	cfg.Network = proxmox.NodeNetwork
	cfg.FirstAddress = proxmox.FirstNodeAddress.String()
	return cfg
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

const (
	// repoModule is the module line of the repository's go.mod, which is how
	// the program knows the repository root. It does not need git, and a go
	// run binary's own path says nothing about where the source is.
	repoModule = "go.holos.run/distro"
	// clusterConfigDir and clusterConfigFile place a cluster's committed
	// config, relative to the repository root.
	clusterConfigDir  = "providers/talos/clusters"
	clusterConfigFile = "talosvm.json"
)

// repoRoot returns the nearest directory at or above dir whose go.mod declares
// repoModule. A go.mod of another module, or one that cannot be read, is passed
// over.
func repoRoot(dir string) (string, bool) {
	for {
		if data, err := os.ReadFile(filepath.Join(dir, "go.mod")); err == nil && declaresModule(data, repoModule) {
			return dir, true
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", false
		}
		dir = parent
	}
}

// declaresModule reports whether the go.mod in data has a module line naming
// module, bare or quoted.
func declaresModule(data []byte, module string) bool {
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) >= 2 && f[0] == "module" {
			return strings.Trim(f[1], `"`+"`") == module
		}
	}
	return false
}

// clusterConfigPath returns where the named cluster's committed config lives,
// from the repository root above the working directory.
func clusterConfigPath(cluster string) (string, error) {
	rel := filepath.Join(clusterConfigDir, cluster, clusterConfigFile)
	dir, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("cannot find the repository root for %s: %w; pass -config", rel, err)
	}
	root, ok := repoRoot(dir)
	if !ok {
		return "", fmt.Errorf("cannot find %s: no go.mod for %s at or above %s; run from the repository or pass -config", rel, repoModule, dir)
	}
	return filepath.Join(root, rel), nil
}

// decodeConfig reads the config file over cfg: explicit when it is given,
// otherwise the committed file of the named cluster. Explicit or not, a file
// that is there but cannot be read or decoded is an error.
//
// Without either name there is no file to read, and Validate reports the
// missing cluster where the command needs one. An invalid cluster name is left
// to Validate too, without becoming a path. A committed file that is absent, or
// a repository root that cannot be found, is an error only when required: a
// command that builds from the file must not fall back to the defaults, and
// one that only finds the cluster's VMs by name does not need it.
func decodeConfig(cfg *config, explicit, cluster string, required bool) error {
	if explicit != "" || cluster == "" {
		return talos.Decode(explicit, cfg)
	}
	if !talos.ValidClusterName(cluster) {
		return nil
	}
	path, err := clusterConfigPath(cluster)
	if err != nil {
		if required {
			return err
		}
		return nil
	}
	err = talos.Decode(path, cfg)
	if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if required {
		return fmt.Errorf("cluster %s has no config: %s does not exist; add that file or pass -config", cluster, path)
	}
	return nil
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
		configPath = fs.String("config", "", "JSON config file over the built-in garage defaults (default "+filepath.Join(clusterConfigDir, "<cluster>", clusterConfigFile)+" from the repository root)")
		cluster = fs.String("cluster", "", "cluster name; picks the default -config and overrides the config's cluster")
		snippetsDir = fs.String("snippets-dir", proxmox.DefaultSnippetsDir, "local mount of the snippet storage's snippets directory, where network snippets are written")
	}
	caFile := fs.String("ca-file", "", "PEM CA bundle to verify the Proxmox certificate (default ~/.config/holos/pve-root-ca.pem when it exists)")
	insecure := fs.Bool("insecure", false, "skip TLS verification of the Proxmox certificate; never the default")
	var dryRun, asJSON, yes, shrink *bool
	var firstAddress *string
	var workers *int
	var mode, nodes, requireDS, kubectlPath, talosctlPath *string
	var timeout, shutdownTimeout *time.Duration
	switch cmd {
	case "create":
		dryRun = fs.Bool("dry-run", false, "print the API calls create would send and send none")
		firstAddress = fs.String("first-address", "", "first node address; overrides the config's firstAddress")
		workers = fs.Int("workers", -1, workersUsage)
	case "list":
		asJSON = fs.Bool("json", false, "print JSON instead of a table")
	case "resize":
		dryRun = fs.Bool("dry-run", false, "print the API calls resize would send and send none")
		nodes = fs.String("nodes", "", "comma-separated VMs to resize (default every VM the config asks for)")
		shrink = fs.Bool("shrink", false, "allow fewer cores or less memory than a VM runs with")
		workers = fs.Int("workers", -1, workersUsage+"; pass the one create was given")
	case "restart":
		dryRun = fs.Bool("dry-run", false, "print each node's steps and change nothing")
		mode = fs.String("mode", talos.ModeReboot, "reboot (talosctl reboot, for changes inside the guest) or power-cycle (Proxmox shutdown and start, for a changed VM config)")
		nodes = fs.String("nodes", "", "comma-separated VMs to restart, in order (default every worker, by name); may name the control plane")
		timeout = fs.Duration("timeout", talos.DefaultRestartTimeout, "time one node may take, from cordon to its workloads being available")
		shutdownTimeout = fs.Duration("shutdown-timeout", talos.DefaultShutdownTimeout, "power-cycle: time the guest has to shut down before Proxmox stops it hard")
		requireDS = fs.String("require-daemonsets", strings.Join(talos.DefaultRequiredDaemonSets, ","), "comma-separated namespace/name DaemonSets a worker must have a Ready pod of, before and after")
		kubectlPath = fs.String("kubectl", "kubectl", "kubectl to run; it uses KUBECONFIG")
		talosctlPath = fs.String("talosctl", "talosctl", "talosctl to run; it uses TALOSCONFIG")
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

	cfg := defaultConfig()
	if configPath != nil {
		if err := decodeConfig(&cfg, *configPath, *cluster, cmd == "create" || cmd == "resize"); err != nil {
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
	if cmd == "create" || cmd == "resize" {
		// Validate before reading the token, so a config mistake shows
		// up even without credentials in the environment.
		if err := errors.Join(cfg.TalosConfig.Validate(proxmox.CheckNodeAddress), cfg.ProxmoxConfig.Validate()); err != nil {
			return err
		}
	}
	var zo talos.ResizeOptions
	if cmd == "resize" {
		zo = talos.ResizeOptions{Nodes: splitList(*nodes), Shrink: *shrink}
		if err := zo.Validate(); err != nil {
			return err
		}
	}
	var ro talos.RestartOptions
	if cmd == "restart" {
		ro = talos.RestartOptions{
			Mode:              *mode,
			Nodes:             splitList(*nodes),
			Timeout:           *timeout,
			ShutdownTimeout:   *shutdownTimeout,
			RequireDaemonSets: splitList(*requireDS),
		}
		if err := ro.Validate(); err != nil {
			return err
		}
		if cfg.Cluster == "" {
			return errors.New("cluster is required: name the cluster with -cluster or in the config")
		}
		// Find the programs before anything changes, rather than after
		// the first node is cordoned. A dry run never runs talosctl.
		tools := talos.ExecTools{}
		var err error
		if tools.KubectlPath, err = exec.LookPath(*kubectlPath); err != nil {
			return fmt.Errorf("-kubectl: %w", err)
		}
		if *mode == talos.ModeReboot && !*dryRun {
			if tools.TalosctlPath, err = exec.LookPath(*talosctlPath); err != nil {
				return fmt.Errorf("-talosctl: %w", err)
			}
		}
		ro.Tools = tools
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
	hc, err := proxmox.NewHTTPClient(ca, *insecure)
	if err != nil {
		return err
	}
	compute, err := proxmox.New(endpoint, getenv("PROXMOX_TOKEN_ID"), getenv("PROXMOX_TOKEN_SECRET"), hc)
	if err != nil {
		return fmt.Errorf("%w (set PROXMOX_TOKEN_ID and PROXMOX_TOKEN_SECRET)", err)
	}
	compute.Config, compute.Out, compute.Err = cfg.ProxmoxConfig, stdout, stderr
	if snippetsDir != nil {
		compute.SnippetsDir = *snippetsDir
	}
	r := &talos.Runner{
		Compute: compute,
		Factory: talos.Factory{BaseURL: talos.FactoryURL, HTTP: &http.Client{Timeout: time.Minute}},
		Config:  cfg.TalosConfig,
		Out:     stdout,
		Err:     stderr,
	}
	if dryRun != nil {
		r.DryRun, compute.DryRun = *dryRun, *dryRun
	}
	switch cmd {
	case "create":
		return r.Create(ctx)
	case "list":
		vms, err := compute.List(ctx, cfg.Cluster)
		if err != nil {
			return err
		}
		return list(vms, *asJSON, stdout, stderr)
	case "resize":
		return r.Resize(ctx, zo)
	case "restart":
		return r.Restart(ctx, ro)
	case "destroy":
		compute.DryRun = !*yes
		return compute.Destroy(ctx, cfg.Cluster)
	default:
		if err := compute.Check(ctx); err != nil {
			return err
		}
		fmt.Fprintln(stdout, "the token holds every privilege in providers/proxmox/preflight/privileges.txt")
		return nil
	}
}

// splitList splits a comma-separated flag, dropping empty entries, so an
// empty flag is an empty list.
func splitList(s string) []string {
	var out []string
	for _, f := range strings.Split(s, ",") {
		if f = strings.TrimSpace(f); f != "" {
			out = append(out, f)
		}
	}
	return out
}
