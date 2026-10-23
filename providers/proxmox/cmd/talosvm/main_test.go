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
		{"no endpoint", []string{"list", "-cluster", "spike"}, without("PROXMOX_URL"), "PROXMOX_URL"},
		{"http endpoint", []string{"list", "-cluster", "spike"}, map[string]string{"PROXMOX_URL": "http://r620a:8006", "PROXMOX_TOKEN_ID": "a@pve!b", "PROXMOX_TOKEN_SECRET": "x"}, "want https"},
		{"no secret", []string{"list", "-cluster", "spike"}, without("PROXMOX_TOKEN_SECRET"), "PROXMOX_TOKEN_SECRET"},
		{"ca and insecure", []string{"list", "-ca-file", "x.pem", "-insecure"}, full, "mutually exclusive"},
		{"missing config", []string{"create", "-config", "/nonexistent/talosvm.json"}, full, "no such file"},
		{"no cluster", []string{"create"}, full, "cluster is required"},
		{"ingress address", []string{"create", "-cluster", "spike", "-first-address", "10.20.0.45"}, full, "reserved (ingress)"},
		{"manual address", []string{"create", "-cluster", "spike", "-first-address", "10.20.0.22"}, full, "reserved (manual)"},
		{"secret in token ID", []string{"list", "-cluster", "spike"}, map[string]string{"PROXMOX_URL": "https://r620a:8006", "PROXMOX_TOKEN_ID": "0b1c2d3e-secret", "PROXMOX_TOKEN_SECRET": "holos@pve!distro"}, "want USER@REALM!TOKENID"},
		{"credentials in URL", []string{"list", "-cluster", "spike"}, map[string]string{"PROXMOX_URL": "https://u:0b1c2d3e-secret@r620a:8006", "PROXMOX_TOKEN_ID": "a@pve!b", "PROXMOX_TOKEN_SECRET": "x"}, "without credentials"},
		{"off subnet", []string{"create", "-cluster", "spike", "-first-address", "192.168.2.50"}, full, "outside the node subnet"},
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
