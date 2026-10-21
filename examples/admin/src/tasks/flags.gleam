//// Manage the app's feature flags from the command line:
//// `gleam run -m tasks/flags help`. `export` prints the flags the code
//// defines as JSON without opening the database; every other command
//// works on the database the app uses.

import howdy/flags/cli
import howdy/flags/database as flags_database
import howdy_admin_example as example

pub fn main() -> Nil {
  cli.main(example.all_flags(), fn() {
    flags_database.store(example.open("admin_example.sqlite"))
  })
}
