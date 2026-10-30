// Package proxmox is the Proxmox VE implementation of the infrastructure
// layer's compute contract, infra.Compute, for the garage's hosts.
//
// It owns everything about Proxmox: the API client (internal/pve), the
// ownership tags, placement across the cluster's nodes, VMIDs, the node
// network's facts and reserved ranges, each VM's MAC, the cloud-init
// snippets written into the garage NFS export and attached with cicustom,
// the ISO download, and the token check against preflight/privileges.txt.
// It exposes no Kubernetes or Talos concept: a VM's role and pool are labels
// it records as tags without knowing what they mean, and each VM's network
// config is a file it writes and attaches without building it. The one thing
// it reads in its own snippets is the node address it gave the VM, since
// Proxmox keeps no other record of it.
//
// It is not under internal/ because the Kubernetes layer's program,
// providers/talos/cmd/talosvm, wires it in. preflight/ holds the one list of
// Proxmox privileges the provider needs, the script that grants exactly
// those on a Proxmox host, and the package that embeds the list so the
// provider can check its token against it. README.md in this directory
// covers that setup, the host step for nested virtualization, the VM
// settings, the node network and address plan, and the garage inventory.
package proxmox
