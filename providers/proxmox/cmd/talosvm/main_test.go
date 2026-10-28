package main

import (
	"context"
	"io"
	"strings"
	"testing"
)

func env(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

// The checks below all fail before any request is sent, so they need no
// Proxmox to talk to.
func TestRunRejects(t *testing.T) {
	full := map[string]string{
		"PROXMOX_URL":          "https://r620a.lan:8006",
		"PROXMOX_TOKEN_ID":     "holos@pve!distro",
		"PROXMOX_TOKEN_SECRET": "x",
	}
	without := func(k string) map[string]string {
		m := map[string]string{}
		for kk, v := range full {
			if kk != k {
				m[kk] = v
			}
		}
		return m
	}
	for _, tc := range []struct {
		name string
		args []string
		env  map[string]string
		want string
	}{
		{"no command", nil, full, "no command"},
		{"unknown command", []string{"apply"}, full, "unknown command"},
		{"stray argument", []string{"list", "extra"}, full, "takes no arguments"},
		{"no endpoint", []string{"list", "-cluster", "treasury"}, without("PROXMOX_URL"), "PROXMOX_URL"},
		{"http endpoint", []string{"list", "-cluster", "treasury"}, map[string]string{"PROXMOX_URL": "http://r620a:8006", "PROXMOX_TOKEN_ID": "a@pve!b", "PROXMOX_TOKEN_SECRET": "x"}, "want https"},
		{"no secret", []string{"list", "-cluster", "treasury"}, without("PROXMOX_TOKEN_SECRET"), "PROXMOX_TOKEN_SECRET"},
		{"ca and insecure", []string{"list", "-ca-file", "x.pem", "-insecure"}, full, "mutually exclusive"},
		{"missing config", []string{"create", "-config", "/nonexistent/talosvm.json"}, full, "no such file"},
		{"no cluster", []string{"create"}, full, "cluster is required"},
		{"ingress address", []string{"create", "-cluster", "treasury", "-first-address", "10.20.0.45"}, full, "reserved (ingress)"},
		{"manual address", []string{"create", "-cluster", "treasury", "-first-address", "10.20.0.22"}, full, "reserved (manual)"},
		{"secret in token ID", []string{"list", "-cluster", "treasury"}, map[string]string{"PROXMOX_URL": "https://r620a:8006", "PROXMOX_TOKEN_ID": "0b1c2d3e-secret", "PROXMOX_TOKEN_SECRET": "holos@pve!distro"}, "want USER@REALM!TOKENID"},
		{"credentials in URL", []string{"list", "-cluster", "treasury"}, map[string]string{"PROXMOX_URL": "https://u:0b1c2d3e-secret@r620a:8006", "PROXMOX_TOKEN_ID": "a@pve!b", "PROXMOX_TOKEN_SECRET": "x"}, "without credentials"},
		{"restart mode", []string{"restart", "-cluster", "treasury", "-mode", "halt"}, full, `mode "halt"`},
		{"restart no cluster", []string{"restart", "-kubectl", "/bin/true"}, full, "cluster is required"},
		{"restart node twice", []string{"restart", "-cluster", "treasury", "-nodes", "treasury-general-1,treasury-general-1"}, full, "named twice"},
		{"restart daemonset", []string{"restart", "-cluster", "treasury", "-require-daemonsets", "cilium"}, full, "want namespace/name"},
		{"restart shutdown timeout", []string{"restart", "-cluster", "treasury", "-mode", "power-cycle", "-timeout", "1m", "-shutdown-timeout", "5m"}, full, "less than the timeout"},
		{"restart no kubectl", []string{"restart", "-cluster", "treasury", "-kubectl", "/nonexistent/kubectl"}, full, "-kubectl"},
		{"restart no talosctl", []string{"restart", "-cluster", "treasury", "-kubectl", "/bin/true", "-talosctl", "/nonexistent/talosctl"}, full, "-talosctl"},
		{"off subnet", []string{"create", "-cluster", "treasury", "-first-address", "192.168.2.50"}, full, "outside the node subnet"},
		{"resize no cluster", []string{"resize"}, full, "cluster is required"},
		{"resize missing config", []string{"resize", "-config", "/nonexistent/talosvm.json"}, full, "no such file"},
		{"resize takes no -yes", []string{"resize", "-cluster", "treasury", "-yes"}, full, "flag provided but not defined"},
		{"resize takes no -workers", []string{"resize", "-cluster", "treasury", "-workers", "2"}, full, "flag provided but not defined"},
		{"resize node twice", []string{"resize", "-cluster", "treasury", "-nodes", "treasury-cp-1,treasury-cp-1"}, full, "named twice"},
		{"resize bad node", []string{"resize", "-cluster", "treasury", "-nodes", "Treasury-cp-1"}, full, "not a VM name"},
		{"resize no endpoint", []string{"resize", "-cluster", "treasury", "-dry-run"}, without("PROXMOX_URL"), "PROXMOX_URL"},
	} {
		err := run(context.Background(), tc.args, io.Discard, io.Discard, env(tc.env))
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: err = %v, want it to mention %q", tc.name, err, tc.want)
		}
		if err != nil && strings.Contains(err.Error(), "0b1c2d3e") {
			t.Errorf("%s: error echoes a secret: %v", tc.name, err)
		}
	}
}
