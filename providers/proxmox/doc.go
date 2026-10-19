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
package proxmox
