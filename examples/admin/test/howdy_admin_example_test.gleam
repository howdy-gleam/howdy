import gleam/erlang/atom
import gleam/http/request
import gleam/list
import gleam/option
import gleam/string
import gleeunit
import gloo/repo
import howdy/admin
import howdy/auth
import howdy/auth/user
import howdy/flags
import howdy/jobs
import howdy/mail
import howdy/mail/outbox
import howdy/mail/preview
import howdy/testing
import howdy_admin_example as example

pub fn main() {
  gleeunit.main()
}

/// The admin mounts on the example's app and sees its table.
pub fn the_admin_sees_the_notes_table_test() {
  let db = example.open(":memory:")
  let box = outbox.start()
  let mailer =
    mail.mailer(outbox.adapter(box)) |> mail.default_from(example.sender)
  let identity = example.identity(db, mailer)
  let permissions = example.permissions(db)
  let features = example.features(db)
  let app =
    example.app(db, identity, permissions, features)
    |> admin.mount(
      admin.new()
      |> admin.auth(identity)
      |> admin.authorization(permissions)
      |> admin.flags(features),
    )
  let res =
    testing.get("/_howdy/data")
    |> request.set_host("localhost")
    |> testing.send(app)
  assert res.status == 200
  assert string.contains(testing.text(res), "notes_notes")
  let res =
    testing.get("/_howdy/roles")
    |> request.set_host("localhost")
    |> testing.send(app)
  assert string.contains(testing.text(res), "reader")
  let res =
    testing.get("/_howdy/flags")
    |> request.set_host("localhost")
    |> testing.send(app)
  assert string.contains(testing.text(res), "notes_newest_first")
  flags.stop(features)
  let assert Ok(_) = repo.close(db)
}

/// Registering sends the auth email to the outbox, with a link to the
/// starter pages, and every email has a preview that renders.
pub fn registration_mail_reaches_the_outbox_test() {
  let db = example.open(":memory:")
  let box = outbox.start()
  let mailer =
    mail.mailer(outbox.adapter(box)) |> mail.default_from(example.sender)
  let identity = example.identity(db, mailer)
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Register)
  let assert Ok(sent) = outbox.latest_to(box, "ada@example.com")
  assert sent.subject == "Confirm your Notes account"
  let assert option.Some(text) = sent.text
  assert string.contains(text, example.origin <> "/auth/login#token=")

  let app =
    example.app(db, identity, example.permissions(db), example.features(db))
    |> admin.mount(
      admin.new()
      |> admin.mail(box)
      |> admin.mail_previews(example.previews(mailer), send_with: mailer),
    )
  list.each(example.previews(mailer), fn(p) {
    let res =
      testing.get("/_howdy/mail/previews?p=" <> preview.key(p))
      |> request.set_host("localhost")
      |> testing.send(app)
    assert res.status == 200
    assert !string.contains(testing.text(res), "would not be sent")
    assert !string.contains(testing.text(res), "crashed")
  })
  let assert Ok(_) = repo.close(db)
}

/// Writing a note queues its author's digest in the same transaction; the
/// runner sends it, once however many notes were written.
pub fn writing_notes_queues_one_digest_test() {
  let db = example.open(":memory:")
  let box = outbox.start()
  let mailer =
    mail.mailer(outbox.adapter(box)) |> mail.default_from(example.sender)
  let identity = example.identity(db, mailer)
  let assert Ok(ada) =
    auth.provision(identity, "ada@example.com", by: user.System)
  let assert Ok(_) = example.create(db, ada, "Buy milk")
  let assert Ok(_) = example.create(db, ada, "Call the plumber")
  let assert Ok([queued]) = jobs.list(db, jobs.listing())
  assert queued.name == "notes.digest"
  assert queued.state == jobs.Scheduled
  // A minute on, the runner sends it.
  let runner =
    example.runner(db, identity, mailer)
    |> jobs.with_clock(fn() { now() + 61_000 })
  let assert Ok(drained) = jobs.drain(runner)
  assert drained.completed == 1
  let assert Ok(sent) = outbox.latest_to(box, "ada@example.com")
  assert sent.subject == "Your notes this week"
  let assert Ok(_) = repo.close(db)
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: atom.Atom) -> Int

fn now() -> Int {
  system_time(atom.create("millisecond"))
}
