package talos

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	"go.holos.run/distro/providers/infra"
)

// FactoryURL is the public Talos Image Factory.
const FactoryURL = "https://factory.talos.dev"

// Extensions are the system extensions baked into every node's image.
//
// They are fixed here rather than configured because the point is that they
// are present from day one: qemu-guest-agent lets the hypervisor see the
// VM's addresses and shut it down cleanly, and gvisor and kata-containers are there
// so the later sandbox items never have to rebuild the nodes. Substrate brings
// its own runsc inside its worker pods and does not depend on the gvisor
// extension. Kept sorted, so the schematic, and therefore its ID, is stable.
var Extensions = []string{
	"siderolabs/gvisor",
	"siderolabs/kata-containers",
	"siderolabs/qemu-guest-agent",
}

// Schematic returns the Image Factory schematic for Extensions. The factory
// derives the schematic ID from the content, so the same text always yields
// the same ID and posting it again is harmless.
func Schematic() string {
	var b strings.Builder
	b.WriteString("customization:\n  systemExtensions:\n    officialExtensions:\n")
	for _, e := range Extensions {
		b.WriteString("      - " + e + "\n")
	}
	return b.String()
}

// Factory is an Image Factory client.
type Factory struct {
	BaseURL string
	HTTP    *http.Client
}

// SchematicID posts the schematic and returns its ID. Posting is how the
// factory computes the ID, and it is idempotent, so dry runs do it too to
// print the real ISO name; it changes nothing on the compute provider.
func (f Factory) SchematicID(ctx context.Context) (string, error) {
	hc := f.HTTP
	if hc == nil {
		hc = http.DefaultClient
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, f.BaseURL+"/schematics", bytes.NewBufferString(Schematic()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/yaml")
	resp, err := hc.Do(req)
	if err != nil {
		return "", fmt.Errorf("image factory: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", fmt.Errorf("image factory: %w", err)
	}
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		return "", fmt.Errorf("image factory: %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
	var out struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(body, &out); err != nil || out.ID == "" {
		return "", fmt.Errorf("image factory: no schematic ID in %q", body)
	}
	return out.ID, nil
}

// Platform is the Talos platform of the image. nocloud, not the metal of the
// Talos Proxmox guide, because the node network has no DHCP: the nocloud
// platform reads the static address, gateway, resolver and hostname from the
// cloud-init drive compute attaches, so a VM is reachable in maintenance mode
// without anyone typing kernel arguments at its console.
const Platform = "nocloud"

// Image names the boot ISO for one schematic and Talos version.
type Image struct {
	FactoryURL   string
	SchematicID  string
	TalosVersion string
}

// ISOURL is where compute downloads the ISO from.
func (i Image) ISOURL() string {
	return fmt.Sprintf("%s/image/%s/%s/%s-amd64.iso", i.FactoryURL, i.SchematicID, i.TalosVersion, Platform)
}

// Filename is the ISO's name in compute's storage. It carries the version and
// a prefix of the schematic ID, so an upgrade or a changed extension list is a
// new file next to the old one rather than a silent overwrite, and an existing
// file with this name can be trusted to be the right image.
func (i Image) Filename() string {
	id := i.SchematicID
	if len(id) > 12 {
		id = id[:12]
	}
	return fmt.Sprintf("talos-%s-%s-%s-amd64.iso", i.TalosVersion, id, Platform)
}

// Boot is the ISO as the image a VM spec boots.
func (i Image) Boot() infra.Image {
	return infra.Image{Name: i.Filename(), URL: i.ISOURL()}
}

// Installer is the installer image talosctl's machine config must name, so
// the installed system keeps the same extensions and platform as the ISO.
// Image Factory serves one per platform as <platform>-installer.
func (i Image) Installer() string {
	host := strings.TrimPrefix(strings.TrimPrefix(i.FactoryURL, "https://"), "http://")
	return fmt.Sprintf("%s/%s-installer/%s:%s", host, Platform, i.SchematicID, i.TalosVersion)
}
