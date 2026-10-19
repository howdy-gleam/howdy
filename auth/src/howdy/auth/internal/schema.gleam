import gloo/migration as gloo_migration
import howdy/migration

pub fn authentication() -> migration.Package {
  migration.Package("howdy_auth", [
    gloo_migration.new(
      1,
      "create_auth",
      "
CREATE TABLE howdy_auth_users (
  id TEXT PRIMARY KEY NOT NULL,
  email TEXT NOT NULL UNIQUE,
  suspended INTEGER NOT NULL DEFAULT 0 CHECK (suspended IN (0, 1))
);
CREATE TABLE howdy_auth_identities (
  issuer TEXT NOT NULL,
  subject TEXT NOT NULL,
  user_id TEXT NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE,
  PRIMARY KEY (issuer, subject)
);
CREATE TABLE howdy_auth_challenges (
  digest TEXT PRIMARY KEY NOT NULL,
  email TEXT NOT NULL,
  intent TEXT NOT NULL CHECK (intent IN ('login', 'register')),
  expires_at BIGINT NOT NULL
);
CREATE INDEX howdy_auth_challenges_expiry ON howdy_auth_challenges(expires_at);
CREATE TABLE howdy_auth_sessions (
  digest TEXT PRIMARY KEY NOT NULL,
  user_id TEXT NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE,
  expires_at BIGINT NOT NULL
);
CREATE INDEX howdy_auth_sessions_user ON howdy_auth_sessions(user_id);
CREATE INDEX howdy_auth_sessions_expiry ON howdy_auth_sessions(expires_at);
CREATE TABLE howdy_auth_throttles (
  key TEXT PRIMARY KEY NOT NULL,
  next_at BIGINT NOT NULL
);
CREATE TABLE howdy_auth_events (
  id TEXT PRIMARY KEY NOT NULL,
  user_id TEXT NOT NULL,
  action TEXT NOT NULL,
  occurred_at BIGINT NOT NULL
);
",
    ),
    gloo_migration.new(
      2,
      "add_password_authentication",
      "
ALTER TABLE howdy_auth_challenges ADD COLUMN password_hash TEXT;
CREATE TABLE howdy_auth_passwords (
  user_id TEXT PRIMARY KEY NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE,
  encoded_hash TEXT NOT NULL
);
CREATE TABLE howdy_auth_password_attempts (
  key TEXT PRIMARY KEY NOT NULL,
  window_start BIGINT NOT NULL,
  attempts INTEGER NOT NULL
);
",
    ),
    // Existing sessions predate the new columns: treat them as created one
    // default lifetime before they expire, so none counts as freshly issued.
    gloo_migration.new(
      3,
      "add_session_metadata_backoff_audit_detail_and_indexes",
      "
ALTER TABLE howdy_auth_sessions ADD COLUMN created_at BIGINT NOT NULL DEFAULT 0;
ALTER TABLE howdy_auth_sessions ADD COLUMN last_seen_at BIGINT NOT NULL DEFAULT 0;
ALTER TABLE howdy_auth_sessions ADD COLUMN method TEXT NOT NULL DEFAULT 'email' CHECK (method IN ('email', 'password'));
UPDATE howdy_auth_sessions SET created_at = expires_at - 86400, last_seen_at = expires_at - 86400;
ALTER TABLE howdy_auth_challenges ADD COLUMN created_at BIGINT NOT NULL DEFAULT 0;
CREATE INDEX howdy_auth_challenges_email ON howdy_auth_challenges(email);
ALTER TABLE howdy_auth_throttles ADD COLUMN strikes INTEGER NOT NULL DEFAULT 0;
CREATE INDEX howdy_auth_throttles_next ON howdy_auth_throttles(next_at);
CREATE INDEX howdy_auth_password_attempts_window ON howdy_auth_password_attempts(window_start);
CREATE INDEX howdy_auth_identities_user ON howdy_auth_identities(user_id);
ALTER TABLE howdy_auth_events ADD COLUMN actor_id TEXT NOT NULL DEFAULT '';
ALTER TABLE howdy_auth_events ADD COLUMN detail TEXT NOT NULL DEFAULT '';
CREATE INDEX howdy_auth_events_user ON howdy_auth_events(user_id, occurred_at);
CREATE INDEX howdy_auth_events_time ON howdy_auth_events(occurred_at);
",
    ),
    gloo_migration.new(
      4,
      "password_client_backoff",
      "
CREATE TABLE howdy_auth_password_clients (
 key TEXT PRIMARY KEY NOT NULL,
 email_key TEXT NOT NULL,
 failures INTEGER NOT NULL,
 next_at BIGINT NOT NULL,
 expires_at BIGINT NOT NULL
);
CREATE INDEX howdy_auth_password_clients_expiry ON howdy_auth_password_clients(expires_at);
CREATE INDEX howdy_auth_password_clients_email ON howdy_auth_password_clients(email_key);
",
    ),
    gloo_migration.new(
      5,
      "track_password_normalization",
      "
ALTER TABLE howdy_auth_passwords ADD COLUMN normalized INTEGER NOT NULL DEFAULT 0 CHECK (normalized IN (0, 1));
ALTER TABLE howdy_auth_challenges ADD COLUMN password_normalized INTEGER NOT NULL DEFAULT 0 CHECK (password_normalized IN (0, 1));
",
    ),
    gloo_migration.new(
      6,
      "record_request_client_and_throttle_key",
      "
ALTER TABLE howdy_auth_events ADD COLUMN client TEXT NOT NULL DEFAULT '';
ALTER TABLE howdy_auth_sessions ADD COLUMN client TEXT NOT NULL DEFAULT '';
CREATE TABLE howdy_auth_keys (
  name TEXT PRIMARY KEY NOT NULL,
  secret TEXT NOT NULL
);
DROP INDEX howdy_auth_challenges_email;
CREATE INDEX howdy_auth_challenges_email_expiry ON howdy_auth_challenges(email, expires_at);
",
    ),
    // The unique column becomes the login key so uniqueness can be per address
    // or per address and group; see `group.login_key`. Renaming rather than
    // rebuilding keeps every row that references a user.
    gloo_migration.new(
      7,
      "add_groups",
      "
CREATE TABLE howdy_auth_groups (
  id TEXT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL
);
INSERT INTO howdy_auth_groups(id, name) VALUES ('default', 'Default');
ALTER TABLE howdy_auth_users RENAME COLUMN email TO login_key;
ALTER TABLE howdy_auth_users ADD COLUMN email TEXT NOT NULL DEFAULT '';
ALTER TABLE howdy_auth_users ADD COLUMN group_id TEXT REFERENCES howdy_auth_groups(id);
UPDATE howdy_auth_users SET email = login_key, group_id = 'default';
CREATE INDEX howdy_auth_users_email ON howdy_auth_users(email);
CREATE INDEX howdy_auth_users_group ON howdy_auth_users(group_id);
ALTER TABLE howdy_auth_challenges ADD COLUMN group_id TEXT REFERENCES howdy_auth_groups(id) ON DELETE CASCADE;
CREATE TABLE howdy_auth_settings (
  name TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
);
",
    ),
    // PostgreSQL has a type for an instant and SQLite does not, so the columns
    // differ; see `database.read_time`. Creation is recovered from the audit
    // trail, and is the epoch where that has been pruned. The default group
    // has no event, so it dates from this migration.
    gloo_migration.new(8, "add_timestamps_and_fields", "
CREATE TABLE howdy_auth_user_fields (
  user_id TEXT NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  value TEXT NOT NULL,
  unique_key TEXT,
  PRIMARY KEY (user_id, name)
);
CREATE UNIQUE INDEX howdy_auth_user_fields_unique ON howdy_auth_user_fields(name, unique_key);
CREATE INDEX howdy_auth_user_fields_value ON howdy_auth_user_fields(name, value);
CREATE TABLE howdy_auth_group_fields (
  group_id TEXT NOT NULL REFERENCES howdy_auth_groups(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  value TEXT NOT NULL,
  unique_key TEXT,
  PRIMARY KEY (group_id, name)
);
CREATE UNIQUE INDEX howdy_auth_group_fields_unique ON howdy_auth_group_fields(name, unique_key);
CREATE INDEX howdy_auth_group_fields_value ON howdy_auth_group_fields(name, value);
" <> migration.per_database(
      postgres: "
ALTER TABLE howdy_auth_users ADD COLUMN created_at TIMESTAMPTZ NOT NULL DEFAULT to_timestamp(0);
ALTER TABLE howdy_auth_users ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT to_timestamp(0);
ALTER TABLE howdy_auth_groups ADD COLUMN created_at TIMESTAMPTZ NOT NULL DEFAULT to_timestamp(0);
ALTER TABLE howdy_auth_groups ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT to_timestamp(0);
UPDATE howdy_auth_users SET created_at = to_timestamp(COALESCE((SELECT MIN(e.occurred_at) FROM howdy_auth_events e WHERE e.user_id = howdy_auth_users.id AND e.action IN ('user.registered', 'user.provisioned')), 0));
UPDATE howdy_auth_groups SET created_at = to_timestamp(COALESCE((SELECT MIN(e.occurred_at) FROM howdy_auth_events e WHERE e.action = 'group.created' AND e.detail = howdy_auth_groups.id), 0));
UPDATE howdy_auth_groups SET created_at = CURRENT_TIMESTAMP WHERE id = 'default' AND created_at = to_timestamp(0);
UPDATE howdy_auth_users SET updated_at = created_at;
UPDATE howdy_auth_groups SET updated_at = created_at;
",
      sqlite: "
ALTER TABLE howdy_auth_users ADD COLUMN created_at BIGINT NOT NULL DEFAULT 0;
ALTER TABLE howdy_auth_users ADD COLUMN updated_at BIGINT NOT NULL DEFAULT 0;
ALTER TABLE howdy_auth_groups ADD COLUMN created_at BIGINT NOT NULL DEFAULT 0;
ALTER TABLE howdy_auth_groups ADD COLUMN updated_at BIGINT NOT NULL DEFAULT 0;
UPDATE howdy_auth_users SET created_at = COALESCE((SELECT MIN(e.occurred_at) FROM howdy_auth_events e WHERE e.user_id = howdy_auth_users.id AND e.action IN ('user.registered', 'user.provisioned')), 0);
UPDATE howdy_auth_groups SET created_at = COALESCE((SELECT MIN(e.occurred_at) FROM howdy_auth_events e WHERE e.action = 'group.created' AND e.detail = howdy_auth_groups.id), 0);
UPDATE howdy_auth_groups SET created_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = 'default' AND created_at = 0;
UPDATE howdy_auth_users SET updated_at = created_at;
UPDATE howdy_auth_groups SET updated_at = created_at;
",
    )),
    // SQLite cannot change a column CHECK. Keep the old column as unused
    // migration metadata rather than rebuilding sessions and dropping indexes
    // or cascading deletes to application tables. New writes use `method`.
    gloo_migration.new(9, "add_identity_providers", "
CREATE TABLE howdy_auth_provider_identities (
  issuer TEXT NOT NULL,
  subject TEXT NOT NULL,
  scope TEXT NOT NULL,
  user_id TEXT NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE,
  PRIMARY KEY (issuer, subject, scope),
  UNIQUE (issuer, user_id)
);
CREATE INDEX howdy_auth_provider_identities_user ON howdy_auth_provider_identities(user_id);
CREATE TABLE howdy_auth_provider_attempts (
  digest TEXT PRIMARY KEY NOT NULL,
  browser_digest TEXT NOT NULL,
  provider TEXT NOT NULL,
  nonce_digest TEXT NOT NULL,
  verifier TEXT NOT NULL,
  redirect_uri TEXT NOT NULL,
  group_id TEXT REFERENCES howdy_auth_groups(id) ON DELETE CASCADE,
  mode TEXT NOT NULL,
  expires_at BIGINT NOT NULL,
  link_user TEXT NOT NULL DEFAULT '',
  link_session TEXT NOT NULL DEFAULT '',
  client TEXT NOT NULL DEFAULT ''
);
CREATE INDEX howdy_auth_provider_attempts_expiry ON howdy_auth_provider_attempts(expires_at);
" <> migration.per_database(
      postgres: "
ALTER TABLE howdy_auth_sessions DROP CONSTRAINT howdy_auth_sessions_method_check;
ALTER TABLE howdy_auth_sessions ADD CONSTRAINT howdy_auth_sessions_method_check CHECK (method IN ('email', 'password') OR method LIKE 'provider:%');
",
      sqlite: "
ALTER TABLE howdy_auth_sessions RENAME COLUMN method TO legacy_method;
ALTER TABLE howdy_auth_sessions ADD COLUMN method TEXT NOT NULL DEFAULT 'email' CHECK (method IN ('email', 'password') OR method LIKE 'provider:%');
UPDATE howdy_auth_sessions SET method = legacy_method;
",
    )),
    gloo_migration.new(
      10,
      "add_account_management",
      "
ALTER TABLE howdy_auth_users ADD COLUMN session_version BIGINT NOT NULL DEFAULT 0;
ALTER TABLE howdy_auth_provider_identities ADD COLUMN provider TEXT NOT NULL DEFAULT 'google';
CREATE TABLE howdy_auth_email_changes (
  digest TEXT PRIMARY KEY NOT NULL,
  user_id TEXT NOT NULL UNIQUE REFERENCES howdy_auth_users(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL,
  old_email TEXT NOT NULL,
  new_email TEXT NOT NULL,
  group_id TEXT NOT NULL,
  mode TEXT NOT NULL,
  expires_at BIGINT NOT NULL
);
CREATE INDEX howdy_auth_email_changes_expiry ON howdy_auth_email_changes(expires_at);
",
    ),
    gloo_migration.new(11, "add_passkeys_and_mfa", "
CREATE TABLE howdy_auth_passkeys (
  id TEXT PRIMARY KEY NOT NULL,
  user_id TEXT NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  public_key TEXT NOT NULL,
  sign_count BIGINT NOT NULL,
  transports TEXT NOT NULL,
  backup_eligible INTEGER NOT NULL,
  backed_up INTEGER NOT NULL,
  aaguid TEXT NOT NULL,
  created_at BIGINT NOT NULL
);
CREATE INDEX howdy_auth_passkeys_user ON howdy_auth_passkeys(user_id);
CREATE TABLE howdy_auth_ceremonies (
  digest TEXT PRIMARY KEY NOT NULL,
  kind TEXT NOT NULL,
  user_id TEXT REFERENCES howdy_auth_users(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL,
  group_id TEXT NOT NULL,
  version BIGINT NOT NULL,
  payload TEXT NOT NULL,
  label TEXT NOT NULL,
  expires_at BIGINT NOT NULL
);
CREATE INDEX howdy_auth_ceremonies_expiry ON howdy_auth_ceremonies(expires_at);
CREATE INDEX howdy_auth_ceremonies_user ON howdy_auth_ceremonies(user_id);
CREATE TABLE howdy_auth_mfa (
  user_id TEXT PRIMARY KEY NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE,
  method TEXT NOT NULL CHECK (method IN ('totp', 'otp')),
  secret TEXT NOT NULL,
  last_step BIGINT NOT NULL
);
CREATE TABLE howdy_auth_recovery_codes (
  digest TEXT PRIMARY KEY NOT NULL,
  user_id TEXT NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE
);
CREATE INDEX howdy_auth_recovery_codes_user ON howdy_auth_recovery_codes(user_id);
CREATE TABLE howdy_auth_mfa_pending (
  digest TEXT PRIMARY KEY NOT NULL,
  user_id TEXT NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE,
  version BIGINT NOT NULL,
  group_id TEXT NOT NULL,
  method TEXT NOT NULL,
  client TEXT NOT NULL,
  otp_digest TEXT NOT NULL DEFAULT '',
  otp_sent_at BIGINT NOT NULL DEFAULT 0,
  expires_at BIGINT NOT NULL
);
CREATE INDEX howdy_auth_mfa_pending_expiry ON howdy_auth_mfa_pending(expires_at);
CREATE INDEX howdy_auth_mfa_pending_user ON howdy_auth_mfa_pending(user_id);
CREATE TABLE howdy_auth_security_attempts (
  user_id TEXT PRIMARY KEY NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE,
  window_start BIGINT NOT NULL,
  attempts INTEGER NOT NULL
);
CREATE TABLE howdy_auth_trusted_devices (
  digest TEXT PRIMARY KEY NOT NULL,
  user_id TEXT NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE,
  version BIGINT NOT NULL,
  created_at BIGINT NOT NULL,
  expires_at BIGINT NOT NULL
);
CREATE INDEX howdy_auth_trusted_devices_user ON howdy_auth_trusted_devices(user_id);
" <> migration.per_database(
      postgres: "
ALTER TABLE howdy_auth_sessions DROP CONSTRAINT howdy_auth_sessions_method_check;
ALTER TABLE howdy_auth_sessions ADD CONSTRAINT howdy_auth_sessions_method_check CHECK (method IN ('email', 'password', 'passkey') OR method LIKE 'provider:%' OR method LIKE 'mfa:%');
",
      sqlite: "
ALTER TABLE howdy_auth_sessions RENAME COLUMN method TO pre_mfa_method;
ALTER TABLE howdy_auth_sessions ADD COLUMN method TEXT NOT NULL DEFAULT 'email' CHECK (method IN ('email', 'password', 'passkey') OR method LIKE 'provider:%' OR method LIKE 'mfa:%');
UPDATE howdy_auth_sessions SET method = pre_mfa_method;
",
    )),
    // `config` is sealed with the application's SSO key: it holds the OIDC
    // client secret. A domain routes to at most one connection installation
    // wide, so an address can never be claimed by two customers' IdPs.
    gloo_migration.new(
      12,
      "add_sso_connections",
      "
CREATE TABLE howdy_auth_sso_connections (
  id TEXT PRIMARY KEY NOT NULL,
  group_id TEXT NOT NULL REFERENCES howdy_auth_groups(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('oidc', 'saml')),
  name TEXT NOT NULL,
  config TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL
);
CREATE INDEX howdy_auth_sso_connections_group ON howdy_auth_sso_connections(group_id);
CREATE TABLE howdy_auth_sso_domains (
  domain TEXT PRIMARY KEY NOT NULL,
  connection_id TEXT NOT NULL REFERENCES howdy_auth_sso_connections(id) ON DELETE CASCADE
);
CREATE INDEX howdy_auth_sso_domains_connection ON howdy_auth_sso_domains(connection_id);
",
    ),
    gloo_migration.new(
      13,
      "add_sso_enforcement",
      "
ALTER TABLE howdy_auth_sso_connections ADD COLUMN enforced INTEGER NOT NULL DEFAULT 0;
",
    ),
    gloo_migration.new(
      14,
      "add_sso_provider_mfa_trust",
      "
ALTER TABLE howdy_auth_sso_connections ADD COLUMN trusts_mfa INTEGER NOT NULL DEFAULT 0;
",
    ),
    gloo_migration.new(
      15,
      "add_passkey_registration",
      "
ALTER TABLE howdy_auth_challenges ADD COLUMN passkey TEXT;
",
    ),
    // A short code emailed beside the token. Only its keyed digest is kept,
    // and it stops working (NULL) after `code_attempts` wrong guesses.
    gloo_migration.new(
      16,
      "add_email_codes",
      "
ALTER TABLE howdy_auth_challenges ADD COLUMN code_digest TEXT;
ALTER TABLE howdy_auth_challenges ADD COLUMN code_attempts INTEGER NOT NULL DEFAULT 0;
",
    ),
    // Per-client request counts every node shares, with
    // `auth.with_shared_rate_limits`. One row per limiter and client: `key` is
    // a digest, so client addresses are not stored.
    gloo_migration.new(
      17,
      "add_shared_rate_limits",
      "
CREATE TABLE howdy_auth_rate_limits (
  key TEXT PRIMARY KEY NOT NULL,
  window_start BIGINT NOT NULL,
  hits INTEGER NOT NULL,
  expires_at BIGINT NOT NULL
);
CREATE INDEX howdy_auth_rate_limits_expiry ON howdy_auth_rate_limits(expires_at);
",
    ),
    // `auth.impersonate` records sessions an operator issued without a
    // credential, so they are distinguishable from the user's own.
    gloo_migration.new(
      18,
      "allow_impersonation_sessions",
      migration.per_database(
        postgres: "
ALTER TABLE howdy_auth_sessions DROP CONSTRAINT howdy_auth_sessions_method_check;
ALTER TABLE howdy_auth_sessions ADD CONSTRAINT howdy_auth_sessions_method_check CHECK (method IN ('email', 'password', 'passkey', 'impersonation') OR method LIKE 'provider:%' OR method LIKE 'mfa:%');
",
        sqlite: "
ALTER TABLE howdy_auth_sessions RENAME COLUMN method TO pre_impersonation_method;
ALTER TABLE howdy_auth_sessions ADD COLUMN method TEXT NOT NULL DEFAULT 'email' CHECK (method IN ('email', 'password', 'passkey', 'impersonation') OR method LIKE 'provider:%' OR method LIKE 'mfa:%');
UPDATE howdy_auth_sessions SET method = pre_impersonation_method;
",
      ),
    ),
    // The locale pages and emails use for a user: the one the request that
    // registered them asked for, or one they chose. NULL for users who
    // predate it, who get whatever their requests ask for.
    gloo_migration.new(
      19,
      "add_user_locale",
      "
ALTER TABLE howdy_auth_users ADD COLUMN locale TEXT;
",
    ),
  ])
}

pub fn authorization() -> migration.Package {
  migration.Package("howdy_authz", [
    gloo_migration.new(
      1,
      "create_authz",
      "
CREATE TABLE howdy_authz_roles (
  scope TEXT NOT NULL,
  name TEXT NOT NULL,
  PRIMARY KEY (scope, name)
);
CREATE TABLE howdy_authz_permissions (
  scope TEXT NOT NULL,
  role TEXT NOT NULL,
  permission TEXT NOT NULL,
  PRIMARY KEY (scope, role, permission),
  FOREIGN KEY (scope, role) REFERENCES howdy_authz_roles(scope, name) ON DELETE CASCADE
);
CREATE TABLE howdy_authz_assignments (
  user_id TEXT NOT NULL REFERENCES howdy_auth_users(id) ON DELETE CASCADE,
  scope TEXT NOT NULL,
  role TEXT NOT NULL,
  PRIMARY KEY (user_id, scope, role),
  FOREIGN KEY (scope, role) REFERENCES howdy_authz_roles(scope, name) ON DELETE CASCADE
);
",
    ),
    gloo_migration.new(
      2,
      "index_assignments_by_role",
      "
CREATE INDEX howdy_authz_assignments_role ON howdy_authz_assignments(scope, role);
",
    ),
  ])
}
