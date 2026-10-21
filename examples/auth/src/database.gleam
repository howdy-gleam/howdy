//// Connection lifecycle/configuration belongs to the application. Auth and
//// `notes` only receive the resulting Repo. These examples choose SQLite; a
//// configured Gloo PostgreSQL Repo works unchanged.

import gloo/adapter/sqlite
import gloo/repo.{type Repo}
import howdy/database

/// The database of the full tour in `howdy_auth_example`.
pub fn connect() -> Repo {
  open("data.sqlite")
}

/// Each example in `flows/` keeps its own file, because they configure auth
/// differently (group modes, for one, are recorded in the database).
pub fn open(path: String) -> Repo {
  let assert Ok(db) = sqlite.start(sqlite.file(path))
  let assert Ok(_) = database.sqlite_defaults(db)
  db
}
