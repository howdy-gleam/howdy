# Howdy Auth compared with Better Auth

Reviewed 21 September 2026 against Howdy commit `9d59bbb` and Better Auth's
current official documentation. The working tree was clean at the start.
Enterprise federation/SSO, SAML and SCIM remain excluded as requested; their
presence in Howdy has not been evaluated here. Ordinary workspace membership is
considered separately because it also matters to non-enterprise SaaS products.
Better Auth plugin capabilities require installation/configuration, not just the
core package. Its online documentation is not a guarantee for every older release.

## Assessment

**Howdy is now close in core web-authentication workflow coverage, but still
substantially narrower as an integration platform.** The previous comparison
understates today's implementation. Password and account management, mainstream
social login, passkeys, MFA and stateful sessions no longer have major missing
categories. Matching every option, client integration and optional plugin remains
a different and larger objective.

For an Erlang/Howdy application using PostgreSQL or SQLite, the current feature
set is credible and broadly sufficient for ordinary browser authentication.
Better Auth still saves application developers more work around clients,
extensions, mobile, administration and alternative login experiences. Production
assurance cannot be inferred from matching feature names or counting tests.

## Previous gaps that are now closed

| Capability | Verified Howdy implementation | Assessment |
| --- | --- | --- |
| Current-password change | `change_password` checks the current password, shares guessing limits, preserves the caller and revokes other sessions; sends a notice | Core workflow covered; no email round trip required |
| Old-mailbox approval | `with_email_change_approval` adds approval before verifying the new address; completion notifies the old mailbox | Core workflow covered |
| Passkey RP/origins | Parent-domain RP IDs and additional ceremony origins; tests cover subdomains and refusal of unlisted origins | Present; bundled HTTP transport still enforces its public Origin |
| Passkey autofill | Conditional mediation, challenge renewal and cancellation when explicit sign-in starts | Present in starter pages |
| Passkey signup | Signed-out WebAuthn ceremony followed by email proof; account and credential created atomically on exchange | Present; email remains mandatory rather than arbitrary onboarding hooks |
| Remembered MFA devices | Configurable lifetime and optional renewal; recovery-code count configurable | Previous fixed-duration/count gap closed |
| Session renewal | Sliding expiry with optional absolute ceiling, idle expiry and updated external-store contract | Present, opt-in |
| Account switching | Multiple accounts in one browser, explicit switching and logout fallback | Present, opt-in |
| Encryption-key rotation | `mfa.with_decryption_keys` / `connection.with_decryption_keys` open with earlier keys; `auth.reseal_mfa` and `connections.reseal` re-encrypt online. Ciphertexts stay unversioned: authenticated trial decryption keeps existing values readable without a migration | Closed, including rolling deployments; Better Auth versions its ciphertexts instead ([secret rotation](https://better-auth.com/docs/reference/security#secret-rotation)) |
| Magic links and email codes | `auth.with_email_links` adds a fragment-carried link that the starter pages fill in and confirm with a click; `auth.with_email_codes` adds a six-digit code limited to three guesses and the password guessing budgets | Closed; one email carries link, code and token together, where Better Auth splits [magic-link](https://better-auth.com/docs/plugins/magic-link) and [email-OTP](https://better-auth.com/docs/plugins/email-otp) into plugins |
| Authenticator QR code | Server-rendered SVG in `MfaSetup.qr_code` and the enrollment JSON, shown on the starter account page | Closed; Better Auth leaves QR rendering to the application |
| Shared HTTP rate limits | `auth.with_shared_rate_limits` counts every auth route group's per-client limits in the auth database; `auth.with_rate_limit_store` takes any `rate_limit.Store`, such as Redis | Closed, comparable to Better Auth's database/secondary storage ([rate limiting](https://better-auth.com/docs/concepts/rate-limit)). A failing store allows the request; the credential guessing limits never fail open |
| Other OAuth/OIDC providers | `providers/oidc.new` configures any OpenID Connect issuer by discovery, verified like SSO connections; `provider.custom` is a supported contract for other OAuth 2.0 providers, namespaced so it cannot reach other issuers' accounts | Closed for sign-in; Better Auth's [generic OAuth plugin](https://better-auth.com/docs/plugins/generic-oauth) also keeps provider tokens, which Howdy deliberately does not |
| Apple login | Apple adapter, signed client-secret JWT, identity verification and POST callback handling | Present alongside Google, GitHub, Facebook and Entra |

Local evidence: [auth API](../auth/src/howdy/auth.gleam),
[MFA configuration](../auth/src/howdy/auth/mfa.gleam),
[starter pages](../auth/src/howdy/auth/pages.gleam),
[Apple adapter](../auth/src/howdy/auth/providers/apple.gleam),
[tests](../auth/test).
Better Auth comparison references: [passwords](https://better-auth.com/docs/authentication/email-password),
[accounts](https://better-auth.com/docs/concepts/users-accounts),
[passkeys](https://better-auth.com/docs/plugins/passkey),
[2FA](https://better-auth.com/docs/plugins/2fa),
[sessions](https://better-auth.com/docs/concepts/session-management),
[multi-session](https://better-auth.com/docs/plugins/multi-session),
[Apple](https://better-auth.com/docs/authentication/apple).

Registration, recovery, account deletion/cleanup, provider unlinking, scoped RBAC,
typed custom fields, trusted provisioning, suspension and session revocation were
already present. They must not be counted as missing in an updated assessment.

## Where Howdy remains weaker

### 1. Reusable frontend and mobile integration — high practical impact

The package offers typed Gleam operations, JSON endpoints and starter-page
JavaScript. It has no equivalent reusable browser SDK with typed errors, reactive
session state, framework bindings or mobile cookie/deep-link handling. Applications
with custom frontends must rebuild this glue. Better Auth supplies a
[client](https://better-auth.com/docs/concepts/client) and
[Expo integration](https://better-auth.com/docs/integrations/expo).

A small Howdy client handling signed-out, pending-MFA and signed-in states,
renewal and account switching would help more applications than another obscure
login method. Native bearer support already exists; the gap is integration work.

### 2. Specialized login methods — product-dependent

Clickable magic links, short email codes and a starter-page QR code for
authenticator setup are now built in (see the closed gaps above). Username,
phone, guest-to-registered/anonymous login and other specialized methods remain
missing; choose them from product requirements rather than aiming for an
unweighted plugin count. [Plugin catalog](https://better-auth.com/docs/plugins)

### 3. Operational controls — high impact before broader deployment

- **Release/dependency readiness is still limited.** Howdy depends on
  `glasslock 1.0.0-rc1`, including internal parsing APIs, and the README still
  requires stopping old instances before migrations. Passwords now use PBKDF2
  from OTP `crypto` rather than a patched, vendored Argon2 binding: no native
  build, but not memory-hard. These are operational constraints, not evidence
  of a particular vulnerability.
  [Installation](../auth/README.md#install-and-migrate)
- **The local test evidence is not a browser/device compatibility matrix.**
  Signed WebAuthn fixtures and a simulated DOM are valuable, but do not establish
  Safari/iOS/Android, real authenticators, credential-manager behavior or live
  Apple callback interoperability. Add real-browser tests and document supported
  devices/providers. No independent security review is established by this work.

### 4. Supported extension points and administration — medium impact

Howdy's functions are composable and include useful targeted callbacks, and
providers now have a supported contract (see the closed gaps above). There is
still no general endpoint/database hook or plugin contract. Its trusted administrative
functions also leave authorization, search/pagination and support interfaces to
applications. Better Auth supplies [hooks](https://better-auth.com/docs/concepts/hooks)
and a permission-controlled [admin plugin](https://better-auth.com/docs/plugins/admin),
including impersonation. That plugin is not a bundled hosted dashboard.

This is a developer-experience gap, not absence of role-based authorization or
user suspension in Howdy. A small administrative API could close the useful
remainder without building a large plugin framework.

### 5. Product-dependent capabilities — significant when needed

| Capability | Howdy difference | Better Auth reference |
| --- | --- | --- |
| Integration/API credentials | Bearer sessions exist, but no independent scoped API-key lifecycle with expiry and per-key limits | [API keys](https://better-auth.com/docs/plugins/api-key) |
| Shared workspaces | Each user belongs to one group, or has separate accounts per group; no one-identity/multiple-membership model, invitation lifecycle or teams | [Organizations](https://better-auth.com/docs/plugins/organization) |
| Ongoing provider API access | Provider access/refresh tokens are discarded; no packaged scope-management/token-refresh workflow | [Accounts](https://better-auth.com/docs/concepts/users-accounts) |
| Storage/platform choice | Erlang with Gloo PostgreSQL/SQLite; custom session adapter supplied by the app | Broader [database/adapters](https://better-auth.com/docs/concepts/database) and JS framework integrations |

These are not prerequisites for a normal Howdy browser app. API keys matter for
public APIs; memberships matter for collaborative SaaS; provider tokens matter
when accessing a user's external services rather than merely signing them in.

### 6. Smaller configuration and UI gaps

Howdy fixes TOTP to six digits/30 seconds and has fewer OTP/recovery/lockout knobs.
WebAuthn extensions, authenticator-policy selection and arbitrary pre-auth signup
hooks are not exposed. Required user verification and resident credentials are
intentional stronger requirements, not missing verification. Its signup retains
mandatory email ownership proof. [Better Auth MFA](https://better-auth.com/docs/plugins/2fa),
[passkey options](https://better-auth.com/docs/plugins/passkey)

## Strengths and differences worth preserving

Howdy gates enrolled MFA across its ordinary email/password/social/passkey
methods. Better Auth's documented default gates credential login, not all
passwordless/social methods. That is a meaningful policy distinction, not an
overall security ranking. Both have shared failed-MFA attempt protection.
[Better Auth enforcement](https://better-auth.com/docs/plugins/2fa)

Howdy also retains current account-state checks, session-token digests, explicit
linking and generation-based revocation for sensitive account changes. Its fresh
database checks cost reads, including with external sessions, but avoid the
staleness of optional cookie-cached session state. Better Auth documents that
cookie-cache revocation may remain stale until cache expiry. Do not add stateless
or cached sessions solely to match a checklist. [Session tradeoffs](https://better-auth.com/docs/concepts/session-management)

## Suggested next priorities

1. Dependency/release readiness and real-browser/device validation.
2. Focused administrative tools.
3. A reusable auth client.
4. API keys, memberships and more login methods only as required by the product.

Core workflow coverage is close; platform breadth remains substantially different;
production assurance requires evidence beyond this comparison. A single parity
percentage would conceal those distinctions.

## Verification and documentation

The auth suite was rerun for this review: **225 tests passed on SQLite and
225 on PostgreSQL**. The exact starter-page JavaScript passes **16 tests**, and
`examples/auth` passes `gleam check`. This is a feature
and implementation review, not an exhaustive vulnerability scan, performance
comparison, live-provider trial or full CI matrix run.

The README's old “Scope compared with Better Auth” paragraph incorrectly described
RP/origin configuration, autofill, signup and configurable device trust as missing.
It has been corrected alongside this comparison. Implementation behavior was
checked rather than inferred from that stale text. Additional primary-source
notes: [current research](betterauth-current-research.md).
