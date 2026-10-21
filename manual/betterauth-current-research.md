# Better Auth comparison research — 21 September 2026

Scope: current official Better Auth documentation and current Howdy README. Excludes enterprise federation, SAML and SCIM. Better Auth's live documentation footer identifies 1.7.5; these notes are a documentation snapshot, not a source audit or proof every feature ships in a particular older release. Optional plugins are capabilities, not defaults. Howdy implementation findings should be checked against code by the comparison reviewer.

## Findings that change the earlier assessment

The current Howdy README documents current-password changes, optional old-email approval, Apple sign-in, configurable passkey RP ID/additional origins, conditional autofill, verified passkey-first registration, configurable MFA recovery-code count and remembered-device expiry/renewal, sliding sessions and same-browser account switching. These should no longer be counted as missing. Typed custom fields, scoped authorization, account deletion, unlinking, trusted provisioning and suspension also already exist.

**Documentation contradiction found and corrected during this review:** `auth/README.md` section “Scope compared with Better Auth” previously said passkey RP/origins, conditional autofill, pre-auth signup and configurable trust/renewal are absent. Earlier sections document them. The parent comparison reviewer corrected this stale paragraph; it was not used as capability evidence.

## Current Better Auth capabilities and residual differences

| Area | Better Auth evidence | Comparison implication |
| --- | --- | --- |
| Browser clients | Framework-agnostic client plus React, Vue, Svelte and Solid integration; reactive `useSession`, fetch/error handling and client plugins. [Client](https://better-auth.com/docs/concepts/client) | A packaged typed/reactive client is still a meaningful gap if Howdy only supplies headless Gleam functions, JSON and starter-page JavaScript. |
| Mobile | Expo client handles SecureStore-compatible cookie/session storage and scheme-based OAuth deep links. [Expo](https://better-auth.com/docs/integrations/expo) | Native bearer endpoints alone are not equivalent integration support. |
| Login breadth | Optional magic-link, primary email OTP, username, phone, anonymous guest, Google One Tap, wallet and generic OAuth plugins. [Plugin catalog](https://better-auth.com/docs/plugins) | Howdy's pasted high-entropy email token is not a convenient short OTP or clickable link; MFA delivered OTP is a different operation. Lower-priority methods should be driven by product needs. |
| Passkeys | Conditional UI and RP configuration, pre-auth registration callbacks (`resolveUser`/`afterVerification`), client/server extensions with returned results, selectable authenticator attachment, resident-key and UV policy. [Passkeys](https://better-auth.com/docs/plugins/passkey) | Core lifecycle is close now. Remaining flexibility includes WebAuthn extensions, selectable authenticator policies and pluggable onboarding; Howdy's fixed required resident key/UV is a stricter choice, not an omitted security check. Better Auth uses SimpleWebAuthn. Do not assert enterprise attestation-management parity based only on this page. |
| MFA | TOTP, delivered OTP, backup codes, remembered devices; configurable digits/periods, recovery length/generation/storage, and account-wide lockout settings. Default 2FA gate covers credential sign-ins, not social/passkey/email-OTP/magic-link flows. [2FA](https://better-auth.com/docs/plugins/2fa) | Core lifecycle is close. Howdy already has trust renewal/duration and recovery count; remaining format/timing/lockout customization is smaller. Broader Howdy gating is a policy difference, not proof of superior security. Both have account-wide guessing limits. |
| Sessions | Expiry/update intervals, freshness, list/revoke, cookie-cache strategies, secondary storage and stateless sessions; cache can delay cross-device revocation until expiry. [Sessions](https://better-auth.com/docs/concepts/session-management) | Howdy renewal/account switching are present now. Caching/stateless operation and browser reactive integration remain different. Fresh database validation is a deliberate tradeoff, not automatically a weakness. |
| Rate limits | Memory default; database, secondary-storage and atomic custom backend options. Server-side `auth.api` bypasses this HTTP limiter. [Rate limits](https://better-auth.com/docs/concepts/rate-limit) | Howdy account/password/MFA budgets are persistent, but its general HTTP limiter remains per process: important before horizontal deployment. |
| Administration | Permission-controlled user-management API/client, searchable/paginated users, role and ban management, impersonation. [Admin](https://better-auth.com/docs/plugins/admin) | Howdy trusted primitives/RBAC cover part of this, but applications build transport authorization and support workflows. Do not imply an open-source hosted dashboard is included. |
| Service credentials | API-key create/list/update/delete/verify, scoped permissions, expiry and rate limits; user and organization ownership. [API keys](https://better-auth.com/docs/plugins/api-key) | Bearer sessions are not independently managed integration credentials. Prioritize when exposing a public/integration API. |
| Collaborative accounts | Organizations, membership/invitations, organization permissions and teams. [Organizations](https://better-auth.com/docs/plugins/organization) | Howdy single-group identity partitioning is not one identity belonging to multiple workspaces. Relevant to ordinary SaaS, separately from excluded enterprise federation. |
| Extension points | Before/after endpoint hooks; schema/database hooks and adapter options. [Hooks](https://better-auth.com/docs/concepts/hooks), [Database](https://better-auth.com/docs/concepts/database) | Headless functions are composable but do not supply the same supported plugin contract and reusable integrations. Better Auth also supports more databases/ORMs; Howdy's SQLite/PostgreSQL focus may be entirely sufficient. |
| Provider APIs | Account scope management, linking via redirects or supported provider ID tokens, persisted provider credentials, access-token retrieval/refresh. [Accounts](https://better-auth.com/docs/concepts/users-accounts) | Howdy explicitly discards access/refresh tokens. This is adequate for login, weaker when an app needs ongoing access to the user's provider APIs. Avoid calling token retention inherently safer. |

## Assessment guidance

For ordinary account lifecycle, passwords, social login, passkeys, MFA and stateful sessions, Howdy is now close in **workflow coverage**, with more fixed policies. It remains substantially narrower as an **auth platform and integration ecosystem**. Do not invent a single percentage combining critical login flows with optional billing/wallet/agent plugins.

Remaining priorities are best separated:

1. Operational confidence: supported dependencies, real-browser/device interoperability, recovery testing, release/migration guarantees and shared HTTP rate limiting.
2. Product usability: simpler email login and local TOTP QR rendering, reusable typed/reactive client and clearer reauthentication/recovery flows.
3. Product-dependent breadth: API keys, packaged admin support, collaborative memberships and additional provider/API integrations.

Howdy's README still records a local Jargon native-password patch and glasslock 1.0.0-rc1 with internal parsing APIs, plus stop-old-instance migration guidance. These limit release readiness; a feature comparison alone establishes neither vulnerabilities nor an assurance ranking. No code changes, device trials or test reruns were performed for these research notes.

## Key rotation and QR nuance

Better Auth supports versioned encryption secrets: the first key encrypts new data; previous keys decrypt existing versioned envelopes. Its single `secret` can remain during migration to decrypt legacy data. This provides a concrete operational comparison to Howdy's documented single stable MFA key, whose replacement strands existing TOTP ciphertext. Rotation support is not automatic historical re-encryption or permission to discard old keys. [Options: secrets](https://better-auth.com/docs/reference/options#secrets), [security](https://better-auth.com/docs/reference/security).

Better Auth's TOTP documentation returns an `otpauth` URI and illustrates **application-supplied local QR rendering** using `react-qr-code`; it is not evidence of a bundled hosted setup UI. Howdy already returns the URI too. Adding QR rendering to Howdy's manual-key starter page is a useful usability improvement, not missing TOTP protocol functionality. [2FA setup](https://better-auth.com/docs/plugins/2fa).
