package main

import (
	"fmt"
	"html"
	"net/url"
	"regexp"
	"strings"
)

// form is one <form> lifted out of a page: where it posts and the fields it
// would submit untouched. Keycloak's login form carries a session_code, an
// execution id and a tab_id minted per page load in its action, so the form
// is read off the page and replayed rather than its endpoint guessed.
type form struct {
	// action is the absolute URL the form submits to.
	action string
	// method is the uppercased HTTP method, GET unless the form says.
	method string
	// values are the form's pre-filled values, in submission form.
	values url.Values
	// fields lists every input name, the empty ones included.
	fields map[string]bool
}

func (f *form) has(name string) bool { return f.fields[name] }

// isLogin reports whether this is Keycloak's username and password form.
func (f *form) isLogin() bool { return f.has("username") && f.has("password") }

// isProfile reports whether this is Keycloak's VERIFY_PROFILE form, the only
// form in the login flow that asks for both names.
func (f *form) isProfile() bool { return f.has("firstName") && f.has("lastName") }

// The module has no dependencies, so the forms are found with regular
// expressions rather than an HTML parser. That is enough for the few,
// well-formed pages Keycloak and Quay serve here: scripts, styles and
// comments are removed first, so markup inside them is not mistaken for a
// form, and forms do not nest.
var (
	reIgnored = regexp.MustCompile(`(?is)<!--.*?-->|<script\b.*?</script\s*>|<style\b.*?</style\s*>`)
	reForm    = regexp.MustCompile(`(?is)<form\b([^>]*)>(.*?)</form\s*>`)
	reInput   = regexp.MustCompile(`(?is)<(input|select|textarea|button)\b([^>]*)>`)
	reAttr    = regexp.MustCompile(`(?s)([^\s"'<>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>` + "`" + `]+)))?`)
)

// attrs parses a tag's attributes, lowercasing names and unescaping values.
func attrs(s string) map[string]string {
	out := map[string]string{}
	for _, m := range reAttr.FindAllStringSubmatch(s, -1) {
		name := strings.ToLower(m[1])
		if _, seen := out[name]; seen {
			continue // the first of a repeated attribute wins, as in HTML
		}
		out[name] = html.UnescapeString(m[2] + m[3] + m[4])
	}
	return out
}

// parseForms returns every form on page, with relative actions resolved
// against base.
func parseForms(page string, base *url.URL) ([]*form, error) {
	page = reIgnored.ReplaceAllString(page, "")
	var forms []*form
	for _, m := range reForm.FindAllStringSubmatch(page, -1) {
		a := attrs(m[1])
		action, err := base.Parse(a["action"])
		if err != nil {
			return nil, fmt.Errorf("form action %q: %w", a["action"], err)
		}
		f := &form{
			action: action.String(),
			method: strings.ToUpper(a["method"]),
			values: url.Values{},
			fields: map[string]bool{},
		}
		if f.method == "" {
			f.method = "GET"
		}
		for _, in := range reInput.FindAllStringSubmatch(m[2], -1) {
			ia := attrs(in[2])
			name := ia["name"]
			if name == "" {
				continue
			}
			f.fields[name] = true
			typ := strings.ToLower(ia["type"])
			_, checked := ia["checked"]
			// An unchecked checkbox or radio submits nothing, and a button
			// submits only when it is the one pressed.
			if (typ == "checkbox" || typ == "radio") && !checked {
				continue
			}
			if strings.ToLower(in[1]) == "button" || typ == "submit" {
				continue
			}
			if v := ia["value"]; v != "" {
				f.values.Set(name, v)
			}
		}
		forms = append(forms, f)
	}
	return forms, nil
}

// findForm returns the first form satisfying match, or nil.
func findForm(forms []*form, match func(*form) bool) *form {
	for _, f := range forms {
		if match(f) {
			return f
		}
	}
	return nil
}

// fragmentValue returns one parameter of a URL's fragment. Quay's implicit
// grant puts the token in the fragment of its redirect, the part a browser
// never sends a server, so the token is read off the Location header.
func fragmentValue(location, key string) (string, error) {
	u, err := url.Parse(location)
	if err != nil {
		return "", fmt.Errorf("parsing redirect: %w", err)
	}
	if u.Fragment == "" {
		return "", fmt.Errorf("redirect to %s%s carries no fragment", u.Host, u.Path)
	}
	values, err := url.ParseQuery(u.Fragment)
	if err != nil {
		return "", fmt.Errorf("parsing the redirect's fragment: %w", err)
	}
	v := values.Get(key)
	if v == "" {
		return "", fmt.Errorf("the redirect's fragment carries no %s", key)
	}
	return v, nil
}
