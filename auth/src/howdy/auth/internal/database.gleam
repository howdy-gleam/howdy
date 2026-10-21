//// Auth's view of `howdy/database`. Transactions additionally carry the
//// authorization cache's dirty flag; everything else is the shared module,
//// so auth and the application serialize on the same SQLite Repo lock.

import gleam/dynamic/decode
import gloo/repo.{type Repo}
import gloo/value.{type GlooValue}
import howdy/auth/internal/cache
import howdy/database
import howdy/service

pub fn backend(repo: Repo) -> service.Result(database.Backend) {
  database.backend(repo)
}

pub fn connect(
  repo: Repo,
  run: fn(Repo) -> service.Result(a),
) -> service.Result(a) {
  database.connect(repo, run)
}

pub fn transaction(
  repo: Repo,
  run: fn(Repo) -> service.Result(a),
) -> service.Result(a) {
  use <- cache.transaction
  database.transaction(repo, run)
}

pub fn write_transaction(
  repo: Repo,
  touching table: String,
  run run: fn(Repo) -> service.Result(a),
) -> service.Result(a) {
  use <- cache.transaction
  database.write_transaction(repo, touching: table, run:)
}

pub fn exec(repo: Repo, statements: String) -> service.Result(Nil) {
  database.exec(repo, statements)
}

pub fn query(
  repo: Repo,
  sql: String,
  args: List(GlooValue),
  decoder: decode.Decoder(a),
) -> service.Result(List(a)) {
  database.query(repo, sql, args, decoder)
}

pub fn execute(
  repo: Repo,
  sql: String,
  args: List(GlooValue),
) -> service.Result(Nil) {
  database.execute(repo, sql, args)
}

pub fn for_update(repo: Repo, alias: String) -> String {
  database.for_update(repo, alias)
}

pub fn read_time(repo: Repo, column: String) -> String {
  database.read_time(repo, column)
}

pub fn write_time(repo: Repo, placeholder: String) -> String {
  database.write_time(repo, placeholder)
}
