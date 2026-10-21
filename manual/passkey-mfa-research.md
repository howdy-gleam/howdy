# Passkey and MFA implementation research

Research date: 2026-09-20. This records the comparison target and dependency choice, not a claim that the implementation is complete or independently security audited.

## Better Auth comparison target

Better Auth's passkey plugin uses SimpleWebAuthn. It supports authenticated enrollment, passwordless sign-in, listing/naming/deleting credentials, discoverable credentials and browser autofill. Configuration includes RP/origins, authenticator attachment, resident keys, and user verification. Its schema also records transports, AAGUID and backup metadata. Optional advanced capabilities include pre-authentication enrollment with application-provided user resolution, extension forwarding, and Expo integration. These optional capabilities should be distinguished from everyday enrollment/sign-in parity. [Official passkey documentation](https://better-auth.com/docs/plugins/passkey).

The 2FA plugin provides TOTP, delivery-callback OTP, replacement/one-use backup codes, enrollment/disable flows and trusted devices. TOTP normally becomes active only after enrollment verification; defaults use 30-second periods and adjacent-period tolerance. Trusted devices default to 30 days with renewal. Password accounts require password confirmation to manage factors; passwordless management is opt-in. Failed checks share an account-level lockout across factors and challenges. Credential sign-in produces a restricted challenge, with no authenticated session before verification. OAuth and passkey sign-ins are not MFA-gated by default. Delivery OTP requires a configured sender; displaying TOTP QR codes is application work. Advanced options include custom code storage/generation and passwordless management. [Official 2FA documentation](https://better-auth.com/docs/plugins/2fa).

## Native verifier recommendation

**Use glasslock behind a small Howdy-owned integration boundary**, with an explicit prerelease maturity note. It is a native Gleam server verifier targeting Erlang and Node, accepts the conventional SimpleWebAuthn JSON shape, and avoids an extra Elixir or Node runtime. The published version inspected is **1.0.0-rc1**, released August 5, 2026. This is a recent prerelease, not an established independently audited dependency. [Hex release metadata](https://hex.pm/api/packages/glasslock/releases/1.0.0-rc1), [project README](https://github.com/jtdowney/glasskey/tree/main/glasslock).

Dependencies match Howdy's existing Gleam ranges: `gleam_json >=3.1 <4`, `gleam_stdlib >=0.67.1 <2`, `gleam_time >=1.8 <2`, plus `gose >=2.1 <3` and `kryptos >=1 <2`. The package uses the Gleam build tool. [Published metadata](https://hex.pm/api/packages/glasslock/releases/1.0.0-rc1).

### API and security checks inspected

The actual [published archive](https://repo.hex.pm/tarballs/glasslock-1.0.0-rc1.tar) was extracted outside the repository and inspected; source API references below match its code:

- `registration.new(RelyingParty, User, origin)` and `authentication.new(rp_id, origin)` return builders; `build` returns options JSON plus an opaque challenge. Both modules provide `encode_challenge`/`parse_challenge` for persistence and `verify_json` convenience functions. [Registration source](https://github.com/jtdowney/glasskey/blob/main/glasslock/src/glasslock/registration.gleam), [authentication source](https://github.com/jtdowney/glasskey/blob/main/glasslock/src/glasslock/authentication.gleam).
- Registration checks ceremony type, challenge, exact origins, cross-origin policy, RP ID hash, user presence, requested user verification, raw credential ID, public-key algorithm and attestation shape. It only accepts `none` attestation. ES256, Ed25519 and RS256 are supported; the default requested algorithm is ES256. [Registration source](https://github.com/jtdowney/glasskey/blob/main/glasslock/src/glasslock/registration.gleam).
- Authentication checks the same ceremony constraints, stored credential ID, signature, counter progression and user handle. `DiscoveredUser(handle)` requires a matching handle; `AlreadyIdentifiedUser(handle)` permits an absent handle but checks it when present. Zero counters are accepted when both stored/new counters are zero. [Authentication source](https://github.com/jtdowney/glasskey/blob/main/glasslock/src/glasslock/authentication.gleam).
- Internal parsing rejects backup state without backup eligibility and malformed authenticator structures. The returned credential does **not** expose AAGUID, backup eligibility or backup state. Persisted backup-eligibility consistency across ceremonies therefore needs extra work for strict Level 3 completeness. [Internal source](https://github.com/jtdowney/glasskey/blob/main/glasslock/src/glasslock/internal.gleam), [credential type](https://github.com/jtdowney/glasskey/blob/main/glasslock/src/glasslock.gleam).

### Required application responsibilities

These are implementation recommendations inferred from the verifier's API and source:

1. Store challenges server-side with expiry, ceremony purpose, session/account binding, and atomic single-use consumption. The builder's timeout is a browser hint; the serialized challenge itself has no issue/expiry timestamp and verification does not enforce time.
2. Use a database uniqueness constraint for credential IDs across accounts/RP; persist credential public key, counter and transports. Update counters atomically alongside successful challenge completion. The verifier performs no persistence.
3. Require user verification explicitly for passwordless authentication; keep origins/RP configuration server-controlled. Use stable opaque user handles and validate the resolved account before issuing a session.
4. Require recent authentication for enrollment/removal; preserve another usable login method when removing the final passkey. Integrate account deletion and session revocation.
5. Bound request bodies and impose durable account/challenge rate limits. Keep MFA pending credentials distinct from full sessions. Encrypt TOTP secrets using an application-held key and store only hashes of recovery/OTP/trusted-device tokens.

Upstream tests include registration/authentication rejection cases for wrong challenges, origins, RP IDs, missing UV/UP, handles, signatures, malformed fields, counter rollback, backup flag consistency, plus all three supported signature algorithms. These were **read, not executed in this research task**. They do not establish an independent audit. [Tests](https://github.com/jtdowney/glasskey/tree/main/glasslock/test/glasslock).

## Alternatives and build impact

**Wax (`wax_` 0.7.0)** is an older Elixir WebAuthn library, with its latest published release May 18, 2025. It supplies registration/authentication verification and broader attestation support. Dependencies include `asn1_compiler`, `cbor`, `jason` and `x509`. Its functions are callable from Erlang as `'Elixir.Wax'`, with Elixir structs represented as maps. Its documentation explicitly says it has not been independently reviewed by security/FIDO specialists. [Release metadata](https://hex.pm/api/packages/wax_/releases/0.7.0), [source/API](https://github.com/tanguilp/wax/blob/master/lib/wax.ex).

Gleam can build Mix dependencies, but the inspected environment has Erlang/rebar3 and lacks `elixir`/`mix` on PATH. Wax thus needs an additional build/runtime dependency. [Gleam dependency documentation](https://gleam.run/documentation/gleam-toml-reference/).

The Hex package named **`webauthn` 0.0.9 is also Elixir**, not a pure Erlang fallback. Its release dates to June 19, 2024. [Package metadata](https://hex.pm/api/packages/webauthn/releases/0.0.9), [repository](https://github.com/scalpel-software/webauthn).

**SimpleWebAuthn via a Node worker** would reuse Better Auth's verifier ecosystem but require maintaining a process boundary, deployment of Node/packages and structured error handling. It remains a plausible alternative if native dependency maturity is unacceptable; it is not needed merely because Howdy uses Gleam. [Better Auth passkey documentation](https://better-auth.com/docs/plugins/passkey).
