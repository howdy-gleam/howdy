//// The feature flag pages, driven through the app against an in-memory
//// SQLite database with auth and flags installed.

import gleam/http/request
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gloo/adapter/sqlite
import gloo/repo
import howdy
import howdy/admin
import howdy/auth
import howdy/database
import howdy/flags
import howdy/flags/database as flags_database
import howdy/migration
import howdy/testing

fn checkout() -> flags.Flag {
  flags.flag("new_checkout", description: "Stripe-hosted checkout")
}

fn with_flags(run: fn(auth.Auth, flags.Flags, howdy.App) -> a) -> a {
  let assert Ok(db) = sqlite.start(sqlite.memory())
  let assert Ok(Nil) = database.sqlite_defaults(db)
  let assert Ok(Nil) =
    migration.run(db, [auth.schema(), flags_database.schema()])
  let assert Ok(identity) =
    auth.new_without_email(repo: db, origin: "http://localhost:8787")
  let assert Ok(store) = flags_database.store(db)
  let assert Ok(features) =
    flags.new(store) |> flags.register([checkout()]) |> flags.start
  let app =
    howdy.new()
    |> admin.mount(admin.new() |> admin.auth(identity) |> admin.flags(features))
  let value = run(identity, features, app)
  flags.stop(features)
  let assert Ok(_) = repo.close(db)
  value
}

fn get(app: howdy.App, path: String) -> String {
  let res =
    testing.get(path) |> request.set_host("localhost") |> testing.send(app)
  assert res.status == 200
    as { "GET " <> path <> " gave " <> string.inspect(res.status) }
  testing.text(res)
}

fn post(
  app: howdy.App,
  path: String,
  fields: List(#(String, String)),
) -> String {
  let res =
    testing.post_form(path, fields)
    |> request.set_host("localhost")
    |> testing.header("sec-fetch-site", "same-origin")
    |> testing.send(app)
  assert res.status == 303
    as {
      "POST "
      <> path
      <> " gave "
      <> string.inspect(res.status)
      <> ": "
      <> testing.text(res)
    }
  let assert Ok(location) = list.key_find(res.headers, "location")
  location
}

const flag_page = "/_howdy/flags/flag?key=new_checkout"

fn act(app: howdy.App, action: String, fields: List(#(String, String))) {
  post(app, "/_howdy/flags/flag/" <> action <> "?key=new_checkout", fields)
}

pub fn flags_appear_in_the_overview_and_sidebar_test() {
  use _, features, app <- with_flags
  assert admin.has_flags(admin.new() |> admin.flags(features))
  let overview = get(app, "/_howdy")
  assert string.contains(overview, "howdy_flags")
  assert string.contains(overview, "1 registered flag")
  let index = get(app, "/_howdy/flags")
  assert string.contains(index, "new_checkout")
  assert string.contains(index, "default off")
  assert string.contains(index, "Stripe-hosted checkout")
}

pub fn kill_and_undo_from_the_flag_page_test() {
  use _, features, app <- with_flags
  // Rollouts are set in code; the page shows them without offering to.
  let assert Ok(Nil) =
    flags.set_rollout(features, "new_checkout", to: 1250, by: "console")
  let page = get(app, flag_page)
  assert string.contains(page, "12.5%")
  assert string.contains(page, "Rollout 0% → 12.5%")
  assert !string.contains(page, "Start ramp")
  assert !string.contains(page, "Set %")

  let _ = act(app, "kill", [])
  let page = get(app, flag_page)
  assert string.contains(page, "killed")
  assert string.contains(page, "Revive the flag")
  assert !flags.enabled(features, checkout(), for: flags.user("1"))

  let assert Ok([kill, ..]) =
    flags.history(features, of: Some("new_checkout"), limit: 1)
  assert kill.by == "howdy_admin"
  let _ = act(app, "undo", [#("change", string.inspect(kill.id))])
  let assert Ok(Some(restored)) = flags.setting(features, "new_checkout")
  assert !restored.killed
  assert restored.rollout == 1250

  // The rollout and ramp routes are gone.
  let res =
    testing.post_form("/_howdy/flags/flag/rollout?key=new_checkout", [
      #("rollout", "50"),
    ])
    |> request.set_host("localhost")
    |> testing.header("sec-fetch-site", "same-origin")
    |> testing.send(app)
  assert res.status == 404

  let _ = act(app, "forget", [])
  assert flags.setting(features, "new_checkout") == Ok(None)
}

pub fn rules_accept_emails_and_the_check_explains_test() {
  use _, features, app <- with_flags
  let assert "/_howdy/users/" <> ada =
    post(app, "/_howdy/users", [#("email", "ada@example.com")])
  let _ = act(app, "allow", [#("kind", "user"), #("id", "ada@example.com")])
  assert flags.enabled(features, checkout(), for: flags.user(ada))
  let page = get(app, flag_page)
  assert string.contains(page, "ada@example.com")
  assert string.contains(page, "user:" <> ada)

  let check = get(app, flag_page <> "&user=ada%40example.com&org=")
  assert string.contains(check, "Allowed for user:" <> ada)
  let check = get(app, flag_page <> "&user=someone&org=")
  assert string.contains(check, "is outside the rollout of 0%")

  let _ = act(app, "unlist", [#("target", "user:" <> ada)])
  assert !flags.enabled(features, checkout(), for: flags.user(ada))
}

pub fn groups_are_created_filled_and_used_test() {
  use _, features, app <- with_flags
  let location =
    post(app, "/_howdy/flags/groups", [
      #("name", "beta"),
      #("description", "Beta testers"),
    ])
  assert location == "/_howdy/flags/groups/group?name=beta"
  let _ =
    post(app, "/_howdy/flags/groups/group/add?name=beta", [
      #("kind", "org"),
      #("id", "acme"),
    ])
  assert string.contains(get(app, location), "org:acme")
  let _ = act(app, "allow", [#("kind", "group"), #("id", "beta")])
  assert flags.enabled(
    features,
    checkout(),
    for: flags.user("9") |> flags.in_organization("acme"),
  )

  // In use by a rule, so deleting is refused with the reason.
  let res =
    testing.post_form("/_howdy/flags/groups/group/delete?name=beta", [])
    |> request.set_host("localhost")
    |> testing.header("sec-fetch-site", "same-origin")
    |> testing.send(app)
  assert string.contains(testing.text(res), "new_checkout")
  let _ = act(app, "unlist", [#("target", "group:beta")])
  assert post(app, "/_howdy/flags/groups/group/delete?name=beta", [])
    == "/_howdy/flags/groups"
  assert string.contains(get(app, "/_howdy/flags/groups"), "No groups yet")
}

pub fn read_only_flags_are_shown_without_controls_test() {
  let store =
    flags.store(
      named: "hosting",
      load: fn() {
        Ok(
          flags.Snapshot(
            version: 1,
            settings: [
              #(
                "new_checkout",
                flags.Setting(
                  killed: False,
                  rollout: 500,
                  bucketing: flags.ByUser,
                  allowed: [flags.Group("beta")],
                  blocked: [],
                  ramp: None,
                ),
              ),
            ],
            groups: [
              flags.GroupSummary("beta", "Beta testers", [
                flags.Organization("acme"),
              ]),
            ],
          ),
        )
      },
      version: fn() { Ok(1) },
      history: fn(_, _) { Ok([]) },
    )
  let assert Ok(features) =
    flags.new(store) |> flags.register([checkout()]) |> flags.start
  let app = howdy.new() |> admin.mount(admin.new() |> admin.flags(features))

  assert string.contains(get(app, "/_howdy"), "kept in hosting, read-only")
  let page = get(app, flag_page)
  assert string.contains(page, "read-only here")
  assert string.contains(page, "group:beta")
  assert string.contains(page, "5%")
  assert !string.contains(page, "Kill the flag")
  assert !string.contains(page, ">Allow<")
  assert !string.contains(page, "Reset to the default")
  // The check still answers.
  let check = get(app, flag_page <> "&user=9&org=acme")
  assert string.contains(check, "Allowed for group:beta")

  let groups = get(app, "/_howdy/flags/groups/group?name=beta")
  assert string.contains(groups, "org:acme")
  assert !string.contains(groups, "Delete group")
  assert !string.contains(get(app, "/_howdy/flags/groups"), "New group")

  // Posting anyway is refused with the reason.
  let res =
    testing.post_form("/_howdy/flags/flag/kill?key=new_checkout", [])
    |> request.set_host("localhost")
    |> testing.header("sec-fetch-site", "same-origin")
    |> testing.send(app)
  assert string.contains(testing.text(res), "read-only")
  flags.stop(features)
}
