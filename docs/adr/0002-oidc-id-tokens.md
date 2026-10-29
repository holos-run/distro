# 0002. OIDC ID tokens, never access tokens

Status: accepted, 2026-10-27

## Context

Every person on the platform logs in through Keycloak, the realm `holos` at
`https://keycloak.bank.internal/realms/holos`, and then presents a token to
the service they use: Argo CD, the Kubernetes API through `kubectl`, the
Secrets Manager, and later Substrate's shim, holos-authenticator and kagent.
Each service has to decide which of the tokens Keycloak issues it accepts.

The Secrets Manager (holos-run/secrets-manager v0.19.0) showed the cost of
leaving that open. Its SPA sent the OAuth access token as its bearer, and
its server checked that token with go-oidc's ID token verifier, which
requires `aud` to hold the client ID. Keycloak's access tokens in this
realm carry no `aud` at all (found in holos-controller-and-the-realm), so
every call after login would have been refused. The fixes on offer each
bent something to fit the access token: teach the server to accept an
access token whose `azp` is its client, or add an audience mapper to the
client in the realm import or in holos-controller's `Client`, which has no
field for one (interview Q53).

The two tokens are different kinds of thing:

- **The access token is opaque to its client.** OAuth 2.0 defines it as a
  credential for a resource server, a string that is "usually opaque to
  the client" (RFC 6749 §1.4), whose format and claims are the
  authorization server's business. Keycloak happens to issue JWTs, but
  nothing in OAuth says what claims they carry, and here `aud` is absent.
- **The ID token is defined.** OpenID Connect defines it as a JWT with
  specified claims (OIDC Core §2): `iss`, `sub`, `aud`, which must contain
  the client ID of the relying party it was issued to, `exp`, `iat`, and
  `azp` when needed. With the `email` scope it carries `email` and
  `email_verified`; in this realm the `groups` scope, a default, puts each
  person's groups in `groups` by full path (`/platform/owners`).

## Decision

Holos services authenticate a person with the OIDC ID token, never the
OAuth access token. A service verifies the ID token's signature against the
issuer's JWKS, its `iss`, its `exp`, and that its `aud` holds the service's
own client ID, and takes the person's identity and groups from its claims.

Jeff McCune, answering Q53:

> "Do not use access tokens.  Use ID tokens.  Record this as a project wide
> decision in the Holos distribution.  Access Tokens are opaque as per the
> OAuth specification, OIDC ID tokens are well defined as JWT encoding with
> specified claim fields, like email when the correct scopes are passed."

A client that needs a claim asks for the scope that puts it in the ID
token: `openid` always, `email` for `email`, `groups` for `groups` (a
default scope in this realm, so present without asking). A missing `aud` is
fixed by sending the ID token, not by an audience mapper.

## Consequences

- **The Secrets Manager** SPA sends the ID token as its bearer, a fix in
  holos-run/secrets-manager; the server's verifier stays as it is. The
  distro pins the release that carries the fix in `SecretsManager.image`
  (`holos/components/secrets-manager.cue`); v0.19.0, which sends the access
  token, has every API call after login refused.
- **substrate-shim, holos-authenticator and kagent's oauth2-proxy** check
  the ID token when they are built: holos-authenticator and kagent's
  oauth2-proxy with `aud` their own client ID, substrate-shim with `aud`
  `kubectl`, since curl carries the token kubectl does (below). None of them
  accepts an access token, and none needs an audience mapper in the realm.
- **Argo CD and `kubectl`** already use ID tokens: Argo CD's OIDC login
  verifies the ID token for client `argocd`, and kubelogin presents the ID
  token of client `kubectl`, whose `aud` is `kubectl`, the audience
  substrate-shim pins.
- An ID token is meant for the client it was issued to, so a service
  accepts only ID tokens with its own client ID in `aud`; a token issued
  to one client is not replayed at another. A service that calls another on
  a person's behalf needs its own design, token exchange or a service
  identity, and a decision of its own; this one does not cover it.
- ID tokens are not refreshed by the resource server. A browser client
  refreshes them with the refresh token, as the Secrets Manager's SPA does
  with `offline_access`, and a CLI with kubelogin's cache.
