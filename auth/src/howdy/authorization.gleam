//// Role-based authorization, independent of login methods and HTTP transport.
//// Grants apply only to their exact scope. Global grants do not imply access
//// to organizations. No role name has implicit privileges or wildcard powers.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gloo/repo.{type Repo}
import gloo/sql
import howdy/auth
import howdy/auth/internal/cache
import howdy/auth/internal/database as db
import howdy/auth/internal/schema
import howdy/auth/internal/store
import howdy/auth/user.{type Actor, type Principal}
import howdy/context.{type Context}
import howdy/migration
import howdy/service

pub type Scope {
  Global
  Organization(String)
}

pub opaque type Authorization {
  Authorization(repo: Repo, cache: Option(#(cache.Cache, Int)))
}

pub fn schema() -> migration.Package {
  schema.authorization()
}

pub fn new(repo: Repo) -> service.Result(Authorization) {
  use _ <- result.try(migration.check(repo, auth.schema()))
  use _ <- result.try(migration.check(repo, schema()))
  Ok(Authorization(repo, None))
}

/// Opt into at most `seconds` (1–60) of stale authorization on changes made
/// from other BEAM nodes or direct SQL. Local grant/suspension changes invalidate all
/// caches. Construct once at application startup; authenticate every request
/// before consulting authorization. The default always reads the database.
pub fn with_cache(
  access: Authorization,
  seconds seconds: Int,
) -> service.Result(Authorization) {
  case seconds >= 1 && seconds <= 60 {
    True -> Ok(Authorization(..access, cache: Some(#(cache.new(), seconds))))
    False ->
      Error(service.Invalid(
        "authorization cache lifetime must be 1 to 60 seconds",
      ))
  }
}

/// Wrap application-owned grant data changes, or a transaction opened directly
/// through `gloo/repo` or pog, so invalidation happens after its actual
/// commit/rollback, not a savepoint. Transactions opened with `howdy/database`
/// or `howdy/database/postgres` need no wrapper. Cached decisions are bypassed
/// inside the callback. Without this wrapper, direct SQL/external transactions
/// have the same bounded TTL as remote nodes.
pub fn with_changes(run: fn() -> a) -> a {
  // The flag it sets is process-local: `run` must do its writing in this
  // process, not in one it spawns (see `cache.changing`).
  cache.changing(run)
}

/// Define or replace a role's permissions atomically. This is a privileged
/// management operation, not a public endpoint. Existing assignments remain.
pub fn define_role(
  access: Authorization,
  scope: Scope,
  name: String,
  permissions: List(String),
  by actor: Actor,
) -> service.Result(Nil) {
  use scope <- result.try(scope_key(scope))
  use _ <- result.try(valid_names([name, ..permissions]))
  // Runs in the process holding the transaction: the dirty flag is
  // process-local (see `cache.changing`).
  use <- cache.changing
  use conn <- db.transaction(access.repo)
  use _ <- result.try(
    db.execute(
      conn,
      "INSERT INTO howdy_authz_roles(scope, name) VALUES ($1, $2) ON CONFLICT DO NOTHING",
      [sql.string(scope), sql.string(name)],
    ),
  )
  use _ <- result.try(
    db.execute(
      conn,
      "DELETE FROM howdy_authz_permissions WHERE scope = $1 AND role = $2",
      [sql.string(scope), sql.string(name)],
    ),
  )
  use _ <- result.try(store.insert_permissions(
    conn,
    scope,
    name,
    list.unique(permissions),
  ))
  auth.event(conn, "", "role.defined", actor, scope <> ":" <> name)
}

/// Assign an existing role to an existing user in exactly this scope.
/// Privileged: the application must authorize the caller first.
pub fn assign(
  access: Authorization,
  user_id: String,
  role: String,
  scope: Scope,
  by actor: Actor,
) -> service.Result(Nil) {
  use scope <- result.try(scope_key(scope))
  // Runs in the process holding the transaction: the dirty flag is
  // process-local (see `cache.changing`).
  use <- cache.changing
  use conn <- db.write_transaction(access.repo, touching: "howdy_auth_users")
  use _ <- result.try(store.require_user(conn, user_id))
  use roles <- result.try(db.query(
    conn,
    "SELECT r.name FROM howdy_authz_roles r WHERE r.scope = $1 AND r.name = $2"
      <> db.for_update(conn, "r"),
    [sql.string(scope), sql.string(role)],
    decode.field(0, decode.string, decode.success),
  ))
  use _ <- result.try(case roles {
    [_] -> Ok(Nil)
    _ -> Error(service.NotFound("role"))
  })
  use _ <- result.try(
    db.execute(
      conn,
      "INSERT INTO howdy_authz_assignments(user_id, scope, role) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING",
      [sql.string(user_id), sql.string(scope), sql.string(role)],
    ),
  )
  auth.event(conn, user_id, "role.assigned", actor, scope <> ":" <> role)
}

/// Revoke a role immediately. Privileged: authorize the caller first.
pub fn revoke(
  access: Authorization,
  user_id: String,
  role: String,
  scope: Scope,
  by actor: Actor,
) -> service.Result(Nil) {
  use scope <- result.try(scope_key(scope))
  // Runs in the process holding the transaction: the dirty flag is
  // process-local (see `cache.changing`).
  use <- cache.changing
  use conn <- db.write_transaction(access.repo, touching: "howdy_auth_users")
  use _ <- result.try(store.require_user(conn, user_id))
  use roles <- result.try(db.query(
    conn,
    "SELECT r.name FROM howdy_authz_roles r WHERE r.scope = $1 AND r.name = $2"
      <> db.for_update(conn, "r"),
    [sql.string(scope), sql.string(role)],
    decode.field(0, decode.string, decode.success),
  ))
  use _ <- result.try(case roles {
    [_] -> Ok(Nil)
    _ -> Error(service.NotFound("role"))
  })
  use _ <- result.try(
    db.execute(
      conn,
      "DELETE FROM howdy_authz_assignments WHERE user_id = $1 AND scope = $2 AND role = $3",
      [sql.string(user_id), sql.string(scope), sql.string(role)],
    ),
  )
  auth.event(conn, user_id, "role.revoked", actor, scope <> ":" <> role)
}

/// A defined role and its permissions.
pub type Role {
  Role(scope: Scope, name: String, permissions: List(String))
}

/// Every defined role in every scope, with its permissions, for management
/// consoles. Roles come sorted by scope then name.
pub fn roles(access: Authorization) -> service.Result(List(Role)) {
  use conn <- db.connect(access.repo)
  use rows <- result.try(
    db.query(
      conn,
      "SELECT r.scope, r.name, p.permission FROM howdy_authz_roles r LEFT JOIN howdy_authz_permissions p ON p.scope = r.scope AND p.role = r.name ORDER BY r.scope, r.name, p.permission",
      [],
      {
        use scope <- decode.field(0, decode.string)
        use name <- decode.field(1, decode.string)
        use permission <- decode.field(2, decode.optional(decode.string))
        decode.success(#(scope, name, permission))
      },
    ),
  )
  rows
  |> list.chunk(fn(row) { #(row.0, row.1) })
  |> list.try_map(fn(group) {
    let assert [#(scope, name, _), ..] = group
    use scope <- result.try(scope_from_key(scope))
    Ok(Role(
      scope:,
      name:,
      permissions: list.filter_map(group, fn(row) {
        option.to_result(row.2, Nil)
      }),
    ))
  })
}

/// Remove a role and every assignment of it. Privileged: authorize the
/// caller first. `NotFound` when there is no such role.
pub fn delete_role(
  access: Authorization,
  scope: Scope,
  name: String,
  by actor: Actor,
) -> service.Result(Nil) {
  use scope <- result.try(scope_key(scope))
  // Runs in the process holding the transaction: the dirty flag is
  // process-local (see `cache.changing`).
  use <- cache.changing
  use conn <- db.transaction(access.repo)
  use roles <- result.try(db.query(
    conn,
    "SELECT name FROM howdy_authz_roles WHERE scope = $1 AND name = $2",
    [sql.string(scope), sql.string(name)],
    decode.field(0, decode.string, decode.success),
  ))
  use _ <- result.try(case roles {
    [_] -> Ok(Nil)
    _ -> Error(service.NotFound("role"))
  })
  use _ <- result.try(
    db.execute(
      conn,
      "DELETE FROM howdy_authz_assignments WHERE scope = $1 AND role = $2",
      [sql.string(scope), sql.string(name)],
    ),
  )
  use _ <- result.try(
    db.execute(
      conn,
      "DELETE FROM howdy_authz_permissions WHERE scope = $1 AND role = $2",
      [sql.string(scope), sql.string(name)],
    ),
  )
  use _ <- result.try(
    db.execute(
      conn,
      "DELETE FROM howdy_authz_roles WHERE scope = $1 AND name = $2",
      [sql.string(scope), sql.string(name)],
    ),
  )
  auth.event(conn, "", "role.deleted", actor, scope <> ":" <> name)
}

/// The roles a user holds, as scope and role name, for management consoles.
/// Suspension does not remove assignments; checks ignore them while it lasts.
pub fn assignments(
  access: Authorization,
  user_id: String,
) -> service.Result(List(#(Scope, String))) {
  use conn <- db.connect(access.repo)
  use rows <- result.try(
    db.query(
      conn,
      "SELECT scope, role FROM howdy_authz_assignments WHERE user_id = $1 ORDER BY scope, role",
      [sql.string(user_id)],
      {
        use scope <- decode.field(0, decode.string)
        use role <- decode.field(1, decode.string)
        decode.success(#(scope, role))
      },
    ),
  )
  list.try_map(rows, fn(row) {
    use scope <- result.try(scope_from_key(row.0))
    Ok(#(scope, row.1))
  })
}

/// The ids of the users assigned a role, for management consoles.
pub fn holders(
  access: Authorization,
  scope: Scope,
  role: String,
) -> service.Result(List(String)) {
  use scope <- result.try(scope_key(scope))
  use conn <- db.connect(access.repo)
  db.query(
    conn,
    "SELECT a.user_id FROM howdy_authz_assignments a JOIN howdy_auth_users u ON u.id = a.user_id WHERE a.scope = $1 AND a.role = $2 ORDER BY u.email, u.id",
    [sql.string(scope), sql.string(role)],
    decode.field(0, decode.string, decode.success),
  )
}

/// The text a scope is stored and displayed as: `global`, or `org:<id>`.
pub fn scope_to_string(scope: Scope) -> String {
  case scope {
    Global -> "global"
    Organization(id) -> "org:" <> id
  }
}

/// Parse what `scope_to_string` produced.
pub fn scope_from_string(text: String) -> Result(Scope, Nil) {
  case text {
    "global" -> Ok(Global)
    "org:" <> id if id != "" -> Ok(Organization(id))
    _ -> Error(Nil)
  }
}

fn scope_from_key(key: String) -> service.Result(Scope) {
  scope_from_string(key)
  |> result.replace_error(service.Internal("unknown authorization scope"))
}

/// Simple role check. The principal must come from authentication.
pub fn has_role(
  access: Authorization,
  principal: Principal,
  role: String,
  scope: Scope,
) -> service.Result(Bool) {
  check(access, principal, RoleGrant(role), scope)
}

/// RBAC permission check. Any currently assigned role may grant a permission.
/// Unknown permissions and scopes deny access; database errors remain errors.
pub fn allowed(
  access: Authorization,
  principal: Principal,
  permission: String,
  scope: Scope,
) -> service.Result(Bool) {
  check(access, principal, Permission(permission), scope)
}

type Grant {
  RoleGrant(String)
  Permission(String)
}

fn check(
  access: Authorization,
  principal: Principal,
  grant: Grant,
  scope: Scope,
) -> service.Result(Bool) {
  use scope <- result.try(scope_key(scope))
  let #(statement, name, kind) = case grant {
    Permission(name) -> #(
      "SELECT 1 FROM howdy_authz_assignments a JOIN howdy_authz_permissions p ON p.scope = a.scope AND p.role = a.role JOIN howdy_auth_users u ON u.id = a.user_id WHERE a.user_id = $1 AND a.scope = $2 AND p.permission = $3 AND u.suspended = 0 LIMIT 1",
      name,
      "permission",
    )
    RoleGrant(name) -> #(
      "SELECT 1 FROM howdy_authz_assignments a JOIN howdy_auth_users u ON u.id = a.user_id WHERE a.user_id = $1 AND a.scope = $2 AND a.role = $3 AND u.suspended = 0 LIMIT 1",
      name,
      "role",
    )
  }
  let load = fn() {
    use conn <- db.connect(access.repo)
    use rows <- result.try(db.query(
      conn,
      statement,
      [sql.string(principal.user.id), sql.string(scope), sql.string(name)],
      decode.field(0, decode.int, decode.success),
    ))
    Ok(rows != [])
  }
  case access.cache {
    None -> load()
    Some(#(memo, seconds)) ->
      cache.run(
        memo,
        #(principal.user.id, principal.session_id, scope, kind, name),
        seconds,
        load,
      )
  }
}

/// Use with guard.require after auth.required. Use a resource's validated
/// organization ID for scope, not an unverified client-provided tenant header.
pub fn require_permission(
  access: Authorization,
  permission: String,
  scope: Scope,
) -> fn(Context(Principal)) -> service.Result(Nil) {
  fn(ctx: Context(Principal)) {
    enforce(allowed(access, ctx.guard, permission, scope))
  }
}

pub fn require_role(
  access: Authorization,
  role: String,
  scope: Scope,
) -> fn(Context(Principal)) -> service.Result(Nil) {
  fn(ctx: Context(Principal)) {
    enforce(has_role(access, ctx.guard, role, scope))
  }
}

fn enforce(decision: service.Result(Bool)) -> service.Result(Nil) {
  use allowed <- result.try(decision)
  case allowed {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  }
}

fn scope_key(scope: Scope) -> service.Result(String) {
  case scope {
    Global -> Ok("global")
    Organization(id) -> {
      use _ <- result.try(valid_names([id]))
      Ok("org:" <> id)
    }
  }
}

fn valid_names(names: List(String)) -> service.Result(Nil) {
  case
    list.all(names, fn(name) {
      string.trim(name) == name && name != "" && string.byte_size(name) <= 200
    })
  {
    True -> Ok(Nil)
    False ->
      Error(service.Invalid(
        "role, permission and organization names must be nonempty and at most 200 bytes",
      ))
  }
}
