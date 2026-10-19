# howdy_auth

Optional email-token, password, provider and passkey authentication and separate role-based authorization for
Howdy. The package includes JSON endpoints, optional starter pages and headless
operations for applications supplying their own UI or transport.

This is an initial implementation, not the complete enterprise identity system.
It targets Erlang and accepts an **already-configured `gloo/repo.Repo`**, supporting
Gloo’s PostgreSQL and SQLite adapters. The application owns connection setup,
configuration and shutdown, and supplies email delivery when email tokens are enabled.
Google, Apple, GitHub, Facebook and Microsoft Entra adapters are built in. Passkeys and
optional TOTP/delivered-code MFA are described below, as are enterprise single
sign-on connections over OpenID Connect and SAML 2.0, with enforcement. SCIM,
invitations, tenant lifecycle management, a hosted management dashboard and
username login are not implemented yet.

## Passkeys and multi-factor authentication

Run auth migration **11** before starting this version, and stop old instances
for the upgrade. It adds passkey credentials, enrollment/login challenges,
encrypted factors, recovery-code digests, verification budgets and remembered
devices; existing users and sessions survive. New session methods include
`passkey` and `mfa:<primary-method>`. External stores must preserve the method
string and session version unchanged. Migration **15** adds a column that holds a
verified passkey with its registration token; run it before using passkey signup.

Enable either feature independently:

```gleam
import howdy/auth
import howdy/auth/mfa

let assert Ok(identity) = auth.with_passkeys(identity, "My application")
let assert Ok(config) = mfa.new("My application", encryption_key_from_environment)
let identity = auth.with_mfa(identity, config)
```

The MFA key must be **32 random bytes encoded as unpadded base64url**, kept
outside the auth database and shared by all application nodes. Generate it once
(for example `openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'`) and retain it
across restarts and restores. Removing MFA configuration does not bypass
enrollment: affected logins fail closed.

To rotate the key without re-enrolling anyone or failing a sign-in:

```gleam
// 1. Deploy everywhere: the new key opens secrets but seals nothing yet.
let assert Ok(config) = mfa.new("My application", old_key)
let assert Ok(config) = mfa.with_decryption_keys(config, [new_key])

// 2. Deploy everywhere: the new key seals, the old key still opens.
let assert Ok(config) = mfa.new("My application", new_key)
let assert Ok(config) = mfa.with_decryption_keys(config, [old_key])

// 3. Once, from any node: re-encrypt what the old key sealed.
let assert Ok(_resealed) = auth.reseal_mfa(identity)
```

Then deploy with `new_key` alone. `reseal_mfa` rewrites stored authenticator
secrets and enrollments in progress, returning how many it changed; it is safe
to run while serving and to rerun, returning 0 once nothing still depends on
the old key. Step 1 is only needed when nodes restart one at a time: it lets a
node still sealing with the old key read what an updated node seals. Stored
values carry no key identifier. Each configured key is tried in turn and
authenticated encryption rejects the wrong ones, so values sealed before this
release open unchanged. SSO connections rotate the same way with
`connection.with_decryption_keys` and `connections.reseal`.

The starter login/account pages include passkey enrollment, sign-in, rename and
removal, authenticator setup, delivered-code and recovery-code verification,
recovery replacement, MFA disablement and remembered-device revocation. TOTP
setup shows a QR code of the `otpauth:` URI beside the manual key. Custom UIs
get the same code as `MfaSetup.qr_code` (`qr_code` in the JSON): a
standalone SVG generated on the server, with no dependency or third-party
service. It contains the key, so show it only to the user enrolling. Enrollment
is not active until the code is verified.
Successful enrollment/recovery replacement returns ten 80-bit recovery codes
once and signs out all sessions. Save those codes before navigating away.
`mfa.with_recovery_codes(config, 16)` issues a different number, from 4 to 32.

Adding a passkey to an account, and managing passkeys, requires a recent sign-in.
The RP ID defaults to the configured public-origin hostname; exact origin, user
presence and user verification (PIN/biometric) are required. Credentials are discoverable,
with ES256, Ed25519 and RS256 support, signature counters, AAGUID, transports and
backup metadata. Challenges expire after five minutes and are single-use.
Enrollment is bound to the initiating session, user, group and session version.
Removing a passkey requires a recent login through another enabled method and
revokes all sessions. An account may have up to 20 passkeys.

To share passkeys across subdomains, name a parent domain as RP ID after
enabling passkeys:

```gleam
let assert Ok(identity) = auth.with_passkeys(identity, "Example")
let assert Ok(identity) =
  auth.with_passkey_relying_party(identity, id: "example.com", origins: [
    "https://admin.example.com",
  ])
```

The RP ID must be the hostname of the public origin and of every listed origin,
or a parent domain of them all. Browsers additionally refuse a public suffix such
as `com`. Listed origins are accepted by the passkey ceremonies alongside the
public origin; the bundled JSON routes still answer only the public origin, so
another origin needs its own deployment (configured with the same RP ID) or its
own transport. A passkey is bound to the RP ID it was created under: changing the
RP ID later strands every existing passkey, so choose it before launch.

An enrolled account must complete MFA after **every primary login method**,
including email, password, provider and passkey login. A pending MFA token cannot
access authenticated endpoints. TOTP uses RFC 6238 SHA-1, six digits and a
30-second interval with adjacent-interval tolerance and an account-wide replay
fence. Secrets use AES-256-GCM with the user ID as authenticated data. Recovery
codes are hashed and atomically consumed. Five failed code checks within five
minutes exhaust the shared account budget, even across new login challenges.

To offer delivered codes, configure `mfa.with_delivery(config, fn(user, code) {
... })` before `auth.with_mfa`. Deliver privately to an application-selected,
separately verified contact; never accept a destination from the request. This
can be the enrolled factor or a fallback for TOTP. Email-token primary logins
cannot use delivered OTP, so two codes to the same mailbox do not become two
factors. They can still use TOTP or recovery codes. Delivery failures fail closed;
sends and enrollment starts use the existing persistent cooldown policy.

Remembered devices require a successful primary login, last 30 days by default,
and are bound to the account/session version. `mfa.with_device_trust(config,
seconds: 604_800, renew: True)` sets the lifetime (five minutes to a year) and
whether each use restarts it; without renewal, trust ends that long after the
second factor was last verified. Devices already remembered keep the expiry they
were issued with until they are next renewed. Tokens are hashed at
rest; browser cookies are HttpOnly and Secure outside loopback development.
Account security changes invalidate them. Forgetting a remembered device stops
future MFA bypass on that device; separately revoke its existing sessions to
sign it out immediately. Disabling MFA or regenerating recovery codes requires
a recent, completed MFA session and revokes all sessions and remembered devices.

### Headless and HTTP contracts

Use `auth.exchange_step` and `auth.login_password_step` to receive
`SignedIn(Session)` or `SecondFactor(MfaChallenge)`. Provider completion can also
return `ProviderSecondFactor`. Old session-only exchange/password APIs return
`Forbidden` for enrolled accounts. Handle `auth.Passkey` in exhaustive matches
on `Method`. Complete a pending challenge using `auth.verify_mfa` with `Totp`,
`DeliveredCode` or `RecoveryCode`; `auth.send_mfa_code` sends a delivered code.
`auth.use_trusted_device` also requires the pending primary-login challenge.

`auth.begin_passkey_registration` / `finish_passkey_registration` and
`begin_passkey_login` / `finish_passkey_login` expose WebAuthn ceremonies.
`PasskeyChallenge.options` is the browser public-key options object; `challenge`
is an opaque Howdy token that must accompany the response. The browser must
convert base64url option fields to ArrayBuffers. Finish operations accept a JSON
string containing the standard WebAuthn credential response. Listing/management
uses `passkeys`, `rename_passkey`, `delete_passkey`. MFA management uses
`begin_mfa`, `confirm_mfa`, `mfa_status`, `disable_mfa`,
`regenerate_recovery_codes`, `trusted_devices`, `revoke_trusted_device`.

**Passkey autofill.** On the starter sign-in pages the email field carries
`autocomplete="username webauthn"`, and where the browser supports conditional
mediation the page arms a `mediation: "conditional"` request on load, so saved
passkeys appear in the field's autofill with no button press. The pending
request is replaced before its five-minute challenge lapses, and cancelled when
the "Sign in with a passkey" button starts its own. It uses the same
`/passkeys/login` and `/passkeys/session` endpoints; custom pages can do the
same with any WebAuthn client.

**Registering with a passkey.** With passkeys, registration and email tokens all
enabled (`auth.passkey_signup_enabled`), a visitor can create an account that
never has a password:

1. `auth.begin_passkey_signup(identity, email, name)` starts a signed-out
   ceremony. Nothing is excluded from it, so it reveals nothing about the address.
2. `auth.finish_passkey_signup(identity, challenge, credential, client)`
   verifies the new credential, stores it with a `Registration` token, and emails
   that token. It pays the same per-address cooldown as password registration.
3. Exchanging the token creates the account **and** its passkey together, under
   the user handle the ceremony chose, and signs in.

No account exists before its address is verified, exactly as for email and
password registration. For an address that already has an account the reply is
identical, the credential is discarded, and the email is `AlreadyRegistered`.
A credential that is already registered fails the exchange with `Conflict`.
To veto or shape sign-ups, guard these calls in your own transport as you would
the other registration routes; `allow_registration` remains the master switch.

Under the configured API prefix:

| Endpoint | Request / result |
| --- | --- |
| `GET /security` | Current MFA method and enabled features |
| `GET /passkeys` | Owned credential metadata |
| `POST /passkeys/register` | `{name}` → `{challenge, options}` |
| `POST /passkeys/register/confirm` | `{challenge, credential}` → 204; `credential` is a JSON string |
| `POST /passkeys/signup` | Signed out; `{email, name, group?}` → `{challenge, options}` |
| `POST /passkeys/signup/confirm` | Signed out; `{challenge, credential}` → 202; emails the registration token |
| `POST /passkeys/login` | `{group?}` → `{challenge, options}` |
| `POST /passkeys/session` | `{challenge, credential}` → session cookie or pending MFA |
| `POST /passkeys/rename` | `{id, name}` → 204 |
| `POST /passkeys/delete` | `{id}` → 204 and sign-out |
| `POST /mfa/enroll` | `{method: "totp" or "otp"}` → `{challenge, key, uri}` |
| `POST /mfa/enroll/confirm` | `{challenge, code}` → `{recovery_codes}` and sign-out |
| `POST /mfa/send` | `{}` with pending cookie → 204 |
| `POST /mfa/verify` | `{method, code, remember?}` with pending cookie → session cookie |
| `POST /mfa/token/send` | `{challenge}` → 204 for native clients |
| `POST /mfa/token` | `{challenge, method, code, remember?}` → `{session, trusted_device}` |
| `POST /mfa/disable` | `{}` → 204 and sign-out |
| `POST /mfa/recovery` | `{}` → replacement recovery codes and sign-out |
| `GET /mfa/devices` | Owned remembered-device IDs and expiry |
| `POST /mfa/devices/revoke` | `{id}` → 204 |

Verification methods are `totp`, `otp`, `recovery`. Browser primary-login
endpoints return **202 `{mfa_required: true}`** with a five-minute pending cookie
when needed; this is not login success. Bearer login endpoints also return
`mfa_token`, which becomes `challenge` for `/mfa/token`. Cookie verification
requires the exact Origin; all mutations retain the existing JSON, Origin and
rate-limit policies. Provider callbacks redirect pending users to `<provider
prefix>/mfa`; mount the starter pages there or provide that page in your UI.

### Scope compared with Better Auth

The everyday passkey and MFA lifecycle is implemented, including configurable
parent-domain RP IDs and additional ceremony origins, browser conditional
autofill, signup with a passkey followed by email verification, configurable
remembered-device duration/renewal and recovery-code count. This is not full
plugin parity: WebAuthn extension and authenticator-selection configuration,
custom onboarding hooks and Expo integration are not exposed. TOTP remains
six digits on a 30-second interval; OTP formats and challenge lifetimes are fixed.
Additional ceremony origins do not change the bundled HTTP routes' exact-Origin
policy; see the deployment note above.
The native verifier is pinned to **glasslock 1.0.0-rc1**, a recent prerelease,
including internal metadata parsing APIs. It has not been independently audited
as part of this work. Review upgrades explicitly; keep signed-ceremony regression
tests. See [comparison and dependency research](https://github.com/mikeyjones/howdy/blob/v2.1.1/manual/passkey-mfa-research.md)
for the official Better Auth references and inspected verifier behavior.

## Install and migrate

```sh
gleam add howdy_auth@1 howdy_database@1
```

[`howdy_database`](https://github.com/mikeyjones/howdy/blob/v2.1.1/database/README.md) provides `howdy/migration` and the
transactions auth runs on. Applications can use it for their own tables too.

Run migrations explicitly during deployment, before starting the new version:

```gleam
import howdy/auth
import howdy/authorization
import howdy/migration

pub fn migrate(db) {
  let assert Ok(_) = migration.run(db, [
    auth.schema(),
    authorization.schema(),
  ])
}
```

Authentication can be installed alone: omit `authorization.schema()` and the
`authorization` runtime if the application does not need roles.

Migrations execute through Gloo transactions with a namespaced, checksummed
ledger. Package entries contain ordinary `gloo/migration.Migration` values,
so applications can reuse Gloo's migration constructors and DDL builders.
Howdy keeps its own package ledger rather than Gloo's global version ledger to
retain package ownership, checksums and schema-drift checks. Do not apply the
same module migrations separately through `gloo/runner`.

Concurrent PostgreSQL migrators serialize using a transaction-scoped advisory
lock. SQLite operations on the same Repo serialize in Howdy, and migration
transactions acquire the write lock before inspecting history. An entire batch
rolls back on failure. Versions are positive and strictly increasing within
each package; different packages may reuse the same version number.

Each package owns the schema namespace `<package name>_`; names must be nonempty
lowercase ASCII identifiers. Auth owns `howdy_auth_*`, and authorization owns
`howdy_authz_*`. Migration SQL is trusted code and must not contain transaction
control or mutate another package's namespace. As in Gloo's runner, batches use
semicolon-separated statements: embedded semicolons in SQL literals/procedural
bodies are not supported. The package list determines dependency order: auth
precedes authz. Auth's own DDL and parameterized queries work on both adapters.

To extend a package, append a Gloo migration with a higher version. Never edit a
published migration. Startup checks both migration history and a fingerprint
of the owned schema objects. SQLite uses its schema catalog; PostgreSQL checks
relations, columns, constraints, indexes, triggers and row-security policies in
the connection's current schema. Manual schema changes are rejected at startup
and before an upgrade. Application tables referencing auth user IDs are allowed;
adding application columns, unique indexes or triggers to auth tables is not.
Small facts about a user or a group need no table of their own: see
[Timestamps and fields](#timestamps-and-fields).

A migration whose SQL depends on the database appends
`migration.per_database(postgres:, sqlite:)` to the statements both share; only
the matching variant runs. Auth uses it to keep `created_at` and `updated_at` as
`TIMESTAMPTZ` on PostgreSQL, and as unix seconds on SQLite, which has no type
for an instant.
Operators may add a plain (non-unique) index to an auth table, provided its
name is outside the package namespace, for example `ops_events_action`.

The fingerprint is built from database catalog output, which can change with
no real drift: a PostgreSQL major upgrade, or a dump and restore. When startup
reports that the schema changed outside its migrations and you have confirmed
by hand that it did not, accept the current shape from a deployment command:

```gleam
let assert Ok(_) = migration.rebaseline(db, auth.schema())
```

`rebaseline` refuses unless the recorded migration history exactly matches the
installed package, so it cannot hide missing or edited migrations. Never call
it at application startup.

Applications can join the same deployment transaction with their own package:

```gleam
import gloo/migration as gloo_migration

migration.run(db, [
  auth.schema(),
  authorization.schema(),
  migration.Package("app", [
    gloo_migration.new(1, "create_profiles", "CREATE TABLE app_profiles (
       user_id TEXT PRIMARY KEY REFERENCES howdy_auth_users(id),
       display_name TEXT NOT NULL
     )"),
  ]),
])
```

Back up the database before deployment. There are no down migrations, automatic
rollbacks across application versions, or rolling-upgrade compatibility guarantees
in this release. Stop old instances before migrating. Startup schema checks do
not continuously police changes made by another database writer; database access
belongs to trusted application/deployment code.

## Configure and mount

```gleam
import howdy
import howdy/auth
import howdy/auth/pages
import howdy/auth/routes
import howdy/auth/user
import howdy/controller

pub fn app(db, send_email) {
  let assert Ok(identity) = auth.new(
    repo: db,
    origin: "https://app.example.com",
    deliver: send_email,
  )
  let identity = auth.allow_registration(identity)
  // Optional: add email/password login alongside email tokens.
  let assert Ok(identity) = auth.with_passwords(identity)

  let account =
    controller.guarded("/account", auth.required(identity))
    |> controller.get("/me", fn(ctx) {
      controller.json(ctx, user.to_json(ctx.guard.user))
    })
    |> controller.build()

  howdy.new()
  |> howdy.controller(routes.api(identity, at: "/api/auth"))
  |> howdy.controller(pages.routes(
    identity, at: "/auth", api_at: "/api/auth",
  ))
  |> howdy.controller(account)
}
```

`send_email` has type `fn(auth.Delivery) -> Result(Nil, Nil)`. Send
`secret.reveal(delivery.token)` privately (import `howdy/auth/secret`) to `delivery.email`, with an instruction to paste it
into the sign-in/registration page. `delivery.purpose` says which email to
write: `SignIn`, `Registration`, or `AlreadyRegistered` when someone asked to
register an address that already has an account. That last one carries a
sign-in token and keeps no password from the request, so tell the reader they
already have an account rather than inviting them to make another. The reply to
whoever asked is the same in every case, so this tells only the inbox owner
anything. It is a 256-bit random, single-use token with
a ten-minute lifetime. Tokens are exchanged only through POST, never GET links.
Do not log tokens, place them in URLs, or include them in analytics. A delivery
error invalidates the challenge. An exchange spends the token even when it then
fails (user suspended, method disabled). Registration is disabled until explicitly
enabled and creates the user only after email verification.

### Ready-made emails

`howdy/auth/emails` writes these emails for you with
[`howdy_mail`](https://github.com/mikeyjones/howdy/blob/v2.1.1/mail/README.md), one for each purpose and one for MFA codes:

```gleam
import howdy/auth/emails
import howdy/mail
import howdy/mail/smtp

let assert Ok(smtp_config) = smtp.from_env()
let mailer =
  mail.mailer(smtp.adapter(smtp_config))
  |> mail.default_from(mail.named("Acme", "hello@acme.test"))
let auth_emails = emails.new(mailer, app_name: "Acme")

let assert Ok(identity) =
  auth.new(repo: db, origin:, deliver: emails.deliver(auth_emails))
let mfa_config = mfa.with_delivery(mfa_config, emails.deliver_mfa(auth_emails))
```

Each message goes to `delivery.email`, tagged `auth.<purpose>` (such as
`auth.sign_in`), with the link, code or token the delivery carries, and a
plain-text part with the link on a line of its own. Replace one with
`emails.with_template(auth_emails, for: auth.SignIn, build: fn(delivery) {
...})`, which sets the subject and body; the recipient and tag are added.
A failed send is logged without the token, and the flow reports the
failure as it would for your own `deliver`. `emails.previews(auth_emails)`
gives the admin a preview of every email, and `emails.previews_in(auth_emails,
["de", "ja"])` the same in other locales.

### Locales

The starter pages and the ready-made emails are translated into en, ar, de,
es, fr, it, ja, nl, pl, pt and zh. Every translation but English is machine
written and waiting for review by a native speaker. Say which locales to
offer, and how to choose one for a request, with a `howdy/locale` negotiator:

```gleam
let locales =
  locale.negotiator(["en", "de", "fr"], default: "en")
  |> locale.from(auth.locale_source(identity))
  |> locale.from_cookie("locale")
  |> locale.from_accept_language
let identity = auth.with_locales(identity, locales)
```

Pages set `lang` and `dir` for the chosen locale. A new account remembers the
locale it registered in (`user.locale`, a nullable column added by migration
19), and its emails use that from then on; `Delivery.locale` carries it to a
`deliver` of your own. With more than one locale, the account page lets the
user choose, through `POST /locale`; `auth.locale_source` reads the choice
back for the negotiator. The words live in `locales/pages` and
`locales/emails`; see `howdy/auth/pages` for how to regenerate them after an
edit.

Every JSON error carries a stable `code` beside its English `error`, so a
client of your own can show its own words: a failure a person can fix has a
code of its own, such as `password_incorrect`, `password_length`,
`email_taken` or `passkey_limit`, and anything else has the code of its
kind, such as `unauthorized`. The headless functions return the same codes
as `service.Coded` errors; match on `service.uncoded(error)` to see the kind
of error inside.

### Links and codes in the email

Pasting a 43-character token is the fallback, not the experience to aim for.
Two options put something easier in the same email:

```gleam
let assert Ok(identity) = auth.with_email_links(identity, at: "/auth")
let identity = auth.with_email_codes(identity)
```

`delivery.link` is then a URL to the starter pages mounted at that path, such
as `https://example.com/auth/login#token=…`. The token rides in the URL
fragment, which browsers never send to a server, so it stays out of access logs
and `Referer` headers. The page fills it in and waits for the reader to press
Continue: security scanners that open every link in an email spend nothing,
and nobody is signed in to an account by a link they did not choose to use.
Email-change links open `/account` with `#email-confirm=` or `#email-approve=`.
Notices get no link. Custom pages at the same path can read the same fragments.

`delivery.code` is a six-digit code for `SignIn`, `Registration` and
`AlreadyRegistered` emails. It is typed with the address it was sent to, into
the same field as the token on the starter pages, or sent as
`{"email", "code"}` to `/session` or `/token` (`auth.exchange_code_step`
headlessly). A code and its token are one credential: using either spends both.
Three wrong guesses retire the code; the token still works. Every guess also
counts against the address and client limits that password guesses use, so
codes add almost nothing to what an attacker can try. The trade-off is at rest:
anyone who can read the auth database can recover a live code by trying all
million against its keyed digest. A token's digest cannot be reversed that way.
Migration **16** adds the two columns codes use; run it before this version.

A token request that finds a usable token already waiting for that address
sends no second email and still reports success: one is already in that inbox.
This is what stops a third party both flooding an inbox and locking its owner
out, because every request leaves the owner holding exactly one live token and
no request is ever refused. `policy.email_coalesce_margin_seconds` sets how
much life a token must have left to count; raising it sends more email and
allows a sooner resend, and setting it to `challenge_seconds` disables
coalescing entirely. Registration with a password cannot be answered from the
inbox, so that path keeps a per-address cooldown instead.

`auth.request_token_from` and `auth.register_password_from` take the requesting
client for throttling and audit; the shorter names share one headless bucket.

Email addresses are trimmed and lowercased as this version's explicit account
identifier policy. Email ownership is the recovery mechanism: a fresh
email-token session is what authorizes setting or resetting a password.

The runtime checks a fixed public origin rather than trusting Host/forwarded
headers. HTTPS is required except for loopback development origins such as
`http://localhost:8787`. Secure cookies use the `__Host-` prefix, HttpOnly,
SameSite=Lax and Path=/; development HTTP uses a different cookie name.
Sessions expire after 24 hours by default. They can additionally expire when
idle, or renew while in use up to an optional ceiling; see [Policy](#policy).

Construct the runtime and routes once in a long-lived startup process. HTTP
route limiters are owned by that process. Auth never opens, configures or closes
the supplied Repo. Pass the same Repo to `auth.new`, `authorization.new`, and
`migration.run`:

```gleam
let assert Ok(identity) = auth.new(
  repo: db, origin: "https://app.example.com", deliver: send_email,
)
let assert Ok(permissions) = authorization.new(db)
```

PostgreSQL can use the application's existing pooled Repo;
`howdy/database/postgres` from `howdy_database` opens one from `DATABASE_URL`
with TLS, UTC and session timeouts. SQLite can use either an in-memory Repo or
a file-backed one. Configure foreign keys and a suitable busy timeout in the
application, just as the Howdy template does; `database.sqlite_defaults(db)`
sets both.

**SQLite connection sharing:** Gloo 1.x exposes one connection per SQLite Repo.
Howdy serializes its own operations on that Repo, first come first served, but cannot serialize unrelated
application calls made directly through Gloo. Application code that goes
through `howdy/database` shares auth's lock and can safely share its Repo. If
the application also performs concurrent database operations directly through
Gloo, supply a dedicated configured SQLite Repo for auth, pointing at the same
database file. Pass that same auth Repo to both auth and authorization. PostgreSQL's pool reserves transaction connections, so this
restriction does not apply there. Do not invoke auth operations inside a
caller-managed transaction; auth owns its operation transactions.

This is a pre-release schema revision of the earlier direct-SQLite prototype.
Existing prototype migration checksums will be rejected rather than silently
rewritten. Use a fresh development database or an explicit data migration if you
need to preserve prototype records; do not delete the ledger to bypass checks.

## Policy

Lifetimes and limits live in one record, `howdy/auth/policy.Policy`. Start from
the defaults and change what you need, once, at startup:

```gleam
import howdy/auth/policy

let assert Ok(identity) = auth.with_policy(
  identity,
  policy.Policy(
    ..policy.default(),
    session_seconds: 3600,
    session_idle_seconds: 900,
  ),
)
```

To keep returning users signed in, renew sessions while they are in use:

```gleam
policy.Policy(
  ..policy.default(),
  session_seconds: 604_800,        // a week
  session_renew_seconds: 86_400,   // extended at most once a day
  session_max_seconds: 7_776_000,  // never beyond 90 days
)
```

Anyone who comes back within a week stays signed in; anyone away longer signs in
again. Renewal happens when an authenticated request finds the expiry at least
`session_renew_seconds` old, during the once-a-minute last-use update, so it adds
no writes. An expired session is never revived, and revocation, suspension and
the idle timeout apply as before. Set a ceiling unless sessions really should be
able to live forever. The session cookie then lasts until the ceiling (or the
400 days browsers allow) rather than being re-issued on each renewal: it only
carries the token, and the server alone decides when the session ends, so
renewal works on every route of the application. `expires_in` from the token
endpoints is the initial expiry; `GET /sessions` reports the current one.
Lowering these values later does not shorten sessions already issued.

| Field | Default | Meaning |
| --- | --- | --- |
| `session_seconds` | 86 400 | Session lifetime: absolute unless renewal extends it |
| `session_renew_seconds` | 0 (off) | Sliding renewal: a session used at least this long after its expiry was last set expires `session_seconds` from now; from 60 to below `session_seconds` |
| `session_max_seconds` | 0 (none) | Ceiling on a renewed session, from its creation; at least `session_seconds` when set |
| `session_idle_seconds` | 0 (off) | Reject sessions unused this long; at least 300 when set |
| `email_coalesce_margin_seconds` | 300 | Life a live token must have left for a request to be answered by it rather than by sending another |
| `fresh_session_seconds` | 600 | Age limit of the email-token session that may set a password |
| `challenge_seconds` | 600 | Emailed token lifetime |
| `live_challenges` | 3 | Unexpired tokens kept per address; `1` makes each request replace the last |
| `email_cooldown_seconds` | 60 | Wait after the first email; doubles per further request |
| `email_cooldown_max_seconds` | 3 600 | Ceiling for that doubling |
| `email_quiet_seconds` | 900 | Doubling starts over after this long undisturbed |
| `password_attempts` | 5 | Initial guesses per client/address before back-off |
| `password_account_attempts` | 100 | Higher shared per-address ceiling per window |
| `password_backoff_max_seconds` | 3600 | Maximum client/address back-off |
| `password_quiet_seconds` | 86400 | Quiet time before client/address failure history expires |
| `password_window_seconds` | 60 | Shared-address window and initial client back-off |
| `password_min_length` | 15 | Minimum new password length in code points; at least 8 |

`with_policy` rejects nonsensical values. Last use of a session is recorded at
most once a minute, so authenticating a request is normally a single read.

## Facebook, GitHub and Microsoft Entra

Install these with `auth.with_provider`, using the same provider routes as Google:

```gleam
import howdy/auth/providers/facebook
import howdy/auth/providers/github
import howdy/auth/providers/entra

facebook.new(client_id: facebook_app_id, client_secret: facebook_app_secret)
github.new(client_id: github_client_id, client_secret: github_client_secret)
entra.new(
  client_id: entra_client_id,
  client_secret: entra_client_secret,
  tenant: "organizations",
)
```

Register the corresponding callback URL with each provider:
`https://app.example.com/auth/providers/facebook/callback`,
`https://app.example.com/auth/providers/github/callback`, or
`https://app.example.com/auth/providers/entra/callback`.
These assume the provider controller is mounted under `/auth`.

Entra accepts a directory tenant ID, a tenant domain such as
`example.onmicrosoft.com`, or `common`, `organizations`, or `consumers`.
The app registration must allow the account types selected by that tenant.
The provider validates the token's signature, signing-key issuer, tenant,
audience, lifetime and nonce, and identifies accounts by the actual issuer
and subject. GitHub uses PKCE and obtains verified email addresses from
`/user/emails`, preferring the primary address.

Facebook and Entra email claims are not treated as proof of mailbox ownership.
Users first create/verify a local account through the email flow, sign in,
and explicitly link the provider. Subsequent provider sign-ins work even when
no email is returned. GitHub can register a new local account when it supplies
a verified email and local registration is enabled; existing local accounts
must explicitly link. Provider access and refresh tokens are not stored.

## Sign in with Apple

```gleam
import howdy/auth/providers/apple

let assert Ok(identity) =
  auth.with_provider(
    identity,
    apple.new(
      client_id: "com.example.web",      // the Services ID, not a bundle ID
      team_id: "ABCDE12345",
      key_id: "KEY1234567",
      private_key: apple_p8_contents,     // the PEM text of the .p8 download
    ),
  )
```

In the Apple developer console, create a Services ID with Sign in with Apple
enabled, add your domain, and register the return URL
`https://app.example.com/auth/providers/apple/callback` (Apple requires HTTPS
and rejects `localhost`, so test against a real or tunnelled domain). Create a
key with Sign in with Apple enabled and keep its `.p8` with your other secrets.

Apple has no shared client secret: each token request is authenticated by a
five-minute ES256 JWT signed with that key, generated per exchange and never
stored. `with_provider` signs once at startup, so an unusable key is an error
there rather than at the first sign-in. The provider then verifies the
`id_token`'s RS256 signature against Apple's published keys, and its issuer,
audience, lifetime and nonce. Apple documents no PKCE support, so none is sent.

Requesting the email scope makes Apple answer with a **cross-site POST**
(`response_mode=form_post`), on which browsers withhold SameSite=Lax cookies:
neither the attempt's binding cookie nor a session to link would arrive. The
provider routes therefore accept `POST …/providers/<id>/callback` only to
redirect (303) to the same callback as a GET carrying `state` and `code`, where
the attempt is judged exactly as for every other provider. That POST decides
nothing and sets nothing. If the application adds its own CSRF or Origin
middleware in front of these routes, exempt that one path.

Apple verifies every address it releases, including `privaterelay.appleid.com`
relay addresses, so a verified email can register a new local account when
registration is enabled; existing local accounts must explicitly link, as with
GitHub. Mail to a relay address is delivered only from sender domains registered
with Apple, so register yours or token and notice emails will not arrive. A user
may share no address at all; such an identity can sign in only to an account it
is already linked to. Apple sends the user's name once, in the POST, and it is
discarded: this package stores no names.

## Enterprise single sign-on

A **connection** is one customer's identity provider: Okta, Entra, Google
Workspace, anything speaking OpenID Connect or SAML 2.0. Unlike the built-in
providers, connections are data. They are created while the server runs, stored
in the auth database, and bound to the group their users sign in to.

```gleam
import howdy/auth/connection
import howdy/auth/connections

// A stable, 32-byte base64url key kept outside the database. Client secrets
// are sealed with it at rest. It may be the MFA key, and rotates the same way:
// `connection.with_decryption_keys`, then `connections.reseal`.
let assert Ok(sso) = connection.config(sso_encryption_key)
let identity = auth.with_sso(identity, sso)

let assert Ok(acme) =
  connections.create_with_id(
    identity,
    id: "acme",
    group: "acme",
    name: "Acme",
    protocol: connection.oidc(
      issuer: "https://acme.okta.com",
      client_id: okta_client_id,
      client_secret: okta_client_secret,
    ),
    domains: ["acme.com"],
    by: user.Acting(admin),
  )
```

For SAML, pass what the customer's administrator hands over:

```gleam
connection.Saml(
  entity_id: "http://www.okta.com/exk1abc",
  sso_url: "https://acme.okta.com/app/acme/exk1abc/sso/saml",
  certificates: [signing_certificate_pem],
)
```

`howdy/auth/connections` is privileged and is not exposed over HTTP: authorize
the caller first, as with `howdy/auth/groups`. It also offers `get`, `list`,
`in_group`, `rename`, `set_protocol`, `set_domains`, `enable`, `disable`,
`enforce`, `trust_provider_mfa` and `delete`. Every change is audited (`sso.created`, `sso.protocol_changed`, …).
Under `Single` a connection's group is `group.default_id`.

Mount the browser routes once. Connections created later are served without
remounting:

```gleam
routes.sso(identity, at: "/auth", success_path: "/account", failure_path: "/login")
```

| Route | Purpose |
| --- | --- |
| `POST /auth/sso/login` | Form field `email`; the domain picks the connection. |
| `POST /auth/sso/:connection/login` | Begin at a known connection. |
| `POST /auth/sso/:connection/link` | Link the signed-in user; needs a fresh session. |
| `GET /auth/sso/:connection/callback` | OpenID Connect redirect URI. |
| `POST /auth/sso/:connection/callback` | SAML assertion consumer service. |
| `GET /auth/sso/:connection/metadata` | SAML service provider metadata. |

A connection therefore has **one URL** to give the customer,
`auth.origin(identity) <> "/auth/sso/acme/callback"`. It is the OIDC redirect
URI, and for SAML it is both the ACS URL and the SP entity ID (audience). Ask
SAML customers for a persistent NameID and an email attribute; an address used
as the NameID also serves.

### What a connection is believed about

The identity provider belongs to the customer, not to a party Howdy can pin, so
it may assert anything. Three rules contain that:

- **Domains.** An asserted address is believed only inside the connection's
  own `domains`, and a domain belongs to at most one connection. Confirm the
  customer controls a domain before adding it: Howdy does not.
- **Group.** A connection's users only ever sign in to, or are created in, its
  own group. An attempt begun at one connection cannot finish at another.
- **Identities are keyed by the connection**, not by the name the provider
  gives itself, so one customer's provider cannot assert its way into
  another's identities. Deleting a connection, or pointing it at a different
  provider with `set_protocol`, forgets them; rotating a secret or a
  certificate does not.

Inside those rules the connection is the authority on who holds an address:
the customer's administrator can read that mailbox anyway. So a first sign-in
whose address is inside the connection's domains

- **takes up the existing account** with that address in the connection's
  group, recording `provider.linked` with no actor, or
- **creates the account**, whether or not `allow_registration` is on: creating
  the connection is what let those users in.

Nobody links beforehand, and a customer can move to another provider without
locking anyone out. Once taken up, an account answers to that one subject; a
second person asserting the same address is refused. A suspended account is
not revived, and an account with that address in *another* group is never
touched. An address outside the domains, such as a contractor's, is believed
about nothing: that user signs in another way and links deliberately from a
fresh session (`POST …/sso/:connection/link`), as for the built-in providers.

Sessions record the method as `Provider("sso:" <> connection.id)`. Disabling
or deleting a connection stops new sign-ins through it, and its live sessions
stop counting as fresh authentication for sensitive operations, but they are
not ended: call `auth.revoke_sessions` when offboarding a customer.

### Second factors

By default the provider is the first factor and Howdy's own, where the user
has one, is still asked for afterwards. A customer whose provider already
demands MFA can be spared the second prompt, per connection:

```gleam
connections.trust_provider_mfa(identity, "acme", by: user.Acting(admin))
connections.require_local_mfa(identity, "acme", by: user.Acting(admin))
```

This is **trust, not verification**. Providers report how a user authenticated
too inconsistently to check (`amr`, SAML authentication contexts and vendor
claims all differ), so Howdy takes the customer's word about their policy.
Weigh it with auto-linking: the provider's administrator can then reach an
account in the connection's domains and group that has a Howdy factor, without
that factor. Every sign-in that skips a factor the user has is audited as
`mfa.provider_trusted`.

A session issued this way has not proven the Howdy factor, so it cannot
disable it or regenerate recovery codes; a session that did prove it still
can. Trust applies to that connection only: email tokens, passwords, passkeys
and other providers keep asking.

### Enforcement

```gleam
connections.enforce(identity, "acme", by: user.Acting(admin))
connections.stop_enforcing(identity, "acme", by: user.Acting(admin))
```

An enforced connection is the only way in for the members it **covers**: those
of its group whose address is in one of its domains. For them email tokens,
passwords, passkeys and the built-in providers are all refused, at the one
place every sign-in ends, so a custom transport cannot route around it.
Members outside the domains, such as guests, keep their ordinary sign-in.

- Refusals are `Unauthorized`, exactly as for a wrong credential, so a correct
  password is not confirmed to an account that may not use it. Send users to
  the right place first: `auth.sso_for_email`, or `POST …/sso/login`.
- Tokens that could never be redeemed are not emailed, to covered members or
  to new addresses that would be covered. The reply to the caller is unchanged.
  A token sent before enforcement began is refused when exchanged.
- `enforce` **signs covered members out**, in the database and in an external
  session store, so their next sign-in is the provider's. Adding a domain to an
  enforced connection does the same for those it newly covers.
- Local MFA still runs after the provider, unless the connection trusts the
  provider's; see above.
- Enforcement needs at least one domain, lapses while the connection is
  disabled, and is decided from the database alone: a deployment that drops
  `with_sso` keeps enforcing, and its covered members cannot sign in until it
  is restored. If a customer's provider breaks, `stop_enforcing` is the way
  back in, so keep an operator account outside every enforced domain.

### Protocol limits

OpenID Connect: authorization code flow with PKCE, state and nonce; discovery
at the configured issuer only, which the document must name; RS256 ID tokens;
`client_secret_post` or `client_secret_basic` as the provider advertises.

SAML: SP-initiated only, HTTP-Redirect out and HTTP-POST back, RSA signatures
with SHA-256 or better over exclusive canonical XML. The response or its
assertion must be signed by a **pinned** certificate (a certificate inside the
document is ignored), and every signature present must verify. Claims are read
only from the single assertion the signature covers; documents with a DTD, an
encrypted assertion or more than one assertion are refused. Unsupported:
IdP-initiated sign-in, signed AuthnRequests, encrypted assertions, single
logout, ECDSA. Canonicalisation is esaml's `xmerl_c14n`, vendored as
`howdy_auth_c14n` under its BSD licence; signature verification is Howdy's own
and has not been independently audited.

Requests to a customer's OIDC endpoints are HTTPS only, follow no redirects
and refuse hosts that resolve to loopback, private or link-local addresses.
That is a filter, not a pinned connection, which is one reason connection
management stays a privileged, operator-side API.

The SAML browser binding sets a second, `SameSite=None; Secure` cookie, since
the provider posts back from its own site. Browsers accept it on loopback
HTTP during development.

## Google and built-in providers

Google sign-in uses the same users, sessions, groups, suspension rules and guards
as email/password authentication. Register an OAuth **Web application** client in
Google Cloud and configure its branding/consent screen. This integration uses the
server authorization-code flow, requests only `openid email`, and needs Erlang/OTP
27 or newer. It does not request offline access or store Google access/refresh tokens.

```gleam
import howdy/auth/providers/google

let assert Ok(identity) = auth.with_provider(
  identity,
  google.new(client_id: google_client_id, client_secret: google_client_secret),
)
let identity = auth.allow_registration(identity)

howdy.new()
|> howdy.controller(routes.api(identity, at: "/api/auth"))
|> howdy.controller(routes.providers(
  identity,
  at: "/auth",
  success_path: "/auth/account",
  failure_path: "/auth/login",
))
|> howdy.controller(pages.routes(identity, at: "/auth", api_at: "/api/auth"))
```

Load credentials from your application's secret configuration. Register the exact
callback `https://app.example.com/auth/providers/google/callback` in Google Cloud,
substituting your configured public origin and mount prefix. Local development can
use `http://localhost:8787/auth/providers/google/callback`. Callback URLs are derived
from the configured origin, never Host or forwarded headers. Mount the provider
controller at the same prefix as the starter pages; their Google buttons and account
link forms appear automatically. `auth.providers(identity)` lists IDs/display names
for custom pages. `auth.with_provider` validates each provider and rejects a
duplicate ID or issuer. For providers beyond the built-in ones, see
[Other OpenID Connect and OAuth providers](#other-openid-connect-and-oauth-providers).

For a Google-only installation, replace `auth.new` with:

```gleam
let assert Ok(identity) = auth.new_without_email(repo: db, origin: origin)
```

Add Google as above. Email-token requests and exchanges are disabled; the starter
pages hide email forms. Existing `auth.new(repo:, origin:, deliver:)` callers keep
their behaviour. `auth.with_email_tokens(identity, deliver: send_email)` enables
email tokens later. Enabling a provider does not enable public registration.

| Provider route (under `/auth`) | Behaviour |
| --- | --- |
| `POST /providers/google/login` | Begin login or, if enabled, registration |
| `GET /providers/google/callback` | Validate the response, set a local session cookie, redirect |
| `POST /providers/google/link` | Begin linking to the currently authenticated account |

Start routes require an exact Origin; plain HTML POST forms work. Callbacks use
single-use state, a separate HttpOnly SameSite=Lax browser cookie, nonce and PKCE
S256. Attempts expire after ten minutes and are spent before contacting Google,
including on cancellation or downstream failure. The latest start for a provider
in a browser replaces its binding cookie; finish that attempt or start again.
Success and failure destinations are fixed local paths (letters, numbers, slash,
hyphen and underscore), not request-controlled return URLs. Callback failures
redirect to `failure_path` without exposing Google's response or account existence.
Both routes and responses disable caching and referrers. Redact callback query
strings in any application/ingress logging; they contain Google's one-use code.

The default provider-route limit is 30 requests/minute per socket address. Behind
a trusted proxy, use `routes.providers_limited_by(..., key:)`, following the same
trusted-key rules as `routes.api_limited_by`. Each outgoing Google request has a
ten-second timeout and verifies TLS; HTTP redirects are not followed. Signing keys
are cached according to Cache-Control/Age, for at most one hour, and refreshed once
on a signature/key mismatch. Identity and session decisions are never cached here.

Account rules:

- An existing `(issuer, subject)` link signs into its local account even if Google's
  email changes. It never silently changes the local recovery email.
- A new identity creates an account only with registration enabled and an email
  Google authoritatively verifies: Gmail or a verified Workspace hosted domain.
- An existing local email never links automatically. Sign into that account, then
  use the account page's **Link Google** form. The session must have been created
  within `policy.fresh_session_seconds`; the same live session must finish linking.
- A Google account using another email provider first registers/verifies through
  Howdy's email flow, then explicitly links. Google-only self-registration for
  those third-party email addresses is refused. A verified Google assertion alone
  does not establish current ownership of that external mailbox.
- Each local user can link one identity per issuer. Linking another subject or an
  identity already held by another account fails; it never replaces an existing link.

To restrict sign-ins to Google Workspace, pipe the constructor through
`google.require_hosted_domain("example.com")`. This checks the signed `hd` claim,
not just the account chooser's domain hint or the email suffix. Domains must use
lowercase ASCII spelling. Local roles and permissions remain application-managed.

Under `AccountPerGroup`, the same external subject may have distinct local accounts
in different groups. Pass `?group=GROUP_ID` to the login start route, or mount with
`auth.in_group`; the selected group is stored with the attempt. Under
`OneGroupPerUser`, new registrations also need a selected group, while existing
links can sign in without one. Link attempts always capture the user's group.
Moving a user moves their provider links and invalidates pending attempts; group
mode conversion refuses ambiguous identities and updates the scopes transactionally.

Provider sessions appear as `auth.Provider("google")` or `"provider:google"` in the
JSON session list. They do **not** satisfy the fresh email-token proof required to
set/reset a password. External session stores follow the same commit/publish and
revocation limitations as the existing login flows. Local logout ends the Howdy
session; it does not sign the browser out of Google.

Headless/custom browser transports can use `auth.begin_provider`,
`auth.begin_provider_link` and `auth.finish_provider`. They must carry the secret
browser token in a protected cookie, enforce Origin and rate limits on starts,
and pass the same authenticated principal on a linking callback. The finish result
is `ProviderSession(Session)` or `ProviderLinked`. Do not expose the internal
provider verification/transport seam as a remotely callable operation.

Migration 9 adds provider attempts and identity links and permits provider session
methods, preserving existing users and sessions. Run `migration.run` before deploying
and stop old instances during this upgrade, as with the package's other migrations.
On SQLite the old constrained method column is retained as `legacy_method` to avoid
rebuilding the session table; application-created indexes targeting the old method
column follow that name and should be replaced if they need to index new methods.

References: [Google's server flow](https://developers.google.com/identity/openid-connect/openid-connect),
[Google identity/email verification](https://developers.google.com/identity/sign-in/web/backend-auth).

## Other OpenID Connect and OAuth providers

Any OpenID Connect provider (Okta, Auth0, Keycloak, GitLab, Zitadel…) needs only
configuration:

```gleam
import howdy/auth/providers/oidc

let assert Ok(identity) =
  auth.with_provider(identity, oidc.new(
    id: "gitlab",
    name: "GitLab",
    issuer: "https://gitlab.com",
    client_id: gitlab_client_id,
    client_secret: gitlab_client_secret,
    authoritative_for: [],
  ))
```

Endpoints and keys are discovered at `issuer` when the first sign-in begins and
cached for five minutes, so an unreachable provider fails that sign-in, not
startup. ID tokens get the same checks as enterprise SSO connections: signature
against the issuer's own keys, then issuer, audience, lifetime and nonce.
Register `https://app.example.com/auth/providers/<id>/callback`.

`authoritative_for` is the security decision. A provider sign-in creates a new
account only when the provider is the authority for the address: for a
company's own domain on its own Keycloak, list that domain. For a public
provider where anyone can make an account, pass `[]`; new users then register
by email and link the provider from the account page. A provider that has
verified an address is not its owner. Howdy never attaches a provider sign-in to
an existing account because the addresses match, whatever this says.

For an OAuth 2.0 provider without OpenID Connect, `provider.custom` takes the
two provider-specific steps and leaves state, PKCE, nonce, cookies, linking,
MFA and sessions to Howdy:

```gleam
import howdy/auth/provider

let assert Ok(identity) =
  auth.with_provider(identity, provider.custom(
    id: "gitea",
    name: "Gitea",
    issuer: "https://git.example.com",
    authorize: fn(request) {
      "https://git.example.com/login/oauth/authorize?" <> uri.query_to_string([
        #("client_id", client_id),
        #("redirect_uri", request.redirect_uri),
        #("response_type", "code"),
        #("state", request.state),
        #("code_challenge", request.challenge),
        #("code_challenge_method", "S256"),
      ])
    },
    // Redeem exchange.code (with exchange.redirect_uri and exchange.verifier),
    // fetch the user, and return
    // Ok(provider.Verified(subject: id, email:, email_authoritative: False)).
    verify: gitea_account,
  ))
```

`subject` must be the provider's stable account ID, never an address.
`email_authoritative` follows the same rule as `authoritative_for` above; leave
it False when unsure. A custom provider's accounts are recorded under
`custom:<issuer>`, so even a provider claiming Google's issuer cannot reach an
account linked through Google or an SSO connection. Changing `issuer` later
forgets its linked accounts. `verify` should bound the responses it reads,
never log them, and return `Error(service.Unauthorized)` for anything it
refuses; any provider access token is yours to discard.

## Optional passwords

`auth.with_passwords(identity)` enables email/password authentication. Without
it, password operations are forbidden and password pages are absent. Email-token
login remains available to password users; these are alternative methods, not
MFA. Passwords are never trimmed. New passwords are normalized to Unicode NFC
before checking and hashing, so canonically equivalent input works across keyboards.
Both original and normalized input must fit the length limits. New passwords need at least
15 Unicode code points (`policy.password_min_length`) and at most 1024 UTF-8 bytes.

`auth.register_password(identity, email, password)` sends an email verification
token. Only `auth.exchange(identity, token)` creates the account and installs its
password hash. Re-registering an existing email never replaces its password or
attaches a password to an email-only account. `auth.login_password(identity,
email, password)` returns the same session type as email-token exchange.

`auth.set_password(identity, principal, password)` sets, replaces or resets the
caller's password. One operation covers all three because the proof is the
same: the session must have been created by an **email-token exchange within
the last ten minutes** (`policy.fresh_session_seconds`). A password session, or
an older one, receives `Forbidden`. So to change or recover a password, or to
add one to an email-only account: request a login token, exchange it, then set
the password. Every other session of that user is revoked. Over HTTP this is
`POST /password`.

A user who knows the current password needs no email round trip:
`auth.change_password(identity, principal, current:, new:)` (over HTTP,
`POST /password/change` with `{"current":"…","password":"…"}`) replaces it from
any live session, and also serves deployments without email tokens. A wrong
current password is `Invalid` (HTTP 400), not `Unauthorized`: the session is
still good. Guesses spend the same per-client and per-address budget as password
logins, so a borrowed session cannot search for the password faster than the
login form allows; custom transports pass their client identity to
`auth.change_password_from`. An account without a password receives `Forbidden`
and uses `set_password` instead. Every other session and remembered device is
revoked, and the address receives a best-effort notice: handle the
`Delivery.purpose` variant `PasswordChanged`, whose `token` is empty, by telling
the reader to sign in by email and reset the password if the change was not
theirs. A failed notice does not undo the change.

A built-in common-password list rejects obvious compromised
choices (including the widely published “correct horse battery staple” example).
For a production breach corpus, configure `auth.with_password_check(identity,
check)` at startup. The callback receives the normalized **new** password and
returns `Ok(Nil)` or a service error; errors fail closed. Use a local corpus or
a privacy-preserving lookup, never plaintext remote queries or logging.
The built-in list and common-pattern checks are not a complete breach database.
To use a local corpus without writing your own callback:

```gleam
import howdy/auth/password_check

let identity = auth.with_password_check(identity, password_check.blocklist(corpus))
```

Build this once at startup. The checker holds normalized SHA-256 digests,
compares case-sensitively without trimming, and sends no password over the
network. Load an appropriate maintained corpus in the application.

Successful login upgrades hashes with older, lower costs and pre-normalization hashes.
Migration 5 adds normalization metadata to credentials and pending registration
challenges. Existing rows start unknown, preserving normalized-first/exact-input
fallback. A successful login marks or rehashes them as NFC. New credentials and
dummy hashes use exactly one verification even for wrong decomposed Unicode
input. Unknown legacy hashes may still require two checks until successful login
or password reset; no forced password reset is required. Rehashing is
outside the transaction; the old credential is rechecked under the user lock
before replacement. Upgrades preserve higher existing costs and output lengths.
Existing passwords are not rejected by a newly configured breach checker during
login; apply that checker when setting or resetting credentials.

New passwords are screened for shapes a length minimum does not catch: a common
word however it is decorated, one unit repeated, a keyboard run, or very few
distinct characters. That is a shape check, not a breach corpus; supply one with
`auth.with_password_check` and `howdy/auth/password_check.blocklist`.

Passwords use PBKDF2-HMAC-SHA256 from OTP's `crypto`, with 600,000 iterations,
a fresh random 16-byte salt and a 32-byte hash, stored in PHC string format
(`$pbkdf2-sha256$i=600000,l=32$...`). No native code is built. PBKDF2 is not
memory-hard, so a leaked database is cheaper to attack on GPUs than an Argon2id
one; the 15 character minimum and the common-password check offset that. To use
another algorithm, implement `howdy/auth/password_hasher.PasswordHasher` and
enable passwords with `auth.with_password_hasher(identity, hasher)` instead of
`auth.with_passwords`. Existing credentials must be readable by that hasher.

Only the encoded salted hash is stored, including while email verification is
pending. Hashing happens outside database transactions. Missing, email-only
and suspended accounts perform a dummy hash verification and return the same
unauthorized result as a wrong password. `auth.login_password_from(identity, email, password, client)` uses a
persistent budget per normalized address and trusted client key. Five attempts
are initially allowed; subsequent failures require a 60-second wait that doubles
to one hour. Rejected attempts do not prolong the wait. A successful login clears
that pair's history, without clearing another client's failures. A higher shared
100/minute address ceiling limits attacks that rotate clients. All these limits
are policy fields. Resetting a password clears the address's client histories.
The compatibility `login_password` API uses one shared `headless` client key;
custom transports should use `login_password_from`. HTTP routes use the same
trusted key as `api_limited_by`; unknown clients share a fallback bucket.
Failed password attempts on real accounts record `login.failed` events.
Custom transports must also enforce client and overall load limits.

This protects stored passwords with one-way hashing. It does not encrypt user
emails, audit records, the database or backups. Those need separate storage
and key-management controls. Existing random tokens retain SHA-256 digests.

Auth migration 2 adds credentials, pending hashes and login attempt counters;
it preserves existing users and sessions. Migration 6 records the requesting
client on sessions and events and adds the throttle key table. Migration 3 adds session metadata,
the email back-off counter, audit actor/detail columns and indexes; existing
sessions are kept and treated as not freshly issued. Migration 4 adds indexed
client/address password back-off state. Migration 5 tracks normalization for
installed credentials and pending registration hashes. Authorization migration 2
adds an index. Deploy them with the same namespaced migration runner before
starting this version.

## Email changes, account deletion and provider unlinking

The account page includes these controls. Their headless operations also work
with custom transports. Each mutation rechecks the live session and active user
under the user row lock, including idle expiry, group scope and the enabled login
method. A recent sign-in means within `policy.fresh_session_seconds`; ordinary
session activity does not renew that proof.

```gleam
// Sign in again, then request a token at the NEW address.
auth.request_email_change(identity, principal, "new@example.com")
// Paste the token in the SAME signed-in session.
auth.confirm_email_change(identity, principal, token)

// Returns #(provider id, issuer) pairs, without external subjects or tokens.
auth.linked_providers(identity, principal)
// Sign in through a DIFFERENT enabled method before unlinking.
auth.unlink_provider(identity, principal, "https://accounts.google.com")
```

Email changes require email delivery to be enabled. Handle the new
`Delivery.purpose` variant `EmailChange`: send its token to `delivery.email`,
telling the reader to confirm the new address on the account page. This is a
separate, single-use token that cannot sign in, register or reset a password.
The old address remains unchanged until confirmation. Both steps require recent
sign-in; confirmation also rechecks address uniqueness under the installation's
group mode. Changing group or group mode invalidates pending changes. Requests
back off both per user and per target mailbox using the configured email cooldown.
Delivery failure invalidates the pending token. Once a change completes, the old
address receives a best-effort `EmailChanged` notice (empty `token`): tell a
reader who did not make the change to contact support, because that mailbox can
no longer recover the account.

By default only the new mailbox is verified, so a hijacked fresh session could
move the account to an address the attacker controls. To also require the
current mailbox, enable approval at startup:

```gleam
let identity = auth.with_email_change_approval(identity)
```

`request_email_change` then sends an `EmailChangeApproval` token to the
**current** address and nothing to the new one. `auth.approve_email_change(
identity, principal, token)` (`POST /email/approve`) redeems it from the
requesting session, rechecks freshness, account state and availability, and only
then sends the usual `EmailChange` token to the new address. Approval and
confirmation tokens are not interchangeable, neither can sign in, and each is
single-use. All three steps must finish within `policy.fresh_session_seconds` of
the sign-in, so consider raising that policy value alongside this option. A user
who has lost the old mailbox cannot change address unaided; trusted
administration still can.

Successful email changes and unlinking sign out **every** session, including the
caller, and cancel pending email changes/provider links. Email changes invalidate
login/registration challenges for both the old and new addresses. Passwords,
user IDs, fields, roles and other linked identities are preserved. Provider login
continues to use the linked subject, independently of the changed recovery email.
After unlinking, sign in through a remaining method. Signing in through the
provider being removed is insufficient proof, even if another method exists:
use that other method first. Disabled methods do not count as alternatives.

Account deletion is disabled until the application supplies its cleanup policy:

```gleam
let identity = auth.with_account_deletion(identity, fn(transaction, user) {
  // Delete/anonymize application-owned rows using this transaction's Repo.
  // Return an error to refuse deletion. For an app with no related data:
  Ok(Nil)
})

// Recent sign-in plus explicit confirmation of the current email address.
auth.delete_account(identity, principal, confirm_email: "ada@example.com")

// As an operator, for an erasure request or a test account. Privileged.
auth.delete_user(identity, user_id, by: user.SystemFrom("console"))
```

`delete_user` runs the same callback and removes the same rows, records
`user.deleted` with the actor, and works on suspended accounts. It is
`Forbidden` until `with_account_deletion` is configured, so application data
is never orphaned.

The callback runs inside the same transaction as deletion. Use the supplied Repo;
do not call other auth operations or perform network/filesystem side effects
there. A callback error or restrictive application foreign key rolls back the
whole database operation. Auth removes the user, passwords, identities, fields,
sessions, pending challenges and scoped role assignments. Roles, groups and
**audit events are retained**; apply the application's audit retention policy
separately. Deletion is not a permanent ban: if registration is open, the person
can subsequently create a new account. External resources should be cleaned up
through an application-owned transactional outbox or equivalent retryable work.

Migration 10 adds pending email changes, records the provider ID on identity
links (existing links were Google), and adds a per-user session version. Run the
normal migrations before starting the new code. `session_store.Entry` now has a
required `version: Int`; custom adapters must persist and return it unchanged.
Pre-upgrade serialized entries can be read as version 0, or cleared on deployment.
The store contract checker includes this field. `Delivery.purpose` exhaustive
matches must also handle `EmailChange`, `EmailChangeApproval` and the tokenless
`EmailChanged` and `PasswordChanged` notices.

Email changes and unlinking advance that version in the database. Authentication
rejects external entries from older versions, including delayed writes after a
change. Deletion rejects them because the user no longer exists. Physical cleanup
of an external store still happens after commit: if it fails, the operation returns
an error **after the account change has committed**, but the old sessions cannot
authenticate. For a surviving account, trusted administration can retry
`auth.revoke_sessions`; deleted users' orphan entries can expire by TTL or be
removed by the adapter. These guarantees concern these new account operations;
other operations retain the external-store semantics described below.

## Custom pages and API clients

Omit `pages.routes` to supply all your own pages. Mounting `routes.api` does not
install or redirect to a login page. Protected routes return JSON 401/403; the
application decides what to show. The starter pages are deliberately minimal,
require JavaScript, and display success without choosing an application redirect.

Error bodies carry a stable `code` beside the English `error`, such as
`{"code":"password_incorrect","error":"current password is incorrect"}`, and
202 answers carry one beside `message`, so a client can show its own words.
`howdy/auth/routes.api` lists the codes.

| Endpoint (relative to API mount) | Input | Result |
| --- | --- | --- |
| `POST /register` | `{"email":"ada@example.com"}` | 202; sends registration token |
| `POST /login` | `{"email":"ada@example.com"}` | 202; sends login token |
| `POST /session` | `{"token":"…"}` | User JSON and browser session cookie |
| `POST /token` | `{"token":"…"}` | Bearer access token, expiry and user JSON |
| `POST /password/register` | `{"email":"ada@example.com","password":"…"}` | 202; sends verification token |
| `POST /password/session` | Email and password | User JSON and browser session cookie |
| `POST /password/token` | Email and password | Bearer access token, expiry and user JSON |
| `POST /password` | Authentication from a fresh email-token session; `{"password":"…"}` | 204; sets or replaces the password, revokes other sessions |
| `POST /password/change` | Authentication; `{"current":"…","password":"…"}` | 204; replaces the password, revokes other sessions; 400 for a wrong current password |
| `GET /me` | Cookie or bearer authentication | User JSON |
| `POST /locale` | Authentication; `{"locale":"de"}`, or `null` to clear | 204; sets the locale pages and emails use for the caller; 400 for one `with_locales` does not offer |
| `GET /sessions` | Cookie or bearer authentication | The caller's live sessions: `id`, `method`, `created_at`, `last_seen_at`, `expires_at`, `current` |
| `POST /sessions/revoke` | Cookie or bearer authentication; `{"id":"…"}` | 204; revokes that session if it is the caller's |
| `POST /logout` | Cookie or bearer authentication; JSON body, e.g. `{}`; `{"all":true}` with multi-session | 204; revokes session. With multi-session the browser falls back to another account, or `all` signs every one out |
| `GET /sessions/accounts` | Cookie authentication | With multi-session: `[{id, user, current}]` for the accounts in this browser; otherwise `[]` |
| `POST /sessions/switch` | Cookie authentication; `{"id":"…"}` from the listing | User JSON; makes that account the browser's active session. 404 if it is not in this browser |
| `POST /email/change` | Recent authentication; `{"email":"new@example.com"}` | 202; emails confirmation token to new address, or an approval token to the current address under `with_email_change_approval` |
| `POST /email/approve` | Only with `with_email_change_approval`; same recent session; `{"token":"…"}` from the current address | 202; sends the confirmation token to the new address |
| `POST /email/confirm` | Same recent session; `{"token":"…"}` | 204; changes email, signs out all sessions and clears cookie |
| `GET /providers` | Authentication | Linked provider/issuer pairs |
| `POST /providers/unlink` | Recent authentication through another method; `{"issuer":"…"}` | 204; unlinks, signs out all sessions and clears cookie |
| `POST /account/delete` | Recent authentication; `{"email":"current@example.com"}` | 204; deletes account and clears cookie; application opt-in required |

`/register`, `/login` and the three `/password/…` sign-in endpoints accept an
optional `"group":"…"`; see [Groups](#groups). User JSON is `id`, `email`,
`group_id`, and `created_at` and `updated_at` as RFC 3339 strings.

Password starter pages are at `/password/register` and `/password/login`,
relative to the page mount. They use the same JSON API as custom pages. There
is also a session-protected `/account` page for setting/resetting passwords,
listing and revoking sessions, and signing out. For password recovery, use the
email-token sign-in page first, then open `/account`.

POST endpoints require `Content-Type: application/json`. Browser session exchange
and password cookie login require the exact configured Origin. Other endpoints allow absent Origin for
native clients but reject foreign or duplicate Origin headers. API responses
carry `Cache-Control: no-store`.

A custom browser page can use:

```javascript
await fetch('/api/auth/register', {
  method: 'POST',
  headers: {'Content-Type': 'application/json'},
  body: JSON.stringify({email}),
});

// After the user enters the emailed token:
const response = await fetch('/api/auth/session', {
  method: 'POST',
  credentials: 'same-origin',
  headers: {'Content-Type': 'application/json'},
  body: JSON.stringify({token}),
});
```

Browsers supply Origin automatically. Browser pages should use the HttpOnly
cookie flow rather than retain bearer tokens in JavaScript storage. Native
clients exchange at `/token` and send `Authorization: Bearer <access_token>`.
Requests carrying both a session cookie and Authorization are rejected, as are
duplicate credentials. `auth.required(identity)` works on both controller guards
and individual endpoints using `guard.require`.

For server-rendered forms or a completely different transport, call
`auth.request_token`, `auth.exchange`, `auth.register_password`,
`auth.login_password`, `auth.set_password`, `auth.authenticate`,
`auth.sessions`, `auth.revoke_session` and `auth.logout`
directly. Those functions return typed results without HTML, redirects or HTTP
responses. A custom transport is responsible for its CSRF protection, cookie
handling, response caching and client throttling. The provided guard requires
Origin on cookie-authenticated writes, including application routes. Applications
must not perform writes on GET routes.

## Groups

Every user belongs to exactly one group: a workspace, a tenant, an
organization. A group is an `id`, a `name` and two timestamps; keep more about
it in [fields](#timestamps-and-fields), or in your own tables keyed by the id. Choose how users relate to groups once, at startup:

```gleam
import howdy/auth
import howdy/auth/group

let assert Ok(identity) = auth.new(repo:, origin:, deliver:)
let assert Ok(identity) = auth.with_groups(identity, group.OneGroupPerUser)
```

| Mode | Groups | An email address has |
| --- | --- | --- |
| `group.Single` (default) | One, `group.default_id` | one account |
| `group.OneGroupPerUser` | Many | one account, in one group |
| `group.AccountPerGroup` | Many | at most one account *per group*, each with its own user id, credentials and sessions |

An application that never mentions groups gets `Single` and needs to do nothing:
everyone is in the group `default`, which migration 7 creates and puts existing
users in. `user.User` carries `group_id`, and so does the user JSON.

`auth.in_group(identity, id)` returns the same configuration acting in one
group. Requests made through it apply to that group, and it authenticates only
that group's users:

```gleam
let acme = auth.in_group(identity, "acme")
auth.request_token(acme, email, auth.Register)     // the new user joins acme
controller.guarded("/acme", auth.required(acme))   // only acme's users pass
```

- `OneGroupPerUser` needs a group to **register**, which is how a new user's
  group is chosen. Signing in works without one; with one, the account must be
  in it.
- `AccountPerGroup` needs a group for every token request, registration and
  password login, because an address alone does not name an account. Requests
  without one are `Invalid`.
- A group that does not exist is `NotFound("group")`. Under `Single`, that is
  every id but `default`.

The JSON endpoints that take an `email` also take an optional `"group"` id, and
the starter pages pass on a `?group=` query parameter. That value is the
client's claim about where it wants to sign in. After authentication, trust
`principal.user.group_id`, or guard with `auth.required(auth.in_group(…))`.
With public registration enabled, anyone who knows a group's id can register
into it; leave `allow_registration` off if membership is by invitation, and
create members with `auth.provision`.

`howdy/auth/groups` manages groups. Like user administration, these are trusted
operations that take `by:` and are not exposed over HTTP:

```gleam
import howdy/auth/groups

let assert Ok(acme) = groups.create(identity, name: "Acme", by: user.System)
let assert Ok(_) =
  groups.create_with_id(identity, id: "globex", name: "Globex", by: user.System)
groups.list(identity)
groups.get(identity, "globex")
groups.rename(identity, acme.id, to: "Acme Ltd", by: user.Acting(principal))
groups.members(identity, acme.id)
groups.move(identity, user_id, to: "globex", by: user.Acting(principal))
groups.delete(identity, acme.id, by: user.System)  // Conflict while it has users
```

`create` generates the id; `create_with_id` takes one of 1 to 64 letters, digits,
hyphens and underscores, such as a tenant slug. `move` takes the user's sessions
and credentials with them, and is `Conflict` under `AccountPerGroup` when the
destination already has an account for the address. Groups are independent of
authorization scopes: to scope roles by group, use
`authorization.Organization(group_id)`, and revoke those roles yourself when
moving a user.

The mode is recorded in the database. `auth.new` adopts the recorded mode, and
`auth.with_groups` with a different one converts the installation in a single
transaction, or refuses with `Conflict` when the existing users do not fit:
`Single` needs everyone in `default`, and leaving `AccountPerGroup` needs no
address to have accounts in two groups. Sessions survive a conversion; emailed
tokens not yet redeemed do not. Convert with other nodes stopped, since a
running node keeps the mode it started with.

Uniqueness is enforced by the database through `howdy_auth_users.login_key`:
the address, or `group_id:address` under `AccountPerGroup`. Read
`howdy_auth_users.email` for the address, as before.

## Timestamps and fields

`user.User` and `group.Group` carry `created_at` and `updated_at` as
`gleam/time` timestamps, in whole seconds, and their JSON carries them as
RFC 3339 strings. PostgreSQL stores them as `TIMESTAMPTZ`; SQLite stores unix
seconds. A user's `updated_at` moves when they are suspended or resumed, change
group, or have a field changed; a group's when it is renamed or has a field
changed. Credentials, sessions and membership do not move it. For rows that
predate these columns, `created_at` comes from the audit trail
(`user.registered`, `user.provisioned`, `group.created`) and is the unix epoch
where those events have been pruned.

A field is a small fact your application keeps about a user or a group: a
username, a plan, a billing id. Declare it once, then use the declaration to
write and to read, so the two cannot disagree about the type:

```gleam
import howdy/auth/field
import howdy/auth/groups
import howdy/auth/users

pub fn username() {
  field.text("username")
  |> field.unique
  |> field.check(fn(name) {
    case string.length(name) >= 3 {
      True -> Ok(Nil)
      False -> Error("must be at least 3 characters")
    }
  })
}

pub fn seats() { field.int("seats") }

let assert Ok(_) =
  users.update(identity, id, [field.set(username(), "ada")], by: user.Acting(principal))

use data <- result.try(users.fields(identity, principal.user.id))
let name = field.get(data, username()) |> result.unwrap(principal.user.email)

let assert Ok([ada]) = users.find(identity, where: username(), is: "ada")
```

| Declare | Holds |
| --- | --- |
| `field.text`, `field.int`, `field.bool` | the obvious |
| `field.time` | a `Timestamp`, as RFC 3339 text |
| `field.custom(name, encode:, decode:)` | your own type, as text |

| Modifier | Effect |
| --- | --- |
| `field.unique` | one holder per value across the installation |
| `field.unique_in_group` | one holder per value within a group; user fields only |
| `field.check(with:)` | refuse values; the message comes back as `Invalid` |

`users.update` and `groups.update` take `field.set` and `field.clear` changes
and apply them all or nothing. `auth.provision_with(identity, email, fields:,
by:)` and `groups.create_with(identity, id:, name:, fields:, by:)` set fields in
the transaction that creates the row. `users.get`, `users.fields` and
`users.find` called through `auth.in_group` see only that group's users. Like
the rest of user administration these are privileged and not exposed over HTTP:
authorize the caller first.

Uniqueness is enforced by the database, so a taken value is `Conflict` even
under concurrent writes. Declare a field unique before it is first written:
values stored while it was not are not checked against. Values unique within a
group follow a user through `groups.move`, which is `Conflict` if the
destination already holds one. Changes are audited as `user.fields_changed`,
with the field names as detail, and `group.fields_changed`; values never reach
the audit trail.

Fields are not loaded when a request is authenticated; call `users.fields`
where you need them. Names are 1 to 64 lowercase letters, digits and
underscores, user and group fields are named separately, and an encoded value
is at most 1024 bytes. Anything relational, or that you query by range, still
belongs in your own tables keyed by the id.

## Several accounts in one browser

By default signing in replaces the browser's session, and the old one is revoked.
To let people stay signed in to several accounts and move between them:

```gleam
let assert Ok(identity) = auth.with_multi_session(identity, max: 5)
```

Signing in while signed in then **adds** an account. The browser holds a second
HttpOnly cookie, `__Host-howdy_accounts`, listing the session tokens of its
accounts; the usual session cookie still says which one is active, so
`auth.required`, guards and every application route work unchanged and see one
user at a time. `GET /sessions/accounts` lists the accounts by session id and
user, never by token; `POST /sessions/switch` activates one of them, and only
one this browser already holds. Signing out returns to the most recently added
account still signed in, as does any account change that ends the active session
(email change, deletion, passkey removal, and the rest); `{"all": true}` signs
every account out. Signing in to a user already present replaces that user's
session, and signing in beyond `max` (2 to 10) signs the oldest account out;
both revoke the displaced session on the server. While a newly added account
waits for its second factor, the current account stays active. The starter
account page lists the accounts with Switch buttons.

Every account is an ordinary session: listed, renewed, expired, idle-timed and
revoked like any other, in the database or an external store. Entries that no
longer authenticate are dropped from the cookie whenever it is rewritten. The
accounts cookie is as sensitive as the session cookie and gets the same
attributes. Bearer clients are unaffected; a native app holding several tokens
already has this. Custom cookie transports use `auth.device_sessions`,
`auth.add_device_session` and `auth.accounts_cookie_name`.

## Session storage

Sessions live in the auth database by default, and most applications should
leave them there: they are created and revoked in the same transactions as the
changes that cause them. To keep them elsewhere, such as Redis, supply a
`SessionStore`:

```gleam
import howdy/auth/session_store

let identity = auth.with_session_store(identity, my_redis_store(connection))
```

A store is a record of seven functions over one small record type,
`session_store.Entry`: `insert`, `get`, `touch`, `list`, `delete`,
`delete_for_user` and `prune`. `howdy/auth/session_store` documents what each
must do. Nothing else changes: the routes, guards, `auth.sessions` and the rest
behave the same, and this package gains no dependency on any backend.

```gleam
pub fn my_redis_store(connection) -> session_store.SessionStore {
  session_store.SessionStore(
    insert: fn(entry) { todo as "SET howdy:s:<digest> with a TTL; SADD howdy:u:<user_id>" },
    get: fn(digest) { todo },
    touch: fn(digest, now, expires_at) { todo as "set both; EXPIREAT from expires_at" },
    list: fn(user_id) { todo },
    delete: fn(digest, user_id) { todo },
    delete_for_user: fn(user_id, keep) { todo },
    prune: fn(_now) { Ok(Nil) },  // the TTL already does it
  )
}
```

- **A store never sees a session token**, only a one-way digest of it, so its
  contents cannot be used to sign in.
- **Users, credentials and suspension stay in the database.** Every request
  reads the session from the store and then confirms in the database that its
  user is active, so a suspended user is refused even if the store still holds
  their sessions. An external store moves session data; it does not remove the
  per-request database read.
- **The package enforces expiry and idle timeouts itself** from the entry's
  timestamps. A store may expire entries natively as well.
- **Renewal arrives through `touch`.** Its third argument is the expiry to
  store: the unchanged value normally, a later one when
  `policy.session_renew_seconds` is renewing the session. A backend with a
  native TTL must reset it from that value, or renewed sessions vanish early.
  This argument was added with renewal; adapters written for the two-argument
  `touch` no longer compile, and `check` fails one that ignores it.
- **Atomicity is what you give up.** The database commits first and the store
  is written second. If the store fails in between, the operation returns its
  error with the database change already made: a sign-in without a session
  (request another token), or a `suspend`, `revoke_sessions` or `set_password`
  whose sessions are not yet removed (call it again). `resume` clears the
  user's stored sessions first and refuses if it cannot, so a suspension whose
  revocation failed never comes back to life.
- **Changing store signs everyone out.** Sessions are not copied across.
- Return `Error(service.Internal(_))` when the backend fails. Operations then
  fail closed.

`session_store.check(store)` exercises a store against the contract and returns
the first rule it breaks; call it from an adapter's test suite, pointed at a
test backend. `session_store.memory()` is a reference implementation for tests
and single-node development: it is lost on restart and not shared between nodes.

## Simple roles and permission-based RBAC

Authentication provides a user and verified session. Authorization separately
stores role definitions, permission grants and scoped user assignments:

```gleam
import howdy/authorization as access

let assert Ok(permissions) = access.new(db)

// Trusted provisioning/administration code, not a public request handler:
let assert Ok(_) = access.define_role(
  permissions, access.Global, "editor",
  ["articles.read", "articles.write"], by: user.System,
)
let assert Ok(_) = access.assign(
  permissions, user_id, "editor", access.Global, by: user.Acting(admin),
)
```

A simple role check inside an authenticated controller:

```gleam
use _ <- guard.require(
  ctx, access.require_role(permissions, "editor", access.Global),
)
```

Or check the operation the user may perform:

```gleam
use _ <- guard.require(
  ctx, access.require_permission(permissions, "articles.write", access.Global),
)
```

`access.has_role` and `access.allowed` expose the same checks as
`service.Result(Bool)` for application logic outside HTTP. Database failures
propagate as errors, not successful authorization decisions.

Multiple roles grant the union of their permissions. Names are literal strings:
there are no implicit `admin` privileges, wildcard permissions, role inheritance
or deny rules. Changing a role's permissions or revoking an assignment takes
effect on the next check, without waiting for the session to expire.

Use `access.Organization(organization_id)` instead of `Global` for organization
roles. Every grant is limited to exactly that scope; global roles do not bypass
organization checks. Organization IDs belong to the application's domain model.
Load/validate the target resource's organization and use that scope for checks
and data queries. An authorization result does not automatically filter SQL or
establish tenant membership. Object ownership and other business rules remain
application decisions.

## User administration and operational limits

`auth.suspend`, `auth.resume`, and `auth.revoke_sessions` are trusted management
operations. Pass `by: user.SystemFrom(client)` rather than `user.System` when an
operator request arrived over a transport of your own and you want it recorded. Suspending revokes sessions and pending challenges atomically;
resuming never restores old sessions. Role mutations and user administration
are **not exposed as unauthenticated HTTP routes**. Authorize a caller before
using them. Each takes `by:` — `user.Acting(principal)` for an administrator's
request or `user.System` for provisioning and scheduled code. The function
records who acted; deciding whether they may is still the application's job.

`auth.provision(identity, email, by:)` is the trusted way to create a user
without asking them: an invitation, an import, a directory sync. It works with
public registration disabled, which makes it the way to run an invitation-only
installation, and it sends nothing. The user signs in with a login token when
they are ready, which is also what proves the address is theirs. The group is
chosen as for registration, so outside `group.Single` pass
`auth.in_group(identity, group_id)`. It is `Conflict` when the address already
has an account where it must be unique, and is recorded as `user.provisioned`.

For management consoles, `authorization.roles` lists every role with its
permissions, `authorization.assignments` the roles a user holds,
`authorization.holders` the users holding a role, and
`authorization.delete_role` removes a role and its assignments (recorded as
`role.deleted`). `scope_to_string` and `scope_from_string` round-trip a
scope as `global` or `org:<id>`.

`auth.sessions_of(identity, user_id)` lists a user's live sessions for an
operator, with no session marked current, and
`auth.revoke_session_of(identity, user_id, session_id, by:)` ends one of them,
recorded as `session.revoked` with the actor. Both are privileged.

`auth.impersonate(identity, user_id, by:)` issues a session for a user without
a credential, for an operator console or the [`howdy_admin`](https://github.com/mikeyjones/howdy/blob/v2.1.1/admin/README.md)
development area. The session's method is `auth.Impersonation` and the event
is `session.impersonated`, so it is distinguishable from the user's own in
`auth.sessions` and the audit trail. It skips second factors and SSO
enforcement, so it must never be reachable by the user: authorize the caller.
Suspended users are `NotFound`. `routes.signed_in` sets the browser cookies
for a session obtained this way. Migration **18** allows the method name.

Users manage their own sessions with `auth.sessions` and `auth.revoke_session`
(`GET /sessions`, `POST /sessions/revoke`). Session ids are digests: they
identify a session but cannot authenticate as it.

Every event records the client the request came from, and every session records
the client it was created from. `auth.required` reads the socket address;
behind a proxy use `auth.required_from` and `routes.api_limited_by` with the
header your ingress sets, and the same identity then serves rate limiting,
throttling and audit. `auth.authenticate_from` and `auth.exchange_from` take it
for callers outside HTTP. A client string is whatever you pass; once it is an
address it is personal data, so it falls under the same retention as the rest
of `howdy_auth_events`, and passing an empty string records nothing.

The module records transactional lifecycle events in `howdy_auth_events`:
the affected user, the action, the acting user (`actor_id`, empty for system
or self-service by email proof), a `client`, and a `detail` such as the role
and scope or the login method. A token request for an address that has an
account is recorded as `token.requested` with its purpose, so someone asking
why they received an email can be answered. Failed password logins on real accounts are recorded too.
`auth.prune_events(identity, before: unix_seconds)` applies a retention period.
This is not yet an enterprise audit system: audit export, integrity protections
and a management API remain future work.

The default HTTP endpoints rate limit per client in-process: 30 requests per
minute to endpoints that send email, exchange tokens or hash passwords
(`routes.credential_limit`), and a separate 300 per minute to the signed-in
endpoints pages call routinely (`/me`, `/sessions`, `/logout`). `routes.api`
identifies clients by socket address. **Behind a reverse proxy that is the
proxy's address for everyone**, so use `routes.api_limited_by` with the header
your ingress sets:

```gleam
routes.api_limited_by(identity, at: "/api/auth", key: fn(ctx) {
  request.get_header(ctx.request, "fly-client-ip") |> option.from_result
})
```

Only trust a header your ingress overwrites.

By default each node counts on its own, so behind a load balancer a client gets
the full limit from every node, and a restart forgets its count. To share the
limits of `routes.api`, `routes.providers` and `routes.sso` between nodes, count
them in the auth database (migration **17**):

```gleam
let identity = auth.with_shared_rate_limits(identity)
```

Each limited request then costs one database write, keyed by a digest of the
client rather than its address. If that write fails the request is allowed and
a warning logged, so a database hiccup never locks everyone out; the password,
code and second-factor guessing limits behind it are always in the database and
never fail open. Windows follow the system clock, so keep nodes' clocks in sync.
`auth.with_rate_limit_store` counts in a store of your own instead, such as
Redis, and `auth.rate_limit_store(identity)` lends the auth database to the
application's own `rate_limit.shared` limiters. `auth.prune_expired` clears old
windows; they are also cleared now and then as traffic passes.

Token requests are bounded per address by coalescing rather than by refusing:
while a usable token is waiting, further requests send nothing and still report
success. A new request never invalidates tokens already sent; the three most
recent stay valid. So a third party requesting tokens for someone else's
address can neither flood that inbox, nor cancel the token its owner is about
to paste, nor stop the owner receiving one. This holds however many clients
they request from, because the limit is a property of the inbox and not of who
asked. Registration with a password is the one request that cannot be answered
from the inbox, so it backs off per address instead, in the database and shared
across instances: 60 seconds after the first, doubling up to an hour, starting
over after 15 quiet minutes or as soon as a token is exchanged.

Operators must also bound total outgoing mail volume through the
provider/ingress to control abuse across many addresses.

Rows recording which addresses have been asking are keyed with a random secret
created in the database on first use (`howdy_auth_keys`), so they cannot be
matched against a guessed address. Token and session digests are unkeyed:
those values are already random secrets.

Concurrent password hashing is bounded by the runtime rather than by this
package. OTP runs PBKDF2 on the BEAM's dirty CPU schedulers, so at most that
many hashes are ever in flight whatever the request rate, and normal schedulers
keep serving requests. One hash takes roughly 100 ms of CPU. Bound the arrival
rate with the route limiter described above.

Token/session digests are stored instead of raw secrets. Expired rows are
pruned as a side effect of email requests and logins. For quiet installations
call `auth.prune_expired(identity)` from a scheduled job; nothing is scheduled
automatically.

See [the runnable examples](https://github.com/mikeyjones/howdy/blob/v2.1.1/examples/auth/README.md), one per sign-in flow. Run verification with:

```sh
cd auth
gleam test                                      # Gloo SQLite, isolated in memory
HOWDY_AUTH_TEST_BACKEND=postgres gleam test      # same suite, real PostgreSQL
gleam format --check src test
node --test test/pages_client_test.mjs           # account-page interactions
```

PostgreSQL tests use localhost:5432 with a test-only `howdy_auth_test` role and
trust authentication. The role must be able to create temporary test databases.
Each case creates and drops its own uniquely named database. CI runs the same
suite against both adapters using a disposable PostgreSQL service.


## Follow-up API notes

`Delivery.token` and `Session.token` are now opaque `secret.Secret` values.
Call `secret.reveal(value)` explicitly at delivery or transport boundaries;
ordinary inspection of the enclosing record no longer prints the credential.
This prevents accidental logs, not deliberate access to process memory.
The example's local-only delivery output deliberately reveals the token.

Origin construction lowercases scheme/host and removes default ports, preserving
IPv6 brackets. Requests still require an exact canonical Origin for cookie writes.

Privileged `suspend`, `resume` and `revoke_sessions` return `NotFound("user")`
for missing users. Role assignment/revocation also return `NotFound("role")`
for a missing role. Revoking an absent assignment of an existing role is idempotent.
Applications remain responsible for authorizing callers of these headless APIs.

Authorization defaults to fresh database reads. Opt in with
`access.with_cache(permissions, seconds: 5)` (1–60 seconds) at application startup.
This bounded in-memory cache stores successful role/permission decisions, never
database errors. Only role definition/assignment/revocation, suspension/resume and data migrations
invalidate caches. Login, password, throttle and session transactions preserve
cache entries. Invalidation follows the outermost Howdy transaction, including
rollback, so a grant changed inside your own `database.transaction` or
`postgres.transaction` is invalidated when that transaction ends; uncommitted
changes bypass the cache. Use `access.with_changes(fn() { ... })` around
application-owned grant SQL, and around transactions opened directly through
`gloo/repo` or pog, when local invalidation is required. This wrapper does not
make sharing SQLite connections safe. A generation stamp prevents an older in-flight read
from repopulating the current generation after a write. Changes from another
BEAM node or direct SQL may remain stale until the TTL; use the default for
immediate distributed revocation. Always authenticate the session on every request:
this cache does not replace session validation or cache session secrets. If the
process owning the cache exits, authorization falls back to fresh reads.

The core reserves `howdy/auth`, `howdy/auth/*`, `howdy/authorization` and
`howdy/migration` for this optional package. The root CI namespace check enforces
this agreement, avoiding a package-wide breaking module rename.
