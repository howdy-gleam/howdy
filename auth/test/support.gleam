import gleam/dynamic/decode
import gleam/erlang/process
import gloo/adapter/postgres
import gloo/adapter/sqlite
import gloo/repo.{type Repo}
import howdy
import howdy/auth
import howdy/auth/internal/database as db
import howdy/auth/internal/token
import howdy/auth/pages
import howdy/auth/routes
import howdy/auth/secret
import howdy/authorization as access
import howdy/controller
import howdy/guard
import howdy/migration

@external(erlang, "howdy_auth_test_ffi", "backend")
fn backend() -> String

@external(erlang, "howdy_auth_test_ffi", "delete_file")
fn delete_file(path: String) -> Nil

/// Every case gets its own database on either real adapter.
pub fn with_repo(run: fn(Repo) -> a) -> a {
  case backend() {
    "postgres" -> {
      use config <- with_postgres_database
      let assert Ok(db) = postgres.start(config)
      let value = run(db)
      let assert Ok(_) = repo.close(db)
      value
    }
    "sqlite" -> {
      let db = sqlite_repo(sqlite.memory())
      let value = run(db)
      let assert Ok(_) = repo.close(db)
      value
    }
    _ -> panic as "HOWDY_AUTH_TEST_BACKEND must be sqlite or postgres"
  }
}

pub fn with_independent_repos(run: fn(Repo, Repo) -> a) -> a {
  case backend() {
    "postgres" -> {
      use config <- with_postgres_database
      let assert Ok(first) = postgres.start(config)
      let assert Ok(second) = postgres.start(config)
      let value = run(first, second)
      let assert Ok(_) = repo.close(first)
      let assert Ok(_) = repo.close(second)
      value
    }
    "sqlite" -> {
      let path = "/tmp/howdy-auth-gloo-test-" <> token.new() <> ".sqlite"
      let first = sqlite_repo(sqlite.file(path))
      let second = sqlite_repo(sqlite.file(path))
      let value = run(first, second)
      let assert Ok(_) = repo.close(first)
      let assert Ok(_) = repo.close(second)
      delete_file(path)
      value
    }
    _ -> panic as "HOWDY_AUTH_TEST_BACKEND must be sqlite or postgres"
  }
}

fn sqlite_repo(config: sqlite.Config) -> Repo {
  let assert Ok(db) = sqlite.start(config)
  let assert Ok(_) = repo.execute(db, "PRAGMA foreign_keys = ON", [])
  let assert Ok(_) = repo.execute(db, "PRAGMA busy_timeout = 5000", [])
  db
}

fn with_postgres_database(run: fn(postgres.Config) -> a) -> a {
  let config =
    postgres.default_config()
    |> postgres.user("howdy_auth_test")
    |> postgres.pool_size(2)
  let assert Ok(admin) = postgres.start(config)
  let name = "howdy_auth_test_" <> token.new()
  let assert Ok(_) =
    repo.execute(admin, "CREATE DATABASE \"" <> name <> "\"", [])
  let value = run(config |> postgres.database(name))
  let assert Ok(_) =
    repo.execute(admin, "DROP DATABASE \"" <> name <> "\" WITH (FORCE)", [])
  let assert Ok(_) = repo.close(admin)
  value
}

pub fn fixture(
  run: fn(Repo, auth.Auth, access.Authorization, process.Subject(auth.Delivery)) ->
    a,
) -> a {
  use database <- with_repo
  let assert Ok(Nil) = migration.run(database, [auth.schema(), access.schema()])
  let mailbox = process.new_subject()
  let assert Ok(identity) =
    auth.new(database, "https://example.test", fn(delivery) {
      process.send(mailbox, delivery)
      Ok(Nil)
    })
  let identity = auth.allow_registration(identity)
  let assert Ok(permissions) = access.new(database)
  run(database, identity, permissions, mailbox)
}

pub fn signup(
  identity: auth.Auth,
  mailbox: process.Subject(auth.Delivery),
  email: String,
) {
  let assert Ok(Nil) = auth.request_token(identity, email, auth.Register)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  session
}

pub fn exec(database, sql) {
  let conn = database
  let assert Ok(Nil) = db.exec(conn, sql)
  Nil
}

pub fn count(database, sql) {
  let conn = database
  let assert Ok([n]) =
    repo.all(conn, sql, [], decode.field(0, decode.int, decode.success))
  n
}

/// The application the HTTP suites exercise: the auth API, the starter pages
/// and a controller guarded by them.
pub fn app(identity: auth.Auth, permissions: access.Authorization) {
  let protected =
    controller.guarded("/documents", auth.required(identity))
    |> controller.get("/", fn(ctx) {
      use _ <- guard.require(
        ctx,
        access.require_permission(permissions, "documents.read", access.Global),
      )
      controller.text(ctx, "allowed")
    })
    |> controller.post("/", fn(ctx) { controller.text(ctx, "saved") })
    |> controller.build()
  howdy.new()
  |> howdy.controller(routes.api(identity, at: "/api/auth"))
  |> howdy.controller(pages.routes(identity, at: "/auth", api_at: "/api/auth"))
  |> howdy.controller(protected)
}
