package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strings"
	"time"
)

// maxBody bounds a response read. Quay's answers are small and Keycloak's
// pages tens of kilobytes; anything larger is a proxy's error page.
const maxBody = 4 << 20

// quayClient talks to Quay two ways, because Quay needs both. A browser
// session, a cookie jar and a fresh X-CSRF-Token per mutating call, is the
// only way to get a credential at all: there is no password grant, and the
// OAuth authorize endpoint answers only a logged-in session. A Bearer token
// is what everything after uses, and it needs no CSRF token.
type quayClient struct {
	// base is Quay's root URL, without a trailing slash.
	base string
	// http follows redirects, as a browser would; noRedirect shares its jar
	// and transport but stops at the first response, which is how the
	// implicit grant's Location is read.
	http       *http.Client
	noRedirect *http.Client
	// bearer, when set, authenticates requests instead of the session.
	bearer string
}

type quayUser struct {
	Username  string `json:"username"`
	SuperUser bool   `json:"super_user"`
}

type quayApplication struct {
	Name     string `json:"name"`
	ClientID string `json:"client_id"`
}

type quayRobot struct {
	Name  string `json:"name"`
	Token string `json:"token"`
}

// newQuayClient builds a client that trusts roots, the private CA's, beside
// the system's. Verification is never skipped: the session carries a
// superuser's password.
func newQuayClient(base string, roots []byte) (*quayClient, error) {
	pool, err := x509.SystemCertPool()
	if err != nil || pool == nil {
		pool = x509.NewCertPool()
	}
	if len(roots) > 0 && !pool.AppendCertsFromPEM(roots) {
		return nil, errors.New("the private root holds no PEM certificate")
	}
	jar, err := cookiejar.New(nil)
	if err != nil {
		return nil, err
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	return &quayClient{
		base: strings.TrimRight(base, "/"),
		http: &http.Client{Jar: jar, Transport: transport, Timeout: time.Minute},
		noRedirect: &http.Client{
			Jar:           jar,
			Transport:     transport,
			Timeout:       time.Minute,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}, nil
}

// httpError carries a non-2xx answer, because Quay puts the only useful
// explanation in the body.
type httpError struct {
	method, path string
	status       int
	body         string
}

func (e *httpError) Error() string {
	body := strings.TrimSpace(e.body)
	if len(body) > 512 {
		body = body[:512] + "..."
	}
	return fmt.Sprintf("%s %s: HTTP %d: %s", e.method, e.path, e.status, body)
}

func statusOf(err error) int {
	var he *httpError
	if errors.As(err, &he) {
		return he.status
	}
	return 0
}

func bodyContains(err error, needle string) bool {
	var he *httpError
	return errors.As(err, &he) && strings.Contains(he.body, needle)
}

// errRejected marks a credential the server refused, a 401 or a 403, as
// against a request that could not be completed. Only a refusal is grounds
// for minting another token: a token stays live until someone revokes it, so
// minting on a network fault or a 502 would leave another live superuser
// token behind each time.
var errRejected = errors.New("the server rejected the credential")

// do sends a JSON request to path and decodes the answer into out, which
// may be nil. csrf is sent when set, and the bearer token when the client
// holds one.
func (q *quayClient) do(ctx context.Context, method, path string, body any, csrf string, out any) error {
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		r = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, q.base+path, r)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if csrf != "" {
		req.Header.Set("X-CSRF-Token", csrf)
	}
	if q.bearer != "" {
		req.Header.Set("Authorization", "Bearer "+q.bearer)
	}
	resp, err := q.http.Do(req)
	if err != nil {
		return fmt.Errorf("%s %s: %w", method, path, err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, maxBody))
	if err != nil {
		return fmt.Errorf("%s %s: %w", method, path, err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return &httpError{method: method, path: path, status: resp.StatusCode, body: string(b)}
	}
	if out == nil || len(bytes.TrimSpace(b)) == 0 {
		return nil
	}
	if err := json.Unmarshal(b, out); err != nil {
		return fmt.Errorf("decoding %s %s: %w", method, path, err)
	}
	return nil
}

// csrfToken fetches a fresh CSRF token. Quay rotates it with the session,
// and a reused one fails as if it were an authorization problem, so every
// mutating session call fetches its own.
func (q *quayClient) csrfToken(ctx context.Context) (string, error) {
	var out struct {
		Token string `json:"csrf_token"`
	}
	if err := q.do(ctx, http.MethodGet, "/csrf_token", nil, "", &out); err != nil {
		return "", err
	}
	if out.Token == "" {
		return "", errors.New("/csrf_token returned no token")
	}
	return out.Token, nil
}

// mutate sends a mutating session call with a fresh CSRF token.
func (q *quayClient) mutate(ctx context.Context, method, path string, body, out any) error {
	csrf := ""
	if q.bearer == "" {
		var err error
		if csrf, err = q.csrfToken(ctx); err != nil {
			return err
		}
	}
	return q.do(ctx, method, path, body, csrf, out)
}

// verifyToken reports who token acts as and whether it carries the scopes
// holos-controller needs. It probes endpoints rather than reading a flag:
// GET /api/v1/user/ reports super_user for the account, whatever the token
// may do. aavis-ops measured on Quay 3.17.3 that a narrower token answers 403
// on /api/v1/superuser/organizations/ without super:user and on an
// organization's robots without org:admin. The automation organization is the
// probe's target because it hosts the Application: whenever a token exists,
// so does it. A 401 or 403 is wrapped in errRejected.
func (q *quayClient) verifyToken(ctx context.Context, token, automationOrg string) (*quayUser, error) {
	probe := &quayClient{base: q.base, http: &http.Client{Transport: q.http.Transport, Timeout: time.Minute}, bearer: token}
	reject := func(err error, what string) error {
		if s := statusOf(err); s == http.StatusUnauthorized || s == http.StatusForbidden {
			return fmt.Errorf("%w: it lacks %s (%v)", errRejected, what, err)
		}
		return err
	}
	user := &quayUser{}
	if err := probe.do(ctx, http.MethodGet, "/api/v1/user/", nil, "", user); err != nil {
		return nil, reject(err, "an identity")
	}
	if user.Username == "" {
		return nil, fmt.Errorf("%w: it acts as nobody", errRejected)
	}
	if err := probe.do(ctx, http.MethodGet, "/api/v1/superuser/organizations/", nil, "", nil); err != nil {
		return nil, reject(err, "the super:user scope")
	}
	if err := probe.do(ctx, http.MethodGet, "/api/v1/organization/"+url.PathEscape(automationOrg)+"/robots", nil, "", nil); err != nil {
		return nil, reject(err, "the org:admin scope")
	}
	return user, nil
}

// page is a fetched HTML page: where it ended up, and its forms.
type page struct {
	url   string
	forms []*form
}

// readPage turns a response into a page. Its status is not checked: the
// login chain ends on Quay's root, whatever it answers, with the session
// already set; whether the login worked is asked of /api/v1/user/.
func readPage(resp *http.Response, err error) (*page, error) {
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, maxBody))
	if err != nil {
		return nil, err
	}
	forms, err := parseForms(string(b), resp.Request.URL)
	if err != nil {
		return nil, err
	}
	return &page{url: resp.Request.URL.Host + resp.Request.URL.Path, forms: forms}, nil
}

// submit posts f with overrides over its pre-filled values.
func (q *quayClient) submit(ctx context.Context, f *form, overrides url.Values) (*page, error) {
	req, err := f.request(ctx, overrides)
	if err != nil {
		return nil, err
	}
	return readPage(q.http.Do(req))
}

// login gets a Quay session through Keycloak's authorization code flow, with
// the forms a browser would fill. Quay hands back the Keycloak URL rather
// than redirecting, because its UI opens it itself.
func (q *quayClient) login(ctx context.Context, username, password string) error {
	csrf, err := q.csrfToken(ctx)
	if err != nil {
		return err
	}
	var ext struct {
		AuthURL string `json:"auth_url"`
	}
	if err := q.do(ctx, http.MethodPost, "/api/v1/externallogin/keycloak", map[string]string{"kind": "login"}, csrf, &ext); err != nil {
		return fmt.Errorf("starting the Keycloak login: %w", err)
	}
	if ext.AuthURL == "" {
		return errors.New("quay returned no Keycloak URL")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, ext.AuthURL, nil)
	if err != nil {
		return err
	}
	p, err := readPage(q.http.Do(req))
	if err != nil {
		return fmt.Errorf("fetching the Keycloak login page: %w", err)
	}
	f := findForm(p.forms, (*form).isLogin)
	if f == nil {
		return fmt.Errorf("no username and password form at %s", p.url)
	}
	if p, err = q.submit(ctx, f, url.Values{"username": {username}, "password": {password}}); err != nil {
		return fmt.Errorf("submitting the Keycloak login form: %w", err)
	}
	// The realm user is imported with both names and a verified email, so
	// Keycloak has no profile to ask for. If it asks anyway, fix the user
	// rather than have this program write to the realm.
	if findForm(p.forms, (*form).isProfile) != nil {
		return fmt.Errorf("keycloak asks %s to complete its profile; set its first and last name in the realm", username)
	}
	if findForm(p.forms, (*form).isLogin) != nil {
		return fmt.Errorf("keycloak presented the login form again at %s; check %s's password", p.url, username)
	}
	user := &quayUser{}
	if err := q.do(ctx, http.MethodGet, "/api/v1/user/", nil, "", user); err != nil {
		return fmt.Errorf("the login left no Quay session: %w", err)
	}
	if user.Username != username {
		return fmt.Errorf("signed in to Quay as %q, want %q", user.Username, username)
	}
	// A session has the user's full rights, so here the flag is the truth.
	if !user.SuperUser {
		return fmt.Errorf("%s is not a Quay superuser; it must be in SUPER_USERS", username)
	}
	logf("signed in to Quay as %s, a superuser", username)
	return nil
}

// ensureOrganization creates the organization if it does not exist. Quay
// wants a unique email for every namespace.
func (q *quayClient) ensureOrganization(ctx context.Context, name, email string) (bool, error) {
	err := q.do(ctx, http.MethodGet, "/api/v1/organization/"+url.PathEscape(name), nil, "", nil)
	if err == nil {
		return false, nil
	}
	if statusOf(err) != http.StatusNotFound {
		return false, fmt.Errorf("reading organization %s: %w", name, err)
	}
	err = q.mutate(ctx, http.MethodPost, "/api/v1/organization/", map[string]string{"name": name, "email": email}, nil)
	switch {
	case bodyContains(err, "already exists"):
		return false, nil
	case err != nil:
		return false, fmt.Errorf("creating organization %s: %w", name, err)
	}
	logf("created organization %s", name)
	return true, nil
}

// ensureApplication returns the organization's OAuth Application by name,
// creating it if absent. The client ID is Quay's to choose and the name is
// ours, so a second run finds the first run's Application by its name.
func (q *quayClient) ensureApplication(ctx context.Context, org, name string) (*quayApplication, error) {
	path := "/api/v1/organization/" + url.PathEscape(org) + "/applications"
	var list struct {
		Applications []quayApplication `json:"applications"`
	}
	if err := q.do(ctx, http.MethodGet, path, nil, "", &list); err != nil {
		return nil, fmt.Errorf("listing applications in %s: %w", org, err)
	}
	for i := range list.Applications {
		if list.Applications[i].Name == name {
			return &list.Applications[i], nil
		}
	}
	app := &quayApplication{}
	if err := q.mutate(ctx, http.MethodPost, path, map[string]string{
		"name":        name,
		"description": "holos-controller's Quay credential (cmd/quay-bootstrap in holos-run/distro)",
	}, app); err != nil {
		return nil, fmt.Errorf("creating application %s/%s: %w", org, name, err)
	}
	if app.ClientID == "" {
		return nil, fmt.Errorf("quay made application %s/%s with no client id", org, name)
	}
	logf("created OAuth application %s/%s", org, name)
	return app, nil
}

// mintToken generates a token for the Application with the implicit grant
// the UI's Generate Token button drives. For a session that administers the
// Application's organization Quay answers with the redirect at once, the
// token in its fragment. Should Quay render its consent page instead, its
// form is submitted, as the Authorize button would.
func (q *quayClient) mintToken(ctx context.Context, clientID string, scopes []string) (string, error) {
	params := url.Values{
		"response_type": {"token"},
		"client_id":     {clientID},
		"scope":         {strings.Join(scopes, " ")},
		"redirect_uri":  {q.base + "/oauth/localapp"},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, q.base+"/oauth/authorize?"+params.Encode(), nil)
	if err != nil {
		return "", err
	}
	resp, err := q.noRedirect.Do(req)
	if err != nil {
		return "", fmt.Errorf("GET /oauth/authorize: %w", err)
	}
	if loc := resp.Header.Get("Location"); resp.StatusCode >= 300 && resp.StatusCode < 400 && loc != "" {
		resp.Body.Close()
		return fragmentValue(loc, "access_token")
	}
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, maxBody))
		resp.Body.Close()
		return "", &httpError{method: http.MethodGet, path: "/oauth/authorize", status: resp.StatusCode, body: string(b)}
	}
	consent, err := readPage(resp, nil)
	if err != nil {
		return "", err
	}
	f := findForm(consent.forms, func(f *form) bool { return strings.Contains(f.action, "authorizeapp") })
	if f == nil {
		return "", fmt.Errorf("quay rendered %s with no authorize form", consent.url)
	}
	csrf, err := q.csrfToken(ctx)
	if err != nil {
		return "", err
	}
	post, err := f.request(ctx, params)
	if err != nil {
		return "", err
	}
	post.Header.Set("X-CSRF-Token", csrf)
	presp, err := q.noRedirect.Do(post)
	if err != nil {
		return "", fmt.Errorf("POST %s: %w", f.action, err)
	}
	defer presp.Body.Close()
	loc := presp.Header.Get("Location")
	if loc == "" {
		b, _ := io.ReadAll(io.LimitReader(presp.Body, maxBody))
		return "", &httpError{method: http.MethodPost, path: "/oauth/authorizeapp", status: presp.StatusCode, body: string(b)}
	}
	return fragmentValue(loc, "access_token")
}

// ensureRobot returns the organization's robot, creating it if absent.
// Quay answers a read of a missing robot, and of a missing organization,
// with 400.
func (q *quayClient) ensureRobot(ctx context.Context, org, short string) (*quayRobot, bool, error) {
	path := "/api/v1/organization/" + url.PathEscape(org) + "/robots/" + url.PathEscape(short)
	robot := &quayRobot{}
	err := q.do(ctx, http.MethodGet, path, nil, "", robot)
	switch {
	case err == nil && robot.Token != "":
		return robot, false, nil
	case err == nil:
		return nil, false, fmt.Errorf("quay returned robot %s+%s with no token", org, short)
	case bodyContains(err, "Organization does not exist"):
		return nil, false, fmt.Errorf("organization %s does not exist in Quay yet; wait for its Organization to be Ready", org)
	case statusOf(err) != http.StatusBadRequest && statusOf(err) != http.StatusNotFound:
		return nil, false, fmt.Errorf("reading robot %s+%s: %w", org, short, err)
	}
	robot = &quayRobot{}
	if err := q.mutate(ctx, http.MethodPut, path, map[string]string{"description": "made by cmd/quay-bootstrap"}, robot); err != nil {
		return nil, false, fmt.Errorf("creating robot %s+%s: %w", org, short, err)
	}
	if robot.Token == "" {
		return nil, false, fmt.Errorf("quay made robot %s+%s with no token", org, short)
	}
	logf("created robot %s", robot.Name)
	return robot, true, nil
}

// ensureTeamMember makes team in org, with role and description, if it does
// not exist, sets its role if it has another, and puts member in it. The
// description is sent only when the team is made, so one set by hand stays. Quay lets a robot into a team of its
// own organization only, and a team is the only way to give one an
// organization role, such as creator.
func (q *quayClient) ensureTeamMember(ctx context.Context, org, team, role, description, member string) (bool, error) {
	var o struct {
		Teams map[string]struct {
			Role string `json:"role"`
		} `json:"teams"`
	}
	if err := q.do(ctx, http.MethodGet, "/api/v1/organization/"+url.PathEscape(org), nil, "", &o); err != nil {
		return false, fmt.Errorf("reading organization %s: %w", org, err)
	}
	changed := false
	teamPath := "/api/v1/organization/" + url.PathEscape(org) + "/team/" + url.PathEscape(team)
	if t, ok := o.Teams[team]; !ok || t.Role != role {
		body := map[string]string{"role": role}
		if !ok {
			body["description"] = description
		}
		if err := q.mutate(ctx, http.MethodPut, teamPath, body, nil); err != nil {
			return false, fmt.Errorf("setting team %s/%s: %w", org, team, err)
		}
		logf("set team %s/%s to role %s", org, team, role)
		changed = true
	}
	var m struct {
		Members []struct {
			Name string `json:"name"`
		} `json:"members"`
	}
	if err := q.do(ctx, http.MethodGet, teamPath+"/members", nil, "", &m); err != nil {
		return false, fmt.Errorf("listing team %s/%s: %w", org, team, err)
	}
	for _, x := range m.Members {
		if x.Name == member {
			return changed, nil
		}
	}
	if err := q.mutate(ctx, http.MethodPut, teamPath+"/members/"+url.PathEscape(member), map[string]string{}, nil); err != nil {
		return false, fmt.Errorf("adding %s to team %s/%s: %w", member, org, team, err)
	}
	logf("added %s to team %s/%s", member, org, team)
	return true, nil
}

// ensureDefaultPermission gives robot role on every repository made in org
// from now on, by an organization default permission (a prototype). Quay
// applies one only to repositories made after it exists, so existing ones
// are granted one by one (ensureRepositoryRole).
func (q *quayClient) ensureDefaultPermission(ctx context.Context, org, robot, role string) (bool, error) {
	path := "/api/v1/organization/" + url.PathEscape(org) + "/prototypes"
	var list struct {
		Prototypes []struct {
			ID             string `json:"id"`
			Role           string `json:"role"`
			ActivatingUser *struct {
				Name string `json:"name"`
			} `json:"activating_user"`
			Delegate struct {
				Name string `json:"name"`
			} `json:"delegate"`
		} `json:"prototypes"`
	}
	if err := q.do(ctx, http.MethodGet, path, nil, "", &list); err != nil {
		return false, fmt.Errorf("listing default permissions in %s: %w", org, err)
	}
	for _, p := range list.Prototypes {
		if p.Delegate.Name != robot || p.ActivatingUser != nil {
			continue
		}
		if p.Role == role {
			return false, nil
		}
		if err := q.mutate(ctx, http.MethodPut, path+"/"+url.PathEscape(p.ID), map[string]string{"role": role}, nil); err != nil {
			return false, fmt.Errorf("setting %s's default permission in %s: %w", robot, org, err)
		}
		logf("set %s's default permission in %s to %s", robot, org, role)
		return true, nil
	}
	body := map[string]any{"role": role, "delegate": map[string]string{"kind": "user", "name": robot}}
	if err := q.mutate(ctx, http.MethodPost, path, body, nil); err != nil {
		return false, fmt.Errorf("adding %s's default permission in %s: %w", robot, org, err)
	}
	logf("gave %s %s on new repositories in %s", robot, role, org)
	return true, nil
}

// listRepositories returns the names of the organization's repositories.
func (q *quayClient) listRepositories(ctx context.Context, org string) ([]string, error) {
	var list struct {
		Repositories []struct {
			Name string `json:"name"`
		} `json:"repositories"`
	}
	if err := q.do(ctx, http.MethodGet, "/api/v1/repository?namespace="+url.QueryEscape(org), nil, "", &list); err != nil {
		return nil, fmt.Errorf("listing repositories in %s: %w", org, err)
	}
	names := make([]string, 0, len(list.Repositories))
	for _, r := range list.Repositories {
		names = append(names, r.Name)
	}
	return names, nil
}

// roleRank orders repository roles, so a grant never lowers one: a push
// robot that made a repository by pushing to it is its admin.
var roleRank = map[string]int{"read": 1, "write": 2, "admin": 3}

// ensureRepositoryRole gives robot at least role on one repository. Quay
// reports a missing permission as 400.
func (q *quayClient) ensureRepositoryRole(ctx context.Context, org, repo, robot, role string) (bool, error) {
	path := "/api/v1/repository/" + url.PathEscape(org) + "/" + url.PathEscape(repo) + "/permissions/user/" + url.PathEscape(robot)
	var cur struct {
		Role string `json:"role"`
	}
	err := q.do(ctx, http.MethodGet, path, nil, "", &cur)
	if err == nil && roleRank[cur.Role] >= roleRank[role] {
		return false, nil
	}
	if err != nil && statusOf(err) != http.StatusBadRequest && statusOf(err) != http.StatusNotFound {
		return false, fmt.Errorf("reading %s's role on %s/%s: %w", robot, org, repo, err)
	}
	if err := q.mutate(ctx, http.MethodPut, path, map[string]string{"role": role}, nil); err != nil {
		return false, fmt.Errorf("giving %s %s on %s/%s: %w", robot, role, org, repo, err)
	}
	logf("gave %s %s on %s/%s", robot, role, org, repo)
	return true, nil
}
