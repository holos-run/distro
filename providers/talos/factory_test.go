package talos

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSchematicAndImage(t *testing.T) {
	want := "customization:\n  systemExtensions:\n    officialExtensions:\n" +
		"      - siderolabs/gvisor\n      - siderolabs/kata-containers\n      - siderolabs/qemu-guest-agent\n"
	if Schematic() != want {
		t.Errorf("Schematic =\n%s", Schematic())
	}
	img := Image{FactoryURL: FactoryURL, SchematicID: "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba", TalosVersion: "v1.14.4"}
	if got := img.ISOURL(); got != "https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/v1.14.4/nocloud-amd64.iso" {
		t.Errorf("ISOURL = %s", got)
	}
	if got := img.Installer(); got != "factory.talos.dev/nocloud-installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.14.4" {
		t.Errorf("Installer = %s", got)
	}
	if got := img.Boot(); got.Name != "talos-v1.14.4-376567988ad3-nocloud-amd64.iso" || got.URL != img.ISOURL() {
		t.Errorf("Boot = %+v", got)
	}
}

func TestFactorySchematicID(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if r.Method != http.MethodPost || r.URL.Path != "/schematics" || string(body) != Schematic() {
			t.Errorf("got %s %s %q", r.Method, r.URL.Path, body)
		}
		if ct := r.Header.Get("Content-Type"); ct != "application/yaml" {
			t.Errorf("Content-Type = %q", ct)
		}
		w.WriteHeader(http.StatusCreated)
		io.WriteString(w, `{"id":"feedface","schematic":"x"}`)
	}))
	defer srv.Close()
	id, err := Factory{BaseURL: srv.URL, HTTP: srv.Client()}.SchematicID(context.Background())
	if err != nil || id != "feedface" {
		t.Fatalf("SchematicID = %q, %v", id, err)
	}
}
