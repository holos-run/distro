package main

import (
	"context"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// fakeQuay serves the part of Quay's API the token probe uses, for bearer
// tokens alone, and counts the calls that write.
type fakeQuay struct {
	mu     sync.Mutex
	writes int
	// tokens maps a bearer token to its user; narrow lacks super:user, and
	// down answers 502.
	tokens map[string]string
}

func newFakeQuay() *fakeQuay {
	return &fakeQuay{
		tokens: map[string]string{"good": "svc-quay-controller", "narrow": "svc-quay-controller"},
	}
}

func (f *fakeQuay) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	reply := func(code int, v any) {
		w.WriteHeader(code)
		_ = json.NewEncoder(w).Encode(v)
	}
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if token == "down" {
		reply(http.StatusBadGateway, map[string]string{"error": "upstream"})
		return
	}
	user, ok := f.tokens[token]
	if !ok {
		reply(http.StatusUnauthorized, map[string]string{"error": "invalid token"})
		return
	}
	if r.Method != http.MethodGet {
		f.writes++
	}
	p := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	switch {
	case r.URL.Path == "/api/v1/user/":
		reply(200, quayUser{Username: user, SuperUser: true})
	case r.URL.Path == "/api/v1/superuser/organizations/":
		if token == "narrow" {
			reply(403, map[string]string{"error": "insufficient scope"})
			return
		}
		reply(200, map[string]any{"organizations": []any{}})
	case len(p) == 5 && p[2] == "organization" && p[4] == "robots":
		reply(200, map[string]any{"robots": []any{}})
	default:
		reply(404, map[string]string{"error": "no route " + r.Method + " " + r.URL.Path})
	}
}

func startFakeQuay(t *testing.T) (*fakeQuay, *httptest.Server, []byte) {
	t.Helper()
	f := newFakeQuay()
	srv := httptest.NewTLSServer(f)
	t.Cleanup(srv.Close)
	roots := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: srv.Certificate().Raw})
	return f, srv, roots
}

func TestVerifyToken(t *testing.T) {
	_, srv, roots := startFakeQuay(t)
	q, err := newQuayClient(srv.URL, roots)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if u, err := q.verifyToken(ctx, "good", "platform-automation"); err != nil || u.Username != "svc-quay-controller" {
		t.Errorf("good: %v, %v", u, err)
	}
	for _, tok := range []string{"narrow", "revoked"} {
		if _, err := q.verifyToken(ctx, tok, "platform-automation"); !errors.Is(err, errRejected) {
			t.Errorf("%s: %v, want errRejected", tok, err)
		}
	}
	// A 502 says nothing about the token, so it must not lead to a mint.
	if _, err := q.verifyToken(ctx, "down", "platform-automation"); err == nil || errors.Is(err, errRejected) {
		t.Errorf("down: %v, want a hard error", err)
	}
}

func TestMintTokenRedirect(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/oauth/authorize" || r.URL.Query().Get("response_type") != "token" || r.URL.Query().Get("client_id") != "cid" {
			http.Error(w, "bad request", 400)
			return
		}
		http.Redirect(w, r, "/oauth/localapp#access_token=minted&token_type=Bearer", http.StatusFound)
	}))
	defer srv.Close()
	q, err := newQuayClient(srv.URL, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: srv.Certificate().Raw}))
	if err != nil {
		t.Fatal(err)
	}
	if tok, err := q.mintToken(context.Background(), "cid", scopes); err != nil || tok != "minted" {
		t.Errorf("got %q, %v", tok, err)
	}
}

func TestRunTokenRepairsStoredCredential(t *testing.T) {
	f, srv, roots := startFakeQuay(t)
	k := newFakeKube()
	o := &options{
		quayURL:       srv.URL,
		username:      "svc-quay-controller",
		namespace:     "holos-prj-platform",
		tokenSecret:   "quay-controller-token",
		automationOrg: "platform-automation",
	}
	// A working token stored with another url and no username.
	_ = k.createSecret(context.Background(), o.credentialSecret(&credential{url: "https://old.example", token: "good"}))
	k.writes = 0
	ctx := context.Background()

	if err := runToken(ctx, k, o, roots); err != nil {
		t.Fatal(err)
	}
	c := k.secrets["holos-prj-platform/quay-controller-token"]
	if string(c.data["url"]) != srv.URL || string(c.data["username"]) != "svc-quay-controller" || string(c.data["token"]) != "good" {
		t.Errorf("stored credential not repaired: %q", c.data)
	}
	if f.writes != 0 || k.writes != 1 {
		t.Errorf("first run: %d Quay writes, %d Secret writes; want 0 and 1", f.writes, k.writes)
	}
	if err := runToken(ctx, k, o, roots); err != nil {
		t.Fatal(err)
	}
	if k.writes != 1 {
		t.Errorf("second run wrote the Secret again")
	}
}
