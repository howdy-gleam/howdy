//// Schema migrations are a deployment step, never part of startup. This
//// migrates the full tour's database and every example's in `flows/`.

import database
import flows/email_tokens
import flows/enterprise_sso
import flows/multi_tenant
import flows/passkeys_and_mfa
import flows/passwords
import flows/server_rendered
import flows/sessions
import flows/social_login
import gleam/io
import gleam/list
import gloo/repo
import howdy/auth
import howdy/authorization
import howdy/migration
import notes

pub fn main() {
  let auth_only = [auth.schema(), authorization.schema()]
  [
    #("data.sqlite", [auth.schema(), authorization.schema(), notes.schema()]),
    #(email_tokens.database_file, auth_only),
    #(passwords.database_file, auth_only),
    #(social_login.database_file, auth_only),
    #(passkeys_and_mfa.database_file, auth_only),
    #(server_rendered.database_file, auth_only),
    #(multi_tenant.database_file, auth_only),
    #(enterprise_sso.database_file, auth_only),
    #(sessions.database_file, auth_only),
  ]
  |> list.each(fn(target) {
    let #(path, packages) = target
    let db = database.open(path)
    let assert Ok(_) = migration.run(db, packages)
    let assert Ok(_) = repo.close(db)
    io.println("Migrated " <> path)
  })
}
