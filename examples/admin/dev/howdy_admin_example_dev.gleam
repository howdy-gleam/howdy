//// Development entry point: `gleam dev`. The same app as `gleam run`, with
//// hot reload and the admin area at <http://localhost:8787/_howdy>.
////
//// The database and auth are opened once here and handed to both the app
//// and the admin, which is how the admin knows what to show: there is no
//// package detection in Gleam, so registration is explicit.
//// The one thing it finds for itself is the OpenAPI document the app
//// serves, under **API**, where each endpoint can be called as any user.
////
//// Mail goes to an outbox that writes each message to `tmp/mail`, instead
//// of SMTP or the terminal, and the admin shows it as it arrives.
////
//// Telemetry records into memory, and the admin shows every request as a
//// timeline of its queries, emails and logs under **Telemetry**.
////
//// The app's feature flags are under **Flags**: kill switches, rollouts,
//// ramps, rules for users and groups, and their history.
////
//// The jobs runner starts here too, and **Jobs** shows its queues, its
//// weekly schedule and every job: write a note and its digest waits a
//// minute, then lands in the outbox.

import gleam/erlang/process
import howdy
import howdy/admin
import howdy/dev
import howdy/jobs
import howdy/mail
import howdy/mail/outbox
import howdy/telemetry
import howdy/telemetry/recorder
import howdy_admin_example as example

pub fn main() -> Nil {
  let recorder = recorder.new(keep: 200)
  let assert Ok(Nil) =
    telemetry.new("notes") |> telemetry.record(recorder) |> telemetry.start
  let db = example.open("admin_example.sqlite")
  let assert Ok(box) = outbox.start_in("tmp/mail")
  let mailer =
    mail.mailer(outbox.adapter(box)) |> mail.default_from(example.sender)
  let identity = example.identity(db, mailer)
  let permissions = example.permissions(db)
  let features = example.features(db)
  let runner = example.runner(db, identity, mailer)
  let assert Ok(_) = jobs.start(runner)
  let dashboard =
    admin.new()
    |> admin.named("Notes admin")
    |> admin.auth(identity)
    |> admin.authorization(permissions)
    |> admin.mail(box)
    |> admin.mail_previews(example.previews(mailer), send_with: mailer)
    |> admin.telemetry(recorder)
    |> admin.flags(features)
    |> admin.jobs(runner)

  let assert Ok(_) =
    dev.start(fn() {
      example.app(db, identity, permissions, features)
      |> admin.mount(dashboard)
      |> howdy.listening(on: 8787)
    })
  process.sleep_forever()
}
