//// Open a PostgreSQL Repo with production defaults: configuration from a
//// connection URL, TLS unless the server is local, UTC and session timeouts
//// on every connection, and a start that waits for the server and fails
//// clearly instead of leaving every later query to fail. The result is an
//// ordinary Gloo Repo, so an application that builds its own pool loses
//// nothing and can keep doing so.
////
//// Code that queries pog directly, such as Squirrel's generated functions,
//// can share the pool and its transactions: see `start_pool` and
//// `transaction`.
////
//// ```gleam
//// let assert Ok(db) =
////   postgres.from_env()
////   |> result.map(postgres.pool_size(_, 20))
////   |> result.try(postgres.start)
//// ```
////
//// `start` links the pool to the calling process. In an app, put it under
//// the supervisor with `supervised` instead, so a pool that crashes is
//// restarted rather than taking the caller with it.
////
//// `listen` hears `NOTIFY` on a channel, from this node or any other, and
//// `notify` sends one.

import gleam/bool
import gleam/dynamic/decode
import gleam/erlang/process.{type Name, type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleam/uri
import gloo/adapter.{Adapter, PgConnection}
import gloo/repo.{type Repo}
import gloo/telemetry
import howdy/database
import howdy/env
import howdy/service
import howdy/trace
import howdy/url
import pog

/// The oldest PostgreSQL major version still supported upstream.
pub const minimum_version = 14

pub type Ssl {
  /// Unencrypted. Only for a server on the same host or a private network.
  SslDisabled
  /// Encrypted without checking the server's certificate. Protects against
  /// eavesdropping but not impersonation.
  SslUnverified
  /// Encrypted, with the certificate checked against the system's CAs and
  /// the host name.
  SslVerified
}

pub type Error {
  /// The environment variable is unset or empty.
  MissingUrl(variable: String)
  /// The URL is not `postgres://user:password@host:port/database`. It is not
  /// repeated here because it may contain a password.
  InvalidUrl
  /// An `sslmode` other than `disable`, `require`, `verify-ca` or
  /// `verify-full`. There is no fallback to plain text, so `allow` and
  /// `prefer` are refused.
  UnsupportedSslMode(mode: String)
  StartFailed
  /// No query succeeded before the startup timeout: the server is down or
  /// unreachable, refused the credentials, or the database does not exist.
  Unreachable
  UnsupportedVersion(found: Int, minimum: Int)
}

pub fn error_to_string(error: Error) -> String {
  case error {
    MissingUrl(variable) -> variable <> " is not set"
    InvalidUrl -> "the connection URL is not postgres://user:password@host/db"
    UnsupportedSslMode(mode) -> "sslmode " <> mode <> " is not supported"
    StartFailed -> "the connection pool did not start"
    Unreachable -> "no PostgreSQL server answered within the startup timeout"
    UnsupportedVersion(found, minimum) ->
      "PostgreSQL "
      <> int.to_string(found)
      <> " is older than the supported minimum, "
      <> int.to_string(minimum)
  }
}

pub opaque type Config {
  Config(
    host: String,
    port: Int,
    database: String,
    user: String,
    password: Option(String),
    ssl: Ssl,
    pool_size: Int,
    parameters: List(#(String, String)),
    startup_timeout: Int,
  )
}

@external(erlang, "howdy_database_ffi", "monotonic_ms")
fn now() -> Int

/// Read the connection URL from `DATABASE_URL`, as most hosts provide it.
pub fn from_env() -> Result(Config, Error) {
  case env.get("DATABASE_URL") {
    Ok(url) -> from_url(url)
    Error(Nil) -> Error(MissingUrl("DATABASE_URL"))
  }
}

/// Parse `postgres://user:password@host:port/database?sslmode=...`. The user
/// defaults to `postgres` and the port to 5432; percent-encoded characters in
/// the user, password and database are decoded. Without `sslmode`, TLS is off
/// for loopback addresses and dotless host names such as a Compose service
/// called `db`, and verified for everything else.
///
/// Every connection then starts with these settings:
///
/// - `timezone` `UTC`
/// - `statement_timeout` 30 seconds
/// - `lock_timeout` 5 seconds, the counterpart of SQLite's busy timeout
/// - `idle_in_transaction_session_timeout` 60 seconds, so a transaction left
///   open cannot hold its locks indefinitely
pub fn from_url(url: String) -> Result(Config, Error) {
  use parsed <- result.try(uri.parse(url) |> result.replace_error(InvalidUrl))
  use <- bool.guard(
    parsed.scheme != Some("postgres") && parsed.scheme != Some("postgresql"),
    Error(InvalidUrl),
  )
  use host <- result.try(case parsed.host {
    Some(host) if host != "" ->
      Ok(host |> string.replace("[", "") |> string.replace("]", ""))
    _ -> Error(InvalidUrl)
  })
  use #(user, password) <- result.try(credentials(parsed.userinfo))
  use database <- result.try(case parsed.path {
    "/" <> name if name != "" ->
      case string.contains(name, "/") {
        True -> Error(InvalidUrl)
        False -> decoded(name)
      }
    _ -> Error(InvalidUrl)
  })
  use query <- result.try(case parsed.query {
    None -> Ok([])
    Some(query) -> uri.parse_query(query) |> result.replace_error(InvalidUrl)
  })
  use ssl <- result.try(case list.key_find(query, "sslmode") {
    Error(Nil) -> Ok(default_ssl(host))
    Ok("disable") -> Ok(SslDisabled)
    Ok("require") -> Ok(SslUnverified)
    Ok("verify-ca") | Ok("verify-full") -> Ok(SslVerified)
    Ok(mode) -> Error(UnsupportedSslMode(mode))
  })
  Ok(Config(
    host:,
    port: option.unwrap(parsed.port, 5432),
    database:,
    user:,
    password:,
    ssl:,
    pool_size: 10,
    parameters: [
      #("timezone", "UTC"),
      #("statement_timeout", "30000"),
      #("lock_timeout", "5000"),
      #("idle_in_transaction_session_timeout", "60000"),
    ],
    startup_timeout: 10_000,
  ))
}

fn credentials(
  userinfo: Option(String),
) -> Result(#(String, Option(String)), Error) {
  case url.credentials(userinfo) {
    Ok(None) -> Ok(#("postgres", None))
    Ok(Some(found)) -> Ok(found)
    Error(Nil) -> Error(InvalidUrl)
  }
}

fn decoded(text: String) -> Result(String, Error) {
  uri.percent_decode(text) |> result.replace_error(InvalidUrl)
}

fn default_ssl(host: String) -> Ssl {
  case url.is_local(host) {
    True -> SslDisabled
    False -> SslVerified
  }
}

pub fn ssl(config: Config, ssl: Ssl) -> Config {
  Config(..config, ssl:)
}

/// Connections kept open. Default 10.
pub fn pool_size(config: Config, size: Int) -> Config {
  Config(..config, pool_size: size)
}

/// How long `start` waits for the server to answer. Default 10 seconds.
pub fn startup_timeout(config: Config, milliseconds: Int) -> Config {
  Config(..config, startup_timeout: milliseconds)
}

/// Cancel any statement that runs longer. Zero disables the limit.
/// `howdy/migration` lifts it for its own transaction.
pub fn statement_timeout(config: Config, milliseconds: Int) -> Config {
  timeout(config, "statement_timeout", milliseconds)
}

/// Fail a statement that waits longer for a lock. Zero disables the limit.
pub fn lock_timeout(config: Config, milliseconds: Int) -> Config {
  timeout(config, "lock_timeout", milliseconds)
}

/// End the session of a transaction left idle for longer. Zero disables the
/// limit.
pub fn idle_in_transaction_timeout(
  config: Config,
  milliseconds: Int,
) -> Config {
  timeout(config, "idle_in_transaction_session_timeout", milliseconds)
}

fn timeout(config: Config, name: String, milliseconds: Int) -> Config {
  case milliseconds > 0 {
    True -> parameter(config, name, int.to_string(milliseconds))
    False -> Config(..config, parameters: without(config.parameters, name))
  }
}

/// Set any PostgreSQL run-time parameter when each connection opens,
/// replacing an earlier value for the same name. `application_name` cannot
/// be set here: the driver always reports the Erlang node name, which a
/// release sets to something like `notes@host`. Poolers such as PgBouncer
/// may refuse parameters they do not recognise: set them on the role instead
/// (`ALTER ROLE ... SET`) and pass zero to the timeout functions here.
pub fn parameter(config: Config, name: String, value: String) -> Config {
  Config(
    ..config,
    parameters: list.append(without(config.parameters, name), [#(name, value)]),
  )
}

fn without(parameters: List(#(String, String)), name: String) {
  list.filter(parameters, fn(parameter) { parameter.0 != name })
}

/// Start the pool and wait until the server answers and is at least
/// `minimum_version`. The pool is closed again when it does not. The pool
/// is linked to the caller; in an app, prefer `supervised`.
pub fn start(config: Config) -> Result(Repo, Error) {
  start_pool(config) |> result.map(repo)
}

/// A PostgreSQL pool reachable two ways: as the Gloo Repo that Howdy modules
/// take, and as the `pog.Connection` for code that talks to pog directly,
/// such as queries generated by Squirrel. Both use the same connections.
pub opaque type Pool {
  Pool(connection: pog.Connection, pid: Pid, repo: Repo)
}

/// `start`, keeping the `pog.Connection` as well as the Repo.
///
/// ```gleam
/// let assert Ok(pool) = postgres.from_env() |> result.try(postgres.start_pool)
/// let db = postgres.repo(pool)
/// let assert Ok(pog.Returned(rows:, ..)) =
///   sql.find_notes(postgres.connection(pool), owner)
/// ```
pub fn start_pool(config: Config) -> Result(Pool, Error) {
  let name = process.new_name(prefix: "howdy_postgres")
  remember(name, listen_settings(settings(config, name)))
  case pog.start(settings(config, name)) {
    Error(_) -> Error(StartFailed)
    Ok(started) -> {
      let pool = from_pog(started)
      case ready(pool.repo, config) {
        Ok(Nil) -> Ok(pool)
        Error(error) -> {
          let _ = repo.close(pool.repo)
          Error(error)
        }
      }
    }
  }
}

/// The pool as a child of a supervisor, with the handle to query it by.
/// The handle is made here, before the pool starts, so it can be given to
/// the app while the supervisor owns the pool:
///
/// ```gleam
/// let #(pool, child) = postgres.supervised(config)
/// static_supervisor.new(static_supervisor.OneForOne)
/// |> static_supervisor.add(child)
/// |> static_supervisor.add(howdy.supervised(app(postgres.repo(pool))))
/// |> howdy.start_application(name: "my_app_server")
/// ```
///
/// Starting the child waits for the server like `start` does, up to
/// `startup_timeout`, so a supervisor whose database is down fails to start
/// with a clear reason rather than serving requests that all fail. The
/// handle keeps working across restarts of the pool; a query made while it
/// is restarting, or after the supervisor stops, crashes the calling process
/// (usually exiting with `noproc`), as pog does for any named pool. Because the
/// supervisor owns the pool, `repo.close` on this handle's Repo does
/// nothing: stop the supervisor instead.
pub fn supervised(
  config: Config,
) -> #(Pool, supervision.ChildSpecification(Pool)) {
  let name = process.new_name(prefix: "howdy_postgres")
  remember(name, listen_settings(settings(config, name)))
  let connection = pog.named_connection(name)
  // Gloo only uses the pid to close a pool, which is the supervisor's job
  // here, so the Repo is built around a process that has already exited.
  let nobody = process.spawn(fn() { Nil })
  let pool =
    Pool(connection:, pid: nobody, repo: adapted(connection, nobody, 0))
  let child =
    supervision.supervisor(fn() {
      use started <- result.try(pog.start(settings(config, name)))
      case ready(pool.repo, config) {
        Ok(Nil) -> Ok(actor.Started(started.pid, pool))
        Error(error) -> {
          let _ = repo.close(from_pog(started).repo)
          Error(actor.InitFailed(error_to_string(error)))
        }
      }
    })
  #(pool, child)
}

fn settings(config: Config, name: Name(pog.Message)) -> pog.Config {
  let settings =
    pog.default_config(name)
    |> pog.host(config.host)
    |> pog.port(config.port)
    |> pog.database(config.database)
    |> pog.user(config.user)
    |> pog.password(config.password)
    |> pog.ssl(case config.ssl {
      SslDisabled -> pog.SslDisabled
      SslUnverified -> pog.SslUnverified
      SslVerified -> pog.SslVerified
    })
    |> pog.pool_size(config.pool_size)
  list.fold(config.parameters, settings, fn(settings, parameter) {
    pog.connection_parameter(settings, parameter.0, parameter.1)
  })
}

/// Adopt a pool the application started with `pog.start` itself. Unlike
/// `start_pool`, this neither waits for the server nor checks its version.
pub fn from_pog(started: actor.Started(pog.Connection)) -> Pool {
  let actor.Started(pid:, data: connection) = started
  Pool(connection:, pid:, repo: adapted(connection, pid, 0))
}

// Gloo's own Postgres adapter cannot set a port, TLS or parameters, so build
// the same adapter it would around a pool configured here. A depth above zero
// makes Gloo's own transactions savepoints inside an open pog transaction.
fn adapted(connection: pog.Connection, pid: process.Pid, depth: Int) -> Repo {
  repo.from_adapter(Adapter(
    name: "postgres",
    connection: PgConnection(conn: connection, pid:),
    quote_identifier: adapter.postgres_quote,
    placeholder: adapter.postgres_placeholder,
    savepoint_depth: depth,
    telemetry: telemetry.disabled(),
  ))
  |> database.traced
}

/// The Repo for Howdy modules and `howdy/database`.
pub fn repo(pool: Pool) -> Repo {
  pool.repo
}

/// The pog connection, for queries that do not go through Gloo.
pub fn connection(pool: Pool) -> pog.Connection {
  pool.connection
}

/// Commit when `run` returns `Ok`; roll back and return its error otherwise.
/// `run` gets the transaction twice: as a `pog.Connection` for pog and
/// Squirrel queries, and as a Repo for Howdy modules, whose own transactions
/// become savepoints within this one. Map pog errors with `error`.
///
/// Nesting only works that way round. Inside a `database.transaction`, or
/// another `transaction`, pog would check out a second pooled connection,
/// so the writes would not be atomic with the outer transaction's and could
/// deadlock against its row locks. That is refused with an `Internal` error
/// rather than run.
///
/// ```gleam
/// use conn, db <- postgres.transaction(pool)
/// use note <- result.try(
///   sql.insert_note(conn, owner, body) |> result.map_error(postgres.error),
/// )
/// audit.record(db, owner, "note created")
/// ```
pub fn transaction(
  pool: Pool,
  run: fn(pog.Connection, Repo) -> service.Result(a),
) -> service.Result(a) {
  use <- bool.guard(
    database.in_transaction(),
    Error(service.Internal(
      "a pool transaction cannot be opened inside a repo transaction",
    )),
  )
  use <- database.bracketed
  use <- trace.span("transaction", [])
  let answer =
    pog.transaction(pool.connection, fn(connection) {
      run(connection, adapted(connection, pool.pid, 1))
    })
  case answer {
    Ok(value) -> Ok(value)
    Error(failure) -> {
      trace.set_attributes([trace.bool("db.transaction.rolled_back", True)])
      case failure {
        pog.TransactionRolledBack(failure) -> Error(failure)
        pog.TransactionQueryError(failure) -> Error(error(failure))
      }
    }
  }
}

/// The error for a failed pog query, matching `howdy/database`: a
/// constraint violation is a `Conflict`, anything else is `Internal`. Driver
/// messages may contain personal data, so neither repeats them.
pub fn error(error: pog.QueryError) -> service.Error {
  case error {
    pog.ConstraintViolated(..) ->
      service.Conflict("the record conflicts with existing data")
    _ -> service.Internal("database operation failed")
  }
}

// -- Listening ---------------------------------------------------------------

/// A process hearing `NOTIFY` on one channel. See `listen`.
pub opaque type Listener {
  Listener(pid: Pid)
}

pub type ListenError {
  /// The Repo is not on PostgreSQL.
  NotPostgres
  /// The Repo's pool was not opened by this module and its settings could
  /// not be found inside it. Give them with `listen_via`.
  SettingsNotFound
  /// A channel is a plain name: lowercase letters, digits and `_`, not
  /// starting with a digit, at most 63 characters.
  InvalidChannel
}

pub fn listen_error_to_string(error: ListenError) -> String {
  case error {
    NotPostgres -> "the database is not PostgreSQL"
    SettingsNotFound ->
      "the pool's connection settings could not be found; give them with listen_via"
    InvalidChannel ->
      "a channel is lowercase letters, digits and _, not starting with a digit"
  }
}

/// Hear `NOTIFY` on `channel`, sent by any connection to the database,
/// such as another node of the app. `notify` is called with each payload,
/// in the listener's own process, one at a time; a crash in it is logged
/// and listening carries on.
///
/// ```gleam
/// let assert Ok(_) =
///   postgres.listen(db, "orders", fn(id) { process.send(orders, id) })
/// ```
///
/// The listener has a connection of its own, not one of the pool's,
/// opened with the pool's settings: remembered for a pool this module
/// opened, and otherwise looked for inside the running pool. It returns
/// once it is listening, or has tried for five seconds, so a `NOTIFY` sent
/// after `listen` returns is heard while the server is up.
///
/// The listener is linked to the caller and stops when it does. When the
/// connection is lost it connects and listens again by itself, but what
/// was sent meanwhile is not heard: check now and then as well, more
/// slowly, if missing one matters.
pub fn listen(
  repo: Repo,
  channel: String,
  notify: fn(String) -> Nil,
) -> Result(Listener, ListenError) {
  use <- bool.guard(!valid_channel(channel), Error(InvalidChannel))
  use backend <- result.try(
    database.backend(repo) |> result.replace_error(NotPostgres),
  )
  use <- bool.guard(backend != database.Postgres, Error(NotPostgres))
  use found <- result.map(
    settings_for(repo) |> result.replace_error(SettingsNotFound),
  )
  Listener(start_listener(found, channel, notify))
}

/// `listen`, connecting with these settings, such as
/// `pog.url_config(name, url)`: for a pool this module did not open, whose
/// settings `listen` cannot find. The pool name in them is not used.
pub fn listen_via(
  config: pog.Config,
  channel: String,
  notify: fn(String) -> Nil,
) -> Result(Listener, ListenError) {
  use <- bool.guard(!valid_channel(channel), Error(InvalidChannel))
  Ok(Listener(start_listener(listen_settings(config), channel, notify)))
}

/// Stop listening.
pub fn stop_listening(listener: Listener) -> Nil {
  stop_listener(listener.pid)
}

/// The listener's process, to monitor it or to hand it to a supervisor.
pub fn listener_pid(listener: Listener) -> Pid {
  listener.pid
}

/// Send `payload` to everything listening on `channel`. Inside a
/// transaction it is sent when the transaction commits, and not at all if
/// it rolls back. PostgreSQL limits a payload to 8000 bytes.
pub fn notify(
  repo: Repo,
  channel: String,
  payload: String,
) -> service.Result(Nil) {
  use <- bool.guard(
    !valid_channel(channel),
    Error(service.Invalid(listen_error_to_string(InvalidChannel))),
  )
  // NOTIFY takes no parameters, so the payload is written as a literal.
  database.execute(
    repo,
    "NOTIFY " <> channel <> ", '" <> string.replace(payload, "'", "''") <> "'",
    [],
  )
}

/// Channels are written into SQL unquoted, so they are kept to plain names.
fn valid_channel(channel: String) -> Bool {
  let length = string.length(channel)
  length > 0
  && length <= 63
  && !list.contains(
    ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"],
    string.slice(channel, 0, 1),
  )
  && string.to_utf_codepoints(channel)
  |> list.all(fn(codepoint) {
    case string.utf_codepoint_to_int(codepoint) {
      c if c >= 0x61 && c <= 0x7A -> True
      c if c >= 0x30 && c <= 0x39 -> True
      0x5F -> True
      _ -> False
    }
  })
}

type ListenSettings

fn listen_settings(config: pog.Config) -> ListenSettings {
  make_settings(
    config.host,
    config.port,
    config.database,
    config.user,
    config.password,
    config.ssl,
    config.connection_parameters,
    config.ip_version,
  )
}

@external(erlang, "howdy_database_listen", "settings")
fn make_settings(
  host: String,
  port: Int,
  database: String,
  user: String,
  password: Option(String),
  ssl: pog.Ssl,
  parameters: List(#(String, String)),
  ip_version: pog.IpVersion,
) -> ListenSettings

@external(erlang, "howdy_database_listen", "remember")
fn remember(name: Name(pog.Message), settings: ListenSettings) -> Nil

@external(erlang, "howdy_database_listen", "settings_for")
fn settings_for(repo: Repo) -> Result(ListenSettings, Nil)

@external(erlang, "howdy_database_listen", "start")
fn start_listener(
  settings: ListenSettings,
  channel: String,
  notify: fn(String) -> Nil,
) -> Pid

@external(erlang, "howdy_database_listen", "stop")
fn stop_listener(pid: Pid) -> Nil

/// The pool connects in the background and pog gives no signal when it has,
/// so poll until a query succeeds, up to the configured startup timeout.
fn ready(db: Repo, config: Config) -> Result(Nil, Error) {
  poll(db, now() + config.startup_timeout)
}

fn poll(db: Repo, deadline: Int) -> Result(Nil, Error) {
  let version =
    repo.all(
      db,
      "SELECT current_setting('server_version_num')",
      [],
      decode.field(0, decode.string, decode.success),
    )
  case version {
    Ok([version, ..]) ->
      case int.parse(version) {
        Ok(number) if number >= minimum_version * 10_000 -> Ok(Nil)
        Ok(number) ->
          Error(UnsupportedVersion(number / 10_000, minimum_version))
        Error(Nil) -> Error(Unreachable)
      }
    _ ->
      case now() >= deadline {
        True -> Error(Unreachable)
        False -> {
          process.sleep(200)
          poll(db, deadline)
        }
      }
  }
}

@internal
pub fn inspect(
  config: Config,
) -> #(
  String,
  Int,
  String,
  String,
  Option(String),
  Ssl,
  List(#(String, String)),
) {
  #(
    config.host,
    config.port,
    config.database,
    config.user,
    config.password,
    config.ssl,
    config.parameters,
  )
}
