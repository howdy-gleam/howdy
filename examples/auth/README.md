# Authentication examples

Runnable, tested examples of each way `howdy_auth` signs people in, plus a
full tour that combines most of them. Everything listens on loopback only.
Email delivery prints tokens in the terminal **for this local demonstration
only**; configure a private email delivery callback for real applications.

```sh
gleam run -m migrate                     # every example's database
gleam test                               # every flow below, without a server
```

## One flow per module

Each module in `src/flows/` is small, commented, and exposes `configure`
(the auth setup), `app` (the routes) and `main`. Its test in `test/` walks the
flow request by request, so it doubles as a transcript of the HTTP contract.
Each keeps its own SQLite file, since they configure auth differently.

| Run with `gleam run -m …` | Shows | Needs |
| --- | --- | --- |
| `flows/email_tokens` | Passwordless sign-in and registration by emailed token; a browser cookie and a native bearer token from the same exchange | — |
| `flows/passwords` | Email/password alongside tokens; verification before the account exists, a breach blocklist, changing a password, sliding session renewal | — |
| `flows/social_login` | Google, GitHub, Apple, Facebook and Microsoft Entra; which may create accounts and which must be linked | Provider credentials; see the module |
| `flows/passkeys_and_mfa` | Passkeys (including signup and autofill); TOTP and delivered-code MFA, recovery codes, remembered devices | `HOWDY_AUTH_MFA_KEY` |
| `flows/server_rendered` | Your own HTML forms and cookie on the headless API: no JSON routes, starter pages or JavaScript | — |
| `flows/multi_tenant` | Invitation-only workspaces as groups; roles scoped per workspace; user and workspace fields | — |
| `flows/enterprise_sso` | Customer SAML/OIDC connections, email-first routing, SP metadata, enforcement | `HOWDY_AUTH_SSO_KEY` and a connection; see the module |
| `flows/sessions` | Renewal and idle limits, several accounts in one browser, an external session store adapter | — |

Every example serves <http://localhost:8787>, so run one at a time. Start from
the table's first row: the others each add one idea to it.

## The full tour

`src/howdy_auth_example.gleam` combines email tokens, passwords, Google,
passkeys, MFA, RBAC and application-owned data in one app:

```sh
gleam run
```

Open <http://localhost:8787/auth/register>, enter an email address, then paste
the token printed in the terminal. Visit `/account/me` to see the authenticated
user. `/account/reports` returns 403 until trusted administration code, such as
the console below, assigns the existing `reader` role to that user. There is deliberately no public role
assignment endpoint or automatic first-user administrator.

Password registration is at `/auth/password/register`; verify the email using
the printed token, then sign in at `/auth/password/login`. Password support is
explicitly enabled by `auth.with_passwords` in the example. Existing email-only
accounts cannot add a password by registering again; sign in with an email
token and open `/auth/account` within ten minutes instead. That page lets you
set/reset a password, list or revoke sessions, and sign out. Custom clients can
call `POST /api/auth/password` directly.

Existing users can also sign in with email tokens at `/auth/login`. The JSON API is mounted at `/api/auth`.
Omit `pages.routes` in `src/howdy_auth_example.gleam` to supply your own pages;
the JSON endpoints and account guards still work.

`src/database.gleam` owns the Gloo connection and its configuration; auth receives
only the resulting Repo. This example chooses SQLite, but replacing that setup
with a configured Gloo PostgreSQL Repo leaves the auth/routes/RBAC code unchanged.

`src/notes.gleam` is application-owned data beside auth's, built on
[`howdy_database`](../../database/README.md): its own `notes` migration package,
run by the same `migrate` command and checked at startup, and services that
work on either database. Signed in, `GET`, `POST {"title"}` and
`DELETE /:id` under `/account/notes` list, add and remove your notes; a
duplicate title is a 409. Deleting the account removes its notes in auth's own
transaction, through `auth.with_account_deletion`.

`data.sqlite` (and each flow's own file) persists between runs. Schema
migrations are a separate command and are never automatically applied during
application startup.

See [the package documentation](../../auth/README.md) for browser/native API
flows, headless operations, scoped RBAC and current limitations.

Google sign-in is enabled when `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` are
set in the process environment. Create a Google OAuth **Web application** client
and register this exact redirect URI:
`http://localhost:8787/auth/providers/google/callback`. Use OTP 27 or newer.
Run the migration command again before starting an existing demo database.

The login page will display **Continue with Google**. A first sign-in with a
Gmail/Workspace address creates an account. If that email already has a local
account, sign into it with an email token first and use **Link Google** on
`/auth/account`. Linking requires a session created within the last ten minutes.
Google accounts using third-party email addresses must register/verify locally
before linking. Google sign-in leaves existing RBAC permissions unchanged.

Passkeys are enabled in the demo. Sign in, then add a passkey on `/auth/account`;
subsequent logins can use the **Sign in with a passkey** button. Browsers permit
WebAuthn on localhost; deployments need HTTPS and a stable public origin.

To enable authenticator MFA, generate a key once and store it privately:

```sh
openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'
```

Supply that value as `HOWDY_AUTH_MFA_KEY` every time you start the example.
Do not generate a replacement on each startup. Run the migration command before
using an existing database. Enroll from `/auth/account`, copy the manual key into
your authenticator and verify its code. Save the recovery codes, then sign in
again and complete MFA. The demo does not configure delivered-code fallback.

## A console on the running server

[GSH](https://hexdocs.pm/gsh/) is a Gleam REPL that can attach to a running
server and run what you type inside it, like `rails console`, but in the live
process rather than a copy. Start the full tour as a named Erlang node, then
attach from a second terminal:

```sh
# Terminal 1: the server, reachable by Erlang distribution on loopback only
ERL_EPMD_ADDRESS=127.0.0.1 \
ERL_FLAGS="-sname howdy_auth@localhost -setcookie dev -kernel inet_dist_use_interface {127,0,0,1}" \
gleam run

# Terminal 2: the console
ERL_FLAGS="-kernel inet_dist_use_interface {127,0,0,1}" \
gleam run -m gsh -- --remsh howdy_auth@localhost --cookie dev
```

`ERL_EPMD_ADDRESS` only applies when it starts the Erlang port mapper; one
already running from another node keeps listening where it was started.

`main` exposes the database, auth and roles it configured through
`howdy/console`, and `src/console.gleam` wraps the common operations:

```gleam
gsh(1)> console.users()
gsh(2)> console.grant("ada@example.com", "reader")
Ok(Nil) : Result(Nil, Error)
gsh(3)> console.sessions("ada@example.com")
gsh(4)> console.sign_out("ada@example.com")
```

The grant takes effect at once: Ada's next request to `/account/reports`
succeeds. Every operation is recorded in the audit trail with the client
`console`. `console.services()` returns the server's own `Repo`, `Auth` and
`Authorization` for anything the shortcuts do not cover.

To run the server and the console in one terminal instead, let GSH start it:

```sh
gleam run -m gsh -- howdy_auth_example
```

The console runs privileged operations with no authorization of its own.
Anyone who can connect to the node can run any code in it, which is why the
commands above keep distribution on loopback. See the
[console guide](../../docs/guides/console.djot) before attaching to a server on
another machine.

