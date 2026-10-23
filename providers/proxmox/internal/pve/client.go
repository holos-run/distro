// Package pve is a small client for the Proxmox VE REST API.
//
// It covers only what talosvm needs: reading cluster resources, nodes, guest
// configuration and the token's own permissions, asking for a free VMID, and
// sending the calls that fetch an ISO and create, stop and delete a VM, then
// waiting on the tasks those calls start. The API is plain
// JSON over HTTPS with an API token in one header, so the standard library is
// enough and the module keeps no dependencies.
//
// Every response wraps its payload in {"data": ...}. Calls that change the
// cluster return a UPID, the ID of an asynchronous task, and the change is only
// done when that task stops with exit status OK; WaitTask polls for that.
package pve

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
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Client talks to one Proxmox VE endpoint. Any node of a cluster serves the
// API for the whole cluster, so one endpoint is enough.
type Client struct {
	// BaseURL is the scheme, host and port, for example
	// https://r620a.lan:8006. The /api2/json prefix is added per request.
	BaseURL *url.URL
	// TokenID is USER@REALM!TOKENID and Secret is the token's UUID. They are
	// sent on every request as a PVEAPIToken header. Token requests need no
	// CSRF ticket, unlike password logins, which is one reason to use them.
	TokenID string
	Secret  string
	// HTTP is the client requests go through; NewHTTPClient builds one that
	// trusts the cluster's own CA.
	HTTP *http.Client
	// PollInterval is how often WaitTask asks for a task's status. Zero means
	// two seconds.
	PollInterval time.Duration
}

// New returns a client for endpoint. Plain http is accepted for tests; the
// talosvm command only accepts https.
//
// None of the errors quote the endpoint or the token ID. Both come from the
// environment, and a value in the wrong variable, such as the secret in
// PROXMOX_TOKEN_ID or credentials in the URL, would otherwise end up on the
// terminal and in CI logs.
func New(endpoint, tokenID, secret string, hc *http.Client) (*Client, error) {
	u, err := url.Parse(endpoint)
	if err != nil || u.Scheme != "https" && u.Scheme != "http" || u.Host == "" {
		return nil, errors.New("proxmox endpoint: want https://host:8006")
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		// Userinfo would also be repeated in every *url.Error a failed
		// request returns.
		return nil, errors.New("proxmox endpoint: want https://host:8006 without credentials, query or fragment")
	}
	if tokenID == "" || secret == "" {
		return nil, errors.New("proxmox API token ID and secret are both required")
	}
	if !strings.Contains(tokenID, "!") || !strings.Contains(tokenID, "@") {
		return nil, errors.New("proxmox token ID: want USER@REALM!TOKENID")
	}
	if hc == nil {
		hc = http.DefaultClient
	}
	u.Path = strings.TrimSuffix(u.Path, "/")
	return &Client{BaseURL: u, TokenID: tokenID, Secret: secret, HTTP: hc}, nil
}

// NewHTTPClient returns an HTTP client that verifies the server against the
// PEM bundle in caFile when one is given, and against the system roots
// otherwise. A Proxmox cluster signs its hosts' certificates with its own CA,
// and the right fix is to hand the program that CA (/etc/pve/pve-root-ca.pem
// on any node), so insecure is a separate, explicit choice and the two are not
// combined.
func NewHTTPClient(caFile string, insecure bool) (*http.Client, error) {
	if caFile != "" && insecure {
		return nil, errors.New("a CA file and insecure TLS are mutually exclusive")
	}
	tc := &tls.Config{MinVersion: tls.VersionTLS12}
	switch {
	case caFile != "":
		pem, err := os.ReadFile(caFile)
		if err != nil {
			return nil, fmt.Errorf("reading CA file: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("CA file %s holds no PEM certificates", caFile)
		}
		tc.RootCAs = pool
	case insecure:
		tc.InsecureSkipVerify = true
	}
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.TLSClientConfig = tc
	return &http.Client{Transport: tr, Timeout: 2 * time.Minute}, nil
}

// APIError is a non-2xx answer. Proxmox puts the reason in the HTTP status
// text and, for parameter errors, a map from parameter name to message in the
// body, so both are kept.
type APIError struct {
	Method string
	Path   string
	Status string
	Errors map[string]string
}

func (e *APIError) Error() string {
	msg := fmt.Sprintf("proxmox %s %s: %s", e.Method, e.Path, e.Status)
	if len(e.Errors) > 0 {
		keys := make([]string, 0, len(e.Errors))
		for k := range e.Errors {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		parts := make([]string, 0, len(keys))
		for _, k := range keys {
			parts = append(parts, k+": "+strings.TrimSpace(e.Errors[k]))
		}
		msg += " (" + strings.Join(parts, "; ") + ")"
	}
	return msg
}

// Do sends one request. path is already escaped: callers escape each
// segment they build from data, such as a UPID, whose token ID carries a !.
// It goes into RawPath as it is, with Path its decoded form, so the URL
// escapes it exactly once; appending it to Path alone would escape the %
// again and Proxmox would look for a task that does not exist. GET and
// DELETE carry params in the query string; POST and PUT send them form
// encoded, which is what the API expects. When out is not nil the
// response's data member is decoded into it.
func (c *Client) Do(ctx context.Context, method, path string, params url.Values, out any) error {
	u := *c.BaseURL
	escaped := c.BaseURL.EscapedPath() + "/api2/json" + path
	decoded, err := url.PathUnescape(escaped)
	if err != nil {
		return fmt.Errorf("proxmox %s %s: bad path: %w", method, path, err)
	}
	u.Path, u.RawPath = decoded, escaped
	var body io.Reader
	if method == http.MethodGet || method == http.MethodDelete {
		u.RawQuery = params.Encode()
	} else if params != nil {
		body = strings.NewReader(params.Encode())
	}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), body)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "PVEAPIToken="+c.TokenID+"="+c.Secret)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("proxmox %s %s: %w", method, path, err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		return fmt.Errorf("proxmox %s %s: reading response: %w", method, path, err)
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		apiErr := &APIError{Method: method, Path: path, Status: resp.Status}
		var env struct {
			Errors map[string]string `json:"errors"`
		}
		if json.Unmarshal(raw, &env) == nil {
			apiErr.Errors = env.Errors
		}
		return apiErr
	}
	if out == nil {
		return nil
	}
	var env struct {
		Data json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return fmt.Errorf("proxmox %s %s: decoding response: %w", method, path, err)
	}
	if err := json.Unmarshal(env.Data, out); err != nil {
		return fmt.Errorf("proxmox %s %s: decoding data: %w", method, path, err)
	}
	return nil
}

// Node is one entry of GET /nodes.
type Node struct {
	Node   string `json:"node"`
	Status string `json:"status"`
}

// Nodes lists the cluster's nodes.
func (c *Client) Nodes(ctx context.Context) ([]Node, error) {
	var nodes []Node
	err := c.Do(ctx, http.MethodGet, "/nodes", nil, &nodes)
	return nodes, err
}

// Resource is one guest from GET /cluster/resources?type=vm, which lists only
// the guests the token has VM.Audit on. It names the
// node the guest runs on, which is what later becomes a worker's zone label.
type Resource struct {
	VMID     int     `json:"vmid"`
	Name     string  `json:"name"`
	Node     string  `json:"node"`
	Type     string  `json:"type"`
	Status   string  `json:"status"`
	Tags     string  `json:"tags"`
	Template int     `json:"template"`
	MaxCPU   float64 `json:"maxcpu"`
	MaxMem   int64   `json:"maxmem"`
	MaxDisk  int64   `json:"maxdisk"`
}

// TagList splits the tags string. Proxmox stores tags separated by
// semicolons but accepts commas and spaces too, so all three are separators.
func (r Resource) TagList() []string {
	return strings.FieldsFunc(r.Tags, func(r rune) bool {
		return r == ';' || r == ',' || r == ' '
	})
}

// VMs lists every guest in the cluster, on every node, both QEMU VMs and LXC
// containers, since either can hold an address.
func (c *Client) VMs(ctx context.Context) ([]Resource, error) {
	var rs []Resource
	err := c.Do(ctx, http.MethodGet, "/cluster/resources", url.Values{"type": {"vm"}}, &rs)
	return rs, err
}

// Storage is one storage on one node from GET
// /cluster/resources?type=storage. A shared storage is listed once per node
// with Shared set, which is how create knows a single download serves every
// node.
type Storage struct {
	Node    string `json:"node"`
	Storage string `json:"storage"`
	Status  string `json:"status"`
	Shared  int    `json:"shared"`
	Content string `json:"content"`
}

// HasContent reports whether the storage accepts a content type such as
// images or iso.
func (s Storage) HasContent(content string) bool {
	for _, c := range strings.Split(s.Content, ",") {
		if strings.TrimSpace(c) == content {
			return true
		}
	}
	return false
}

// Storages lists every storage on every node.
func (c *Client) Storages(ctx context.Context) ([]Storage, error) {
	var ss []Storage
	err := c.Do(ctx, http.MethodGet, "/cluster/resources", url.Values{"type": {"storage"}}, &ss)
	return ss, err
}

// GuestConfig returns a guest's current configuration as strings. The API
// answers with a mix of JSON strings and numbers; only the text matters here.
func (c *Client) GuestConfig(ctx context.Context, r Resource) (map[string]string, error) {
	kind := r.Type
	if kind != "qemu" && kind != "lxc" {
		return nil, fmt.Errorf("guest %d has unknown type %q", r.VMID, r.Type)
	}
	path := "/nodes/" + url.PathEscape(r.Node) + "/" + kind + "/" + strconv.Itoa(r.VMID) + "/config"
	var raw map[string]json.RawMessage
	if err := c.Do(ctx, http.MethodGet, path, nil, &raw); err != nil {
		return nil, err
	}
	out := make(map[string]string, len(raw))
	for k, v := range raw {
		var s string
		if json.Unmarshal(v, &s) == nil {
			out[k] = s
		} else {
			out[k] = string(v)
		}
	}
	return out, nil
}

// ClusterName returns the Proxmox cluster's name from GET /cluster/status,
// or the empty string for a single host that is not in a cluster.
func (c *Client) ClusterName(ctx context.Context) (string, error) {
	var entries []struct {
		Type string `json:"type"`
		Name string `json:"name"`
	}
	if err := c.Do(ctx, http.MethodGet, "/cluster/status", nil, &entries); err != nil {
		return "", err
	}
	for _, e := range entries {
		if e.Type == "cluster" {
			return e.Name, nil
		}
	}
	return "", nil
}

// Permissions returns the privileges the caller holds on path and below,
// from GET /access/permissions. Every user and token may read its own, so
// this works before anything else is known to work.
//
// The answer maps each privilege to whether it propagates. A privilege that
// does not propagate holds on path alone, not on the /vms, /storage and /sdn
// paths below it that the program's calls are checked against, so only a
// propagating privilege is counted. Proxmox writes the flag as 1 or 0; true,
// false and their string forms are accepted too.
func (c *Client) Permissions(ctx context.Context, path string) (map[string]bool, error) {
	var tree map[string]map[string]json.RawMessage
	if err := c.Do(ctx, http.MethodGet, "/access/permissions", url.Values{"path": {path}}, &tree); err != nil {
		return nil, err
	}
	out := map[string]bool{}
	for priv, v := range tree[path] {
		switch strings.Trim(strings.TrimSpace(string(v)), `"`) {
		case "1", "true":
			out[priv] = true
		}
	}
	return out, nil
}

// NextID asks the cluster for a free VMID. The answer is a JSON string, not a
// number. Two callers at once can be handed the same ID; the second create
// then fails rather than overwriting, which is acceptable for one operator.
func (c *Client) NextID(ctx context.Context) (int, error) {
	var raw json.RawMessage
	if err := c.Do(ctx, http.MethodGet, "/cluster/nextid", nil, &raw); err != nil {
		return 0, err
	}
	s := strings.Trim(string(bytes.TrimSpace(raw)), `"`)
	id, err := strconv.Atoi(s)
	if err != nil {
		return 0, fmt.Errorf("proxmox /cluster/nextid: unexpected answer %s", raw)
	}
	return id, nil
}

// StorageContent is one volume from a storage's content listing.
type StorageContent struct {
	VolID string `json:"volid"`
}

// Content lists the volumes of one content type ("iso") in a storage as seen
// from node.
func (c *Client) Content(ctx context.Context, node, storage, content string) ([]StorageContent, error) {
	var cs []StorageContent
	path := "/nodes/" + url.PathEscape(node) + "/storage/" + url.PathEscape(storage) + "/content"
	err := c.Do(ctx, http.MethodGet, path, url.Values{"content": {content}}, &cs)
	return cs, err
}

// Post sends a POST that starts a task and returns its UPID.
func (c *Client) Post(ctx context.Context, path string, params url.Values) (string, error) {
	var upid string
	err := c.Do(ctx, http.MethodPost, path, params, &upid)
	return upid, err
}

// Delete sends a DELETE that starts a task and returns its UPID.
func (c *Client) Delete(ctx context.Context, path string, params url.Values) (string, error) {
	var upid string
	err := c.Do(ctx, http.MethodDelete, path, params, &upid)
	return upid, err
}

// TaskStatus is GET /nodes/{node}/tasks/{upid}/status.
type TaskStatus struct {
	Status     string `json:"status"`
	ExitStatus string `json:"exitstatus"`
}

// UPIDNode returns the node a task runs on, the second field of
// UPID:node:pid:pstart:starttime:type:id:user:.
func UPIDNode(upid string) (string, error) {
	f := strings.Split(upid, ":")
	if len(f) < 3 || f[0] != "UPID" || f[1] == "" {
		return "", fmt.Errorf("malformed UPID %q", upid)
	}
	return f[1], nil
}

// WaitTask polls a task until it stops and returns an error unless it ended
// with exit status OK. The context bounds the wait.
func (c *Client) WaitTask(ctx context.Context, upid string) error {
	node, err := UPIDNode(upid)
	if err != nil {
		return err
	}
	interval := c.PollInterval
	if interval == 0 {
		interval = 2 * time.Second
	}
	path := "/nodes/" + url.PathEscape(node) + "/tasks/" + url.PathEscape(upid) + "/status"
	for {
		var st TaskStatus
		if err := c.Do(ctx, http.MethodGet, path, nil, &st); err != nil {
			return err
		}
		if st.Status == "stopped" {
			// A task that finished but logged warnings reports
			// "WARNINGS: n"; Proxmox itself counts that as success.
			if st.ExitStatus != "OK" && !strings.HasPrefix(st.ExitStatus, "WARNINGS") {
				return fmt.Errorf("proxmox task %s failed: %s", upid, st.ExitStatus)
			}
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("waiting for proxmox task %s: %w", upid, ctx.Err())
		case <-time.After(interval):
		}
	}
}
