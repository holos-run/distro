package talos

import (
	"fmt"
	"strings"

	"go.holos.run/distro/providers/infra"
)

// NetworkConfig is a node's cloud-init network-config, version 2, rendered
// from the NIC compute assigned it: the address, the MAC to match, the MTU,
// the gateway and the resolvers. Talos's nocloud platform reads it from the
// cloud-init drive in maintenance mode and on every boot after the install,
// since the installed system is the nocloud platform too.
//
// Version 2, because version 1 cannot say that the gateway of a /32 is
// on-link; Talos's nocloud platform honors on-link on a version 2 route by
// adding a link-scope route to the gateway first. This is the shape the
// garage's maintenance-mode Talos VMs already boot with. Talos reads the
// nameservers; it parses but does not apply search.
func NetworkConfig(nic infra.NIC) string {
	join := func(vs []string) string { return strings.Join(vs, ", ") }
	var ns []string
	for _, a := range nic.Nameservers {
		ns = append(ns, a.String())
	}
	return fmt.Sprintf(`version: 2
ethernets:
  net0:
    match:
      macaddress: "%s"
    addresses:
      - %s
    mtu: %d
    routes:
      - to: 0.0.0.0/0
        via: %s
        on-link: true
    nameservers:
      addresses: [%s]
      search: [%s]
`, nic.MAC, nic.Address, nic.MTU, nic.Gateway, join(ns), join(nic.SearchDomains))
}
