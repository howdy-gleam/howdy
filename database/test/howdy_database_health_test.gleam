import gloo/adapter/sqlite
import gloo/repo
import howdy
import howdy/database
import howdy/health
import howdy/testing

fn up(db: repo.Repo) {
  let app =
    howdy.new()
    |> howdy.health_check(
      health.new() |> health.check("database", database.health_check(db)),
    )
  testing.get("/up") |> testing.send(app)
}

pub fn an_open_database_passes_test() {
  let assert Ok(db) = sqlite.start(sqlite.memory())
  assert database.health_check(db)() == Ok(Nil)
  let res = up(db)
  assert res.status == 200
  assert testing.text(res)
    == "{\"status\":\"ok\",\"checks\":{\"database\":\"ok\"}}"
  let assert Ok(_) = repo.close(db)
}

pub fn a_closed_database_fails_test() {
  let assert Ok(db) = sqlite.start(sqlite.memory())
  let assert Ok(_) = repo.close(db)
  let res = up(db)
  assert res.status == 503
  assert testing.text(res)
    == "{\"status\":\"error\",\"checks\":{\"database\":\"error\"}}"
}
