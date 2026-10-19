//// Manage the app's background jobs from the command line:
//// `gleam run -m tasks/jobs help`. Every command works on the database the
//// app uses.

import howdy/jobs/cli
import howdy_admin_example as example

pub fn main() -> Nil {
  cli.main(fn() { Ok(example.open("admin_example.sqlite")) })
}
