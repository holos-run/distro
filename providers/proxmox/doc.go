// Package proxmox is the Holos Distro provider for Proxmox VE.
//
// A provider holds what the distro needs to bring up Kubernetes on one kind
// of infrastructure. Proxmox is the first provider; each later provider gets a
// sibling directory under providers/.
//
// The provider's programs live under providers/proxmox/cmd/<name>, one
// directory per program, and run from a checkout of the repository root:
//
//	go run ./providers/proxmox/cmd/<name>
//
// The first program is talosvm, which creates, lists and destroys the Talos
// VMs of one cluster through the Proxmox API. Its library code is in
// internal/, so nothing outside the provider comes to depend on it while it
// changes. preflight/ holds the one list of Proxmox privileges the program
// needs, the script that grants exactly those on a Proxmox host, and the
// package that embeds the list so the program can check its token against
// it. README.md in this directory covers that setup, the host step for nested
// virtualization, the node network and address plan, usage, and the garage
// inventory.
package proxmox
