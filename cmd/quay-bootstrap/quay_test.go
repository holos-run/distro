package main

import (
	"context"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// fakeQuay serves the part of Quay's API the robots command and the token
// probe use, for bearer tokens alone, and counts the calls that write.
type fakeQuay struct {
	mu     sync.Mutex
	writes int
	// tokens maps a bearer token to its user; narrow lacks super:user, and
	// down answers 502.
	tokens     map[string]string
	robots     map[string]string            // org+short -> token
	teams      map[string]map[string]string // org -> team -> role
	members    map[string][]string          // org/team -> members
	prototypes map[string][]proto           // org -> default permissions
	repos      map[string][]string          // org -> repositories
	perms      map[string]string            // org/repo/user -> role
}

type proto struct {
	ID       string `json:"id"`
	Role     string `json:"role"`
	Delegate struct {
		Name string `json:"name"`
	} `json:"delegate"`
	ActivatingUser *struct{} `json:"activating_user"`
}

func newFakeQuay() *fakeQuay {
	return &fakeQuay{
		tokens:     map[string]string{"good": "svc-quay-controller", "narrow": "svc-quay-controller"},
		robots:     map[string]string{},
		teams:      map[string]map[string]string{"substrate": {"owners": "admin"}, "kagent": {"owners": "admin"}},
		members:    map[string][]string{},
		prototypes: map[string][]proto{},
		repos:      map[string][]string{"substrate": {"substrate"}},
		perms:      map[string]string{"substrate/substrate/substrate+push": "admin"},
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
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
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
	case r.URL.Path == "/api/v1/repository":
		org := r.URL.Query().Get("namespace")
		var list []map[string]string
		for _, n := range f.repos[org] {
			list = append(list, map[string]string{"name": n})
		}
		reply(200, map[string]any{"repositories": list})
	case len(p) == 5 && p[2] == "organization" && p[4] == "robots":
		reply(200, map[string]any{"robots": []any{}})
	case len(p) == 6 && p[2] == "organization" && p[4] == "robots":
		name := p[3] + "+" + p[5]
		if r.Method == http.MethodPut {
			f.robots[name] = "tok-" + name
		}
		if tok, ok := f.robots[name]; ok {
			reply(200, quayRobot{Name: name, Token: tok})
			return
		}
		reply(400, map[string]string{"message": "Could not find robot with specified username"})
	case len(p) == 4 && p[2] == "organization":
		teams := map[string]map[string]string{}
		for t, role := range f.teams[p[3]] {
			teams[t] = map[string]string{"role": role}
		}
		reply(200, map[string]any{"name": p[3], "teams": teams})
	case len(p) == 6 && p[4] == "team":
		f.teams[p[3]][p[5]] = body["role"].(string)
		reply(200, map[string]any{})
	case len(p) == 7 && p[4] == "team" && p[6] == "members":
		var list []map[string]string
		for _, m := range f.members[p[3]+"/"+p[5]] {
			list = append(list, map[string]string{"name": m})
		}
		reply(200, map[string]any{"members": list})
	case len(p) == 8 && p[4] == "team" && p[6] == "members":
		f.members[p[3]+"/"+p[5]] = append(f.members[p[3]+"/"+p[5]], p[7])
		reply(200, map[string]any{})
	case len(p) == 5 && p[4] == "prototypes" && r.Method == http.MethodPost:
		var x proto
		x.ID = fmt.Sprint(len(f.prototypes[p[3]]))
		x.Role = body["role"].(string)
		x.Delegate.Name = body["delegate"].(map[string]any)["name"].(string)
		f.prototypes[p[3]] = append(f.prototypes[p[3]], x)
		reply(200, x)
	case len(p) == 5 && p[4] == "prototypes":
		reply(200, map[string]any{"prototypes": f.prototypes[p[3]]})
	case len(p) == 8 && p[2] == "repository" && p[5] == "permissions":
		key := p[3] + "/" + p[4] + "/" + p[7]
		if r.Method == http.MethodPut {
			f.perms[key] = body["role"].(string)
		}
		if role, ok := f.perms[key]; ok {
			reply(200, map[string]string{"role": role})
			return
		}
		reply(400, map[string]string{"message": "User does not have permission for repo."})
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

func TestRunRobotsConverges(t *testing.T) {
	f, srv, roots := startFakeQuay(t)
	k := newFakeKube()
	o := &options{
		namespace:     "holos-prj-platform",
		tokenSecret:   "quay-controller-token",
		automationOrg: "platform-automation",
		orgs:          "substrate, kagent",
		pushSecret:    "quay-robot-push",
		pullSecret:    "quay-robot-pull",
	}
	_ = k.createSecret(context.Background(), o.credentialSecret(&credential{url: srv.URL, token: "good", username: "svc-quay-controller"}))
	k.writes = 0
	ctx := context.Background()

	if err := runRobots(ctx, k, o, roots); err != nil {
		t.Fatal(err)
	}
	if f.writes == 0 || k.writes != 3 {
		t.Fatalf("first run: %d Quay writes, %d Secret writes; want some and 3", f.writes, k.writes)
	}
	// The push robot made substrate/substrate by pushing, so it is its admin;
	// a grant must not lower that.
	if got := f.perms["substrate/substrate/substrate+push"]; got != "admin" {
		t.Errorf("push robot's role on its own repository: %s", got)
	}
	if got := f.perms["substrate/substrate/substrate+pull"]; got != "read" {
		t.Errorf("pull robot's role: %s", got)
	}
	if got := f.teams["kagent"]["pushers"]; got != "creator" {
		t.Errorf("pushers team role: %s", got)
	}
	push := k.secrets["holos-prj-platform/quay-robot-push-kagent"]
	if push == nil || string(push.data["username"]) != "kagent+push" || push.labels[managedByLabel] != managedBy {
		t.Errorf("push secret: %+v", push)
	}
	pull := k.secrets["holos-prj-platform/quay-robot-pull"]
	var cfg struct {
		Auths map[string]dockerAuth `json:"auths"`
	}
	if pull == nil || pull.typ != "kubernetes.io/dockerconfigjson" || json.Unmarshal(pull.data[".dockerconfigjson"], &cfg) != nil {
		t.Fatalf("pull secret: %+v", pull)
	}
	host := strings.TrimPrefix(srv.URL, "https://")
	if a := cfg.Auths[host+"/substrate"]; a.Username != "substrate+pull" || a.Password != "tok-substrate+pull" {
		t.Errorf("pull auths: %+v", cfg.Auths)
	}

	quayWrites, kubeWrites := f.writes, k.writes
	if err := runRobots(ctx, k, o, roots); err != nil {
		t.Fatal(err)
	}
	if f.writes != quayWrites || k.writes != kubeWrites {
		t.Errorf("second run wrote: %d Quay writes, %d Secret writes", f.writes-quayWrites, k.writes-kubeWrites)
	}
}
