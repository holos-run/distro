package main

import (
	"net/url"
	"testing"
)

// keycloakLogin is the shape of Keycloak's login page: a script that
// mentions a form, the login form with an escaped relative action, a submit
// button, an unchecked checkbox and a hidden field.
const keycloakLogin = `<!DOCTYPE html><html><head>
<script type="module">const s = "<form action='/nope'><input name='x'></form>"; if (a < b && c) {}</script>
<!-- <form action="/commented"><input name="username"><input name="password"></form> -->
</head><body>
<form id="kc-form-login" onsubmit="login.disabled = true; return true;" action="login-actions/authenticate?session_code=abc&amp;execution=xyz&amp;tab_id=t1" method="post" novalidate="novalidate">
  <input tabindex="1" id="username" name="username" value="" type="text" autofocus autocomplete="username" aria-invalid=""/>
  <input tabindex="2" id="password" name="password" type="password" autocomplete="current-password"/>
  <input id="rememberMe" name="rememberMe" type="checkbox" value="on">
  <input type="hidden" id="id-hidden-input" name="credentialId" value='cred-1'/>
  <button tabindex="4" name="login" id="kc-login" type="submit">Sign In</button>
</form>
</body></html>`

const keycloakProfile = `<html><body>
<form id="kc-update-profile-form" action="https://keycloak.example/realms/holos/login-actions/required-action?execution=VERIFY_PROFILE&amp;tab_id=t1" method="post">
  <input type="text" id="email" name="email" value="svc@example"/>
  <input type="text" id="firstName" name="firstName" value=""/>
  <input type="text" id="lastName" name="lastName" value=""/>
  <input type="submit" value="Submit"/>
</form></body></html>`

func TestParseForms(t *testing.T) {
	base, _ := url.Parse("https://keycloak.example/realms/holos/protocol/openid-connect/auth?client_id=quay")
	forms, err := parseForms(keycloakLogin, base)
	if err != nil {
		t.Fatal(err)
	}
	if len(forms) != 1 {
		t.Fatalf("got %d forms, want 1 (script and comment ignored)", len(forms))
	}
	f := forms[0]
	if want := "https://keycloak.example/realms/holos/protocol/openid-connect/login-actions/authenticate?session_code=abc&execution=xyz&tab_id=t1"; f.action != want {
		t.Errorf("action %q, want %q", f.action, want)
	}
	if f.method != "POST" {
		t.Errorf("method %q", f.method)
	}
	if !f.isLogin() || f.isProfile() {
		t.Errorf("isLogin %v isProfile %v", f.isLogin(), f.isProfile())
	}
	if got := f.values.Encode(); got != "credentialId=cred-1" {
		t.Errorf("values %q, want only the hidden field", got)
	}

	forms, err = parseForms(keycloakProfile, base)
	if err != nil {
		t.Fatal(err)
	}
	if p := findForm(forms, (*form).isProfile); p == nil || p.values.Get("email") != "svc@example" {
		t.Errorf("profile form not found or wrong: %+v", forms)
	}
	if findForm(forms, (*form).isLogin) != nil {
		t.Error("profile form taken for a login form")
	}
}

func TestFragmentValue(t *testing.T) {
	got, err := fragmentValue("https://quay.example/oauth/localapp#access_token=tok&token_type=Bearer&expires_in=315576000", "access_token")
	if err != nil || got != "tok" {
		t.Errorf("got %q, %v", got, err)
	}
	if _, err := fragmentValue("https://quay.example/oauth/localapp?access_token=tok", "access_token"); err == nil {
		t.Error("a token in the query, not the fragment, was accepted")
	}
	if _, err := fragmentValue("https://quay.example/oauth/localapp#error=access_denied", "access_token"); err == nil {
		t.Error("a fragment without the token was accepted")
	}
}
