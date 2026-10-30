// Package talos is the Kubernetes layer of the Holos Distro: Talos Linux on
// VMs an infrastructure provider makes. It takes compute, through the
// infra.Compute contract and nothing else, and hands over a Kubernetes API
// with its nodes registered.
//
// It owns the Talos side of the VMs: the Image Factory schematic and the
// nocloud ISO it names, the nocloud network config each guest reads,
// rendered from the address, MAC, gateway, MTU and resolvers compute
// assigns, the cluster's shape (its control plane and pools, their sizes and
// addresses), the role and pool labels, and restart, which cordons a node,
// reboots Talos or has compute power-cycle the VM, and waits until the node
// and its workloads are back. It does not create VMs, disks or hypervisor
// credentials, and knows no hypervisor: the same code runs on any provider
// that implements the contract, and its tests run against a fake one.
//
// The program talosvm, under cmd/talosvm, is the one place that wires the
// Proxmox provider in. cluster.sh turns the VMs into a cluster with talosctl
// and the patches beside it, and clusters/<cluster>/ holds each cluster's
// rendered patches. README.md covers the program, the patches and the
// cluster's bring-up, and docs/ the control plane's memory.
package talos
