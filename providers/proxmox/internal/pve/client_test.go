package pve

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func testClient(t *testing.T, h http.HandlerFunc) *Client {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	c, err := New(srv.URL, "holos@pve!distro", "s3cret", srv.Client())
	if err != nil {
		t.Fatal(err)
	}
	c.PollInterval = time.Millisecond
	return c
}

func TestDoSendsTokenAndForm(t *testing.T) {
	c := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		if got, want := r.Header.Get("Authorization"), "PVEAPIToken=holos@pve!distro=s3cret"; got != want {
			t.Errorf("Authorization = %q, want %q", got, want)
		}
		if r.URL.Path != "/api2/json/nodes/r620a/qemu" {
			t.Errorf("path = %q", r.URL.Path)
		}
		if ct := r.Header.Get("Content-Type"); ct != "application/x-www-form-urlencoded" {
			t.Errorf("Content-Type = %q", ct)
		}
		body, _ := io.ReadAll(r.Body)
		if string(body) != "name=a&vmid=100" {
			t.Errorf("body = %q", body)
		}
		io.WriteString(w, `{"data":"UPID:r620a:1:2:3:qmcreate:100:holos@pve!distro:"}`)
	})
	upid, err := c.Post(context.Background(), "/nodes/r620a/qemu", map[string][]string{"vmid": {"100"}, "name": {"a"}})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(upid, "UPID:r620a:") {
		t.Errorf("upid = %q", upid)
	}
}

func TestDeleteUsesQuery(t *testing.T) {
	c := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodDelete || r.URL.Query().Get("purge") != "1" {
			t.Errorf("got %s %s", r.Method, r.URL)
		}
		io.WriteString(w, `{"data":"UPID:r620a:1:2:3:qmdestroy:100:u:"}`)
	})
	if _, err := c.Delete(context.Background(), "/nodes/r620a/qemu/100", map[string][]string{"purge": {"1"}}); err != nil {
		t.Fatal(err)
	}
}

func TestAPIError(t *testing.T) {
	c := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		io.WriteString(w, `{"data":null,"errors":{"scsihw":"value 'x' does not have a value in the enumeration"}}`)
	})
	err := c.Do(context.Background(), http.MethodPost, "/nodes/r620a/qemu", nil, nil)
	var apiErr *APIError
	if !errors.As(err, &apiErr) {
		t.Fatalf("err = %v, want APIError", err)
	}
	if !strings.Contains(err.Error(), "scsihw: value 'x'") {
		t.Errorf("error %q does not name the parameter", err)
	}
}

func TestNextIDString(t *testing.T) {
	c := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"data":"104"}`)
	})
	id, err := c.NextID(context.Background())
	if err != nil || id != 104 {
		t.Fatalf("NextID = %d, %v; want 104", id, err)
	}
}

func TestWaitTask(t *testing.T) {
	for _, tc := range []struct {
		exit string
		ok   bool
	}{
		{"OK", true},
		{"WARNINGS: 1", true},
		{"unable to create VM 100 - storage full", false},
	} {
		polls := 0
		c := testClient(t, func(w http.ResponseWriter, r *http.Request) {
			if !strings.HasPrefix(r.URL.Path, "/api2/json/nodes/r620b/tasks/UPID:r620b:") {
				t.Errorf("path = %q", r.URL.Path)
			}
			polls++
			if polls < 3 {
				io.WriteString(w, `{"data":{"status":"running"}}`)
				return
			}
			io.WriteString(w, `{"data":{"status":"stopped","exitstatus":"`+tc.exit+`"}}`)
		})
		err := c.WaitTask(context.Background(), "UPID:r620b:0001:0002:0003:qmcreate:100:u:")
		if (err == nil) != tc.ok {
			t.Errorf("exit %q: err = %v, want ok=%v", tc.exit, err, tc.ok)
		}
		if polls != 3 {
			t.Errorf("exit %q: polled %d times, want 3", tc.exit, polls)
		}
	}
}

// A UPID carries the token ID, and the ! in it must reach Proxmox escaped
// exactly once: escaped twice, the server decodes %2521 to %21 and finds no
// such task.
func TestWaitTaskEscapesUPIDOnce(t *testing.T) {
	const upid = "UPID:r620a:0001:0002:0003:qmcreate:104:holos@pve!distro:"
	c := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		want := "/api2/json/nodes/r620a/tasks/" + upid + "/status"
		if r.URL.Path != want {
			t.Errorf("decoded path = %q, want %q", r.URL.Path, want)
		}
		if got := r.URL.EscapedPath(); strings.Contains(got, "%25") {
			t.Errorf("escaped path %q is escaped twice", got)
		}
		if strings.Contains(r.RequestURI, "%25") || !strings.Contains(r.RequestURI, "holos@pve%21distro") {
			t.Errorf("request URI = %q", r.RequestURI)
		}
		io.WriteString(w, `{"data":{"status":"stopped","exitstatus":"OK"}}`)
	})
	if err := c.WaitTask(context.Background(), upid); err != nil {
		t.Fatal(err)
	}
}

// Values from the environment never appear in errors: a secret pasted into
// the wrong variable must not reach the terminal.
func TestNewDoesNotEchoInputs(t *testing.T) {
	const secret = "0b1c2d3e-4f50-6172-8394-a5b6c7d8e9f0"
	for _, tc := range []struct{ endpoint, id string }{
		{"https://r620a:8006", secret},
		{"https://holos:" + secret + "@r620a:8006", "a@pve!b"},
		{"r620a:8006/" + secret, "a@pve!b"},
	} {
		_, err := New(tc.endpoint, tc.id, "x", nil)
		if err == nil {
			t.Errorf("New(%q, %q) accepted", tc.endpoint, tc.id)
			continue
		}
		if strings.Contains(err.Error(), secret) {
			t.Errorf("error echoes the secret: %v", err)
		}
	}
}

func TestUPIDNode(t *testing.T) {
	if n, err := UPIDNode("UPID:r620c:00001:2:3:download:x:u:"); err != nil || n != "r620c" {
		t.Errorf("UPIDNode = %q, %v", n, err)
	}
	if _, err := UPIDNode("nope"); err == nil {
		t.Error("UPIDNode accepted a malformed UPID")
	}
}

func TestNewChecks(t *testing.T) {
	if _, err := New("https://r620a:8006", "", "x", nil); err == nil {
		t.Error("New accepted an empty token ID")
	}
	if _, err := New("https://r620a:8006", "root@pam", "x", nil); err == nil {
		t.Error("New accepted a token ID without !TOKENID")
	}
	if _, err := New("r620a:8006", "a@pve!b", "x", nil); err == nil {
		t.Error("New accepted an endpoint without a scheme")
	}
	if _, err := NewHTTPClient("ca.pem", true); err == nil {
		t.Error("NewHTTPClient accepted a CA file together with insecure")
	}
	hc, err := NewHTTPClient("", false)
	if err != nil {
		t.Fatal(err)
	}
	if hc.Transport.(*http.Transport).TLSClientConfig.InsecureSkipVerify {
		t.Error("TLS verification is off by default")
	}
}

func TestTagList(t *testing.T) {
	got := Resource{Tags: "talosvm;talosvm-cluster-treasury,talosvm-role-worker talosvm-pool-general"}.TagList()
	if strings.Join(got, "|") != "talosvm|talosvm-cluster-treasury|talosvm-role-worker|talosvm-pool-general" {
		t.Errorf("TagList = %q", got)
	}
}

func TestPermissions(t *testing.T) {
	c := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api2/json/access/permissions" || r.URL.Query().Get("path") != "/" {
			t.Errorf("got %s", r.URL)
		}
		io.WriteString(w, `{"data":{"/":{"VM.Audit":1,"Sys.Audit":true,"Datastore.Audit":"1","SDN.Use":0,"VM.Allocate":false}}}`)
	})
	have, err := c.Permissions(context.Background(), "/")
	if err != nil {
		t.Fatal(err)
	}
	// SDN.Use and VM.Allocate do not propagate, so they do not reach the
	// paths below / that the program's calls are checked against.
	if !have["VM.Audit"] || !have["Sys.Audit"] || !have["Datastore.Audit"] || have["SDN.Use"] || have["VM.Allocate"] || len(have) != 3 {
		t.Errorf("Permissions = %v", have)
	}
}

func TestGuestConfig(t *testing.T) {
	c := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api2/json/nodes/r620b/qemu/102/config":
			io.WriteString(w, `{"data":{"ipconfig0":"ip=10.20.0.10/32,gw=10.20.0.1","cores":4}}`)
		case "/api2/json/nodes/r620b/lxc/150/config":
			io.WriteString(w, `{"data":{"net0":"name=eth0,ip=10.20.0.99/24"}}`)
		default:
			t.Errorf("got %s", r.URL)
		}
	})
	conf, err := c.GuestConfig(context.Background(), Resource{VMID: 102, Node: "r620b", Type: "qemu"})
	if err != nil || conf["ipconfig0"] != "ip=10.20.0.10/32,gw=10.20.0.1" || conf["cores"] != "4" {
		t.Errorf("GuestConfig(qemu) = %v, %v", conf, err)
	}
	conf, err = c.GuestConfig(context.Background(), Resource{VMID: 150, Node: "r620b", Type: "lxc"})
	if err != nil || conf["net0"] != "name=eth0,ip=10.20.0.99/24" {
		t.Errorf("GuestConfig(lxc) = %v, %v", conf, err)
	}
	if _, err := c.GuestConfig(context.Background(), Resource{VMID: 1, Type: "storage"}); err == nil {
		t.Error("GuestConfig accepted a non-guest")
	}
}

func TestClusterNameAndStorages(t *testing.T) {
	c := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/api2/json/cluster/status":
			io.WriteString(w, `{"data":[{"type":"node","name":"r620a"},{"type":"cluster","name":"garage"}]}`)
		case r.URL.Path == "/api2/json/cluster/resources" && r.URL.Query().Get("type") == "storage":
			io.WriteString(w, `{"data":[{"node":"r620a","storage":"garage","shared":1,"content":"iso,snippets,images,import","status":"available"}]}`)
		default:
			t.Errorf("got %s", r.URL)
		}
	})
	if name, err := c.ClusterName(context.Background()); err != nil || name != "garage" {
		t.Errorf("ClusterName = %q, %v", name, err)
	}
	ss, err := c.Storages(context.Background())
	if err != nil || len(ss) != 1 || ss[0].Shared != 1 || !ss[0].HasContent("iso") || ss[0].HasContent("rootdir") {
		t.Errorf("Storages = %+v, %v", ss, err)
	}
}
