import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit
import gloo/adapter/sqlite
import gloo/repo.{type Repo}
import howdy
import howdy/controller
import howdy/database
import howdy/database/postgres
import howdy/jobs.{Drained}
import howdy/mail
import howdy/migration
import howdy/notifications.{
  Delivered, Delivery, EmailDigest, EmailNow, GiveUp, NoEmail, Received, Retry,
  Unread,
}
import howdy/service
import howdy/sse
import howdy/testing

pub fn main() {
  gleeunit.main()
}

@external(erlang, "howdy_notifications_test_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

/// SQLite in memory, or a PostgreSQL database emptied of the package's
/// rows when `HOWDY_NOTIFICATIONS_TEST_POSTGRES_URL` is set. The PostgreSQL
/// pool is opened and migrated once and kept for the whole run.
fn open() -> Repo {
  case getenv("HOWDY_NOTIFICATIONS_TEST_POSTGRES_URL") {
    Error(Nil) -> {
      let assert Ok(db) = sqlite.start(sqlite.memory())
      let assert Ok(Nil) = database.sqlite_defaults(db)
      let assert Ok(Nil) =
        migration.run(db, [jobs.schema(), notifications.schema()])
      let assert Ok(Nil) = migration.check(db, notifications.schema())
      db
    }
    Ok(url) -> {
      let db = case kept() {
        Ok(db) -> db
        Error(Nil) -> {
          // The pool is linked to the process that starts it, and each test
          // runs in a process of its own, so a process that never exits
          // starts it.
          let started = process.new_subject()
          process.spawn_unlinked(fn() {
            let assert Ok(db) =
              postgres.from_url(url) |> result.try(postgres.start)
            process.send(started, db)
            process.sleep_forever()
          })
          let assert Ok(db) = process.receive(started, 10_000)
          let assert Ok(Nil) =
            database.exec(
              db,
              "DROP TABLE IF EXISTS howdy_notifications_items,
                howdy_notifications_preferences, howdy_notifications_digests,
                howdy_notifications_push_subscriptions, howdy_jobs,
                howdy_jobs_queues, howdy_jobs_schedules;
              CREATE TABLE IF NOT EXISTS howdy_migrations (package TEXT NOT NULL, version BIGINT NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(package, version));
              CREATE TABLE IF NOT EXISTS howdy_migration_schemas (package TEXT PRIMARY KEY NOT NULL, fingerprint TEXT NOT NULL);
              DELETE FROM howdy_migrations WHERE package IN ('howdy_notifications', 'howdy_jobs');
              DELETE FROM howdy_migration_schemas WHERE package IN ('howdy_notifications', 'howdy_jobs')",
            )
          let assert Ok(Nil) =
            migration.run(db, [jobs.schema(), notifications.schema()])
          let assert Ok(Nil) = migration.check(db, notifications.schema())
          keep(db)
          db
        }
      }
      let assert Ok(Nil) =
        database.exec(
          db,
          "TRUNCATE howdy_notifications_items, howdy_notifications_preferences,
            howdy_notifications_digests, howdy_notifications_push_subscriptions,
            howdy_jobs, howdy_jobs_queues, howdy_jobs_schedules",
        )
      db
    }
  }
}

@external(erlang, "howdy_notifications_test_ffi", "kept")
fn kept() -> Result(Repo, Nil)

@external(erlang, "howdy_notifications_test_ffi", "keep")
fn keep(db: Repo) -> Nil

/// A clock every process shares, which moves only when a test advances it.
@external(erlang, "howdy_notifications_test_ffi", "clock")
fn clock() -> Int

@external(erlang, "howdy_notifications_test_ffi", "advance")
fn advance(milliseconds: Int) -> Nil

fn notifier() -> notifications.Notifier {
  notifications.new(open()) |> notifications.with_clock(clock)
}

/// Do every delivery job that is due by the test's clock.
fn deliver(notifier: notifications.Notifier) -> jobs.Drained {
  let assert Ok(drained) =
    jobs.runner(notifications.repo(notifier))
    |> jobs.with_clock(clock)
    |> notifications.handle_jobs(notifier)
    |> jobs.drain
  drained
}

fn send(notifier, to: String, title: String) -> notifications.Notification {
  let assert Ok(Some(sent)) =
    notifications.draft("comment.created", title)
    |> notifications.send(notifier, to:)
  advance(1)
  sent
}

fn titles(notifier, user: String, page) -> List(String) {
  let assert Ok(found) = notifications.list(notifier, user, page)
  list.map(found, fn(n) { n.title })
}

// -- The inbox ---------------------------------------------------------------

pub fn send_and_read_the_inbox_test() {
  let notifier = notifier()
  let first =
    notifications.draft("comment.created", "Ana commented")
    |> notifications.body("Looks good")
    |> notifications.link("/posts/1")
    |> notifications.data([#("post", "1")])
    |> notifications.send(notifier, to: "u1")
  let assert Ok(Some(first)) = first
  assert first.recipient == "u1"
  assert first.read_at == None
  advance(1)
  let _ = send(notifier, "u1", "Bo commented")
  let _ = send(notifier, "u2", "Not yours")

  assert titles(notifier, "u1", notifications.page())
    == ["Bo commented", "Ana commented"]
  assert notifications.unread_count(notifier, "u1") == Ok(2)
  let assert Ok(got) = notifications.get(notifier, "u1", first.id)
  assert got == first
  assert got.data == dict.from_list([#("post", "1")])
  assert got.link == Some("/posts/1")
  // Someone else's notification cannot be seen or changed.
  assert notifications.get(notifier, "u2", first.id)
    == Error(service.NotFound("notification not found"))
  assert notifications.mark_read(notifier, "u2", first.id)
    == Error(service.NotFound("notification not found"))
  assert notifications.delete(notifier, "u2", first.id)
    == Error(service.NotFound("notification not found"))
}

pub fn read_unread_and_delete_test() {
  let notifier = notifier()
  let a = send(notifier, "u1", "A")
  let b = send(notifier, "u1", "B")
  assert notifications.mark_read(notifier, "u1", a.id) == Ok(Nil)
  // Reading twice keeps the first time.
  let assert Ok(read) = notifications.get(notifier, "u1", a.id)
  advance(5)
  assert notifications.mark_read(notifier, "u1", a.id) == Ok(Nil)
  assert notifications.get(notifier, "u1", a.id) == Ok(read)
  assert read.read_at != None
  assert notifications.unread_count(notifier, "u1") == Ok(1)
  assert titles(
      notifier,
      "u1",
      notifications.page() |> notifications.unread_only,
    )
    == ["B"]

  assert notifications.mark_unread(notifier, "u1", a.id) == Ok(Nil)
  assert notifications.unread_count(notifier, "u1") == Ok(2)
  assert notifications.mark_all_read(notifier, "u1") == Ok(Nil)
  assert notifications.unread_count(notifier, "u1") == Ok(0)

  assert notifications.delete(notifier, "u1", b.id) == Ok(Nil)
  assert titles(notifier, "u1", notifications.page()) == ["A"]
}

pub fn pages_go_back_in_time_test() {
  let notifier = notifier()
  let sent =
    ["1", "2", "3", "4", "5"]
    |> list.map(fn(title) { send(notifier, "u1", title) })
  let assert [_, _, third, ..] = list.reverse(sent)
  let page = notifications.page() |> notifications.limit(2)
  assert titles(notifier, "u1", page) == ["5", "4"]
  assert titles(notifier, "u1", notifications.before(page, third.id))
    == ["2", "1"]
  // A cursor that is not the user's gives nothing.
  assert titles(notifier, "u2", notifications.before(page, third.id)) == []
}

pub fn notifications_sent_in_the_same_millisecond_page_by_id_test() {
  let notifier = notifier()
  let assert Ok(sent) =
    notifications.draft("x", "same")
    |> notifications.send_to_each(notifier, ["u1", "u1", "u1"])
  // Ties are broken by ID, in the database's own text order, so paging one
  // at a time visits each exactly once.
  let page = notifications.page() |> notifications.limit(1)
  let assert Ok([first]) = notifications.list(notifier, "u1", page)
  let assert Ok([second]) =
    notifications.list(notifier, "u1", notifications.before(page, first.id))
  let assert Ok([third]) =
    notifications.list(notifier, "u1", notifications.before(page, second.id))
  assert notifications.list(
      notifier,
      "u1",
      notifications.before(page, third.id),
    )
    == Ok([])
  let visited = [first.id, second.id, third.id] |> list.sort(string.compare)
  assert visited == list.map(sent, fn(n) { n.id }) |> list.sort(string.compare)
}

pub fn delete_user_and_prune_test() {
  let notifier = notifier()
  let a = send(notifier, "u1", "A")
  let _ = send(notifier, "u1", "B")
  let _ = send(notifier, "u2", "C")
  let assert Ok(Nil) =
    notifications.set_preference(notifier, "u1", "x", notifications.muted)

  assert notifications.mark_read(notifier, "u1", a.id) == Ok(Nil)
  advance(10)
  assert notifications.prune(notifier, read_before: clock()) == Ok(Nil)
  // Only the read one goes.
  assert titles(notifier, "u1", notifications.page()) == ["B"]

  assert notifications.delete_user(notifications.repo(notifier), "u1")
    == Ok(Nil)
  assert titles(notifier, "u1", notifications.page()) == []
  assert notifications.preferences(notifier, "u1") == Ok([])
  assert titles(notifier, "u2", notifications.page()) == ["C"]
}

// -- Preferences -------------------------------------------------------------

pub fn preferences_fall_back_from_kind_to_every_kind_to_defaults_test() {
  let digest = Delivery(inbox: True, email: EmailDigest, push: False)
  let notifier =
    notifier()
    |> notifications.with_defaults(fn(kind) {
      case kind {
        "security." <> _ ->
          Delivery(..notifications.default_delivery, email: EmailNow)
        _ -> notifications.default_delivery
      }
    })
  assert notifications.preference(notifier, "u1", "security.login")
    == Ok(Delivery(inbox: True, email: EmailNow, push: True))
  assert notifications.preference(notifier, "u1", "comment")
    == Ok(notifications.default_delivery)

  let assert Ok(Nil) =
    notifications.set_preference(
      notifier,
      "u1",
      notifications.every_kind,
      digest,
    )
  assert notifications.preference(notifier, "u1", "security.login")
    == Ok(digest)
  let assert Ok(Nil) =
    notifications.set_preference(notifier, "u1", "comment", notifications.muted)
  assert notifications.preference(notifier, "u1", "comment")
    == Ok(notifications.muted)
  // Setting again replaces.
  let assert Ok(Nil) =
    notifications.set_preference(notifier, "u1", "comment", digest)
  assert notifications.preferences(notifier, "u1")
    == Ok([#("*", digest), #("comment", digest)])
  assert notifications.clear_preference(notifier, "u1", "comment") == Ok(Nil)
  assert notifications.preferences(notifier, "u1") == Ok([#("*", digest)])
  // Other users are untouched.
  assert notifications.preference(notifier, "u2", "comment")
    == Ok(notifications.default_delivery)
  assert notifications.set_preference(notifier, "u1", "", digest)
    == Error(service.Invalid("a kind is 1 to 200 characters"))
}

pub fn a_muted_kind_is_not_saved_test() {
  let notifier = notifier()
  let assert Ok(Nil) =
    notifications.set_preference(
      notifier,
      "u1",
      "comment.created",
      notifications.muted,
    )
  assert notifications.draft("comment.created", "Hi")
    |> notifications.send(notifier, to: "u1")
    == Ok(None)
  assert titles(notifier, "u1", notifications.page()) == []
}

pub fn email_only_notifications_stay_out_of_the_inbox_test() {
  let #(notifier, outbox) = with_mail(notifier())
  let assert Ok(Nil) =
    notifications.set_preference(
      notifier,
      "u1",
      "comment.created",
      Delivery(inbox: False, email: EmailNow, push: False),
    )
  let n = send(notifier, "u1", "Hi")
  assert titles(notifier, "u1", notifications.page()) == []
  assert notifications.unread_count(notifier, "u1") == Ok(0)
  assert notifications.get(notifier, "u1", n.id)
    == Error(service.NotFound("notification not found"))
  assert deliver(notifier).completed == 1
  assert sent_subjects(outbox) == ["Hi"]
}

// -- Live --------------------------------------------------------------------

pub fn subscribers_hear_new_notifications_and_counts_test() {
  let notifier = notifier()
  let events = process.new_subject()
  let subscription = notifications.subscribe("u1", events)
  assert notifications.subscribers("u1") == 1

  let sent = send(notifier, "u1", "Hello")
  let _ = send(notifier, "u2", "Not for u1")
  assert process.receive(events, 1000) == Ok(Received(sent))
  assert process.receive(events, 1000) == Ok(Unread(1))
  assert notifications.mark_read(notifier, "u1", sent.id) == Ok(Nil)
  assert process.receive(events, 1000) == Ok(Unread(0))
  assert process.receive(events, 50) == Error(Nil)

  notifications.unsubscribe(subscription)
  process.sleep(20)
  assert notifications.subscribers("u1") == 0
  let _ = send(notifier, "u1", "Unheard")
  assert process.receive(events, 50) == Error(Nil)
}

pub fn a_subscription_ends_with_its_owner_test() {
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let events = process.new_subject()
      notifications.subscribe("u9", events)
      process.send(ready, Nil)
      process.sleep_forever()
    })
  let assert Ok(Nil) = process.receive(ready, 1000)
  assert notifications.subscribers("u9") == 1
  process.kill(owner)
  process.sleep(50)
  assert notifications.subscribers("u9") == 0
}

// -- Routes ------------------------------------------------------------------

fn app(notifier) -> howdy.App {
  howdy.new()
  |> howdy.controller(
    notifications.routes(notifier, at: "/notifications", identify: fn(ctx) {
      case testing_user(ctx) {
        Ok(user) -> Ok(user)
        Error(Nil) -> Error(service.Unauthorized)
      }
    }),
  )
}

/// The user a test request claims to be, from an `x-user` header.
fn testing_user(ctx: controller.Context) -> Result(String, Nil) {
  list.key_find(ctx.request.headers, "x-user")
}

fn listing() -> decode.Decoder(#(List(String), Int)) {
  use titles <- decode.field(
    "notifications",
    decode.list(decode.at(["title"], decode.string)),
  )
  use unread <- decode.field("unread", decode.int)
  decode.success(#(titles, unread))
}

pub fn routes_list_and_change_the_inbox_test() {
  let notifier = notifier()
  let a = send(notifier, "u1", "A")
  let _ = send(notifier, "u1", "B")
  let app = app(notifier)

  let res = testing.get("/notifications") |> testing.send(app)
  assert res.status == 401

  let res =
    testing.get("/notifications")
    |> testing.header("x-user", "u1")
    |> testing.send(app)
  assert testing.json(res, listing()) == Ok(#(["B", "A"], 2))
  let res =
    testing.get("/notifications")
    |> testing.query([#("limit", "1"), #("before", a.id)])
    |> testing.header("x-user", "u1")
    |> testing.send(app)
  assert testing.json(res, listing()) == Ok(#([], 2))

  let unread = decode.field("unread", decode.int, decode.success)
  let res =
    testing.post("/notifications/" <> a.id <> "/read", json.null())
    |> testing.header("x-user", "u1")
    |> testing.send(app)
  assert testing.json(res, unread) == Ok(1)
  let res =
    testing.post("/notifications/" <> a.id <> "/read", json.null())
    |> testing.header("x-user", "u2")
    |> testing.send(app)
  assert res.status == 404
  let res =
    testing.post("/notifications/" <> a.id <> "/unread", json.null())
    |> testing.header("x-user", "u1")
    |> testing.send(app)
  assert testing.json(res, unread) == Ok(2)
  let res =
    testing.post("/notifications/read", json.null())
    |> testing.header("x-user", "u1")
    |> testing.send(app)
  assert testing.json(res, unread) == Ok(0)
  let res =
    testing.delete("/notifications/" <> a.id)
    |> testing.header("x-user", "u1")
    |> testing.send(app)
  assert testing.json(res, unread) == Ok(0)
  assert titles(notifier, "u1", notifications.page()) == ["B"]
}

pub fn forms_are_redirected_to_next_test() {
  let notifier = notifier()
  let _ = send(notifier, "u1", "A")
  let app = app(notifier)
  let res =
    testing.post_form("/notifications/read", [])
    |> testing.query([#("next", "/inbox?tab=all")])
    |> testing.header("x-user", "u1")
    |> testing.send(app)
  assert res.status == 303
  assert response.get_header(res, "location") == Ok("/inbox?tab=all")
  assert notifications.unread_count(notifier, "u1") == Ok(0)

  list.each(
    ["//evil.example", "https://evil.example", "/\\evil", "inbox"],
    fn(next) {
      let res =
        testing.post_form("/notifications/read", [])
        |> testing.query([#("next", next)])
        |> testing.header("x-user", "u1")
        |> testing.send(app)
      assert res.status == 400
    },
  )
}

pub fn the_event_stream_opens_with_the_count_and_follows_the_inbox_test() {
  let notifier = notifier()
  let _ = send(notifier, "u1", "Before")
  let res =
    testing.get("/notifications/events")
    |> testing.header("x-user", "u1")
    |> testing.send(app(notifier))
  assert res.status == 200
  let stream = testing.open_events(res)
  assert testing.next_event(stream)
    == Ok(sse.event("{\"count\":1}") |> sse.name("unread"))

  let sent = send(notifier, "u1", "After")
  let assert Ok(event) = testing.next_event(stream)
  assert event.name == Some("notification")
  assert event.data == json.to_string(notifications.to_json(sent))
  assert testing.next_event(stream)
    == Ok(sse.event("{\"count\":2}") |> sse.name("unread"))
  testing.close_events(stream)
  process.sleep(20)
  assert notifications.subscribers("u1") == 0

  let res = testing.get("/notifications/events") |> testing.send(app(notifier))
  assert res.status == 401
}

// -- Email -------------------------------------------------------------------

/// A mailer whose messages arrive on the returned subject. `fail` decides
/// whether each send fails, by its subject.
fn with_mail_failing(
  notifier,
  fail: fn(String) -> Result(Nil, mail.Error),
) -> #(notifications.Notifier, process.Subject(mail.Outgoing)) {
  let outbox = process.new_subject()
  let adapter =
    mail.adapter(named: "test", send: fn(outgoing: mail.Outgoing) {
      use Nil <- result.map(fail(outgoing.subject))
      process.send(outbox, outgoing)
      mail.Receipt(outgoing.id, None)
    })
  let mailer =
    mail.mailer(adapter)
    |> mail.default_from(mail.address("app@example.com"))
  let notifier =
    notifier
    |> notifications.with_base_url("https://example.com/")
    |> notifications.with_defaults(fn(_) {
      Delivery(..notifications.default_delivery, email: EmailNow)
    })
    |> notifications.with_email(
      mailer,
      address: fn(user) {
        case user {
          "nobody" -> Error(Nil)
          _ -> Ok(mail.address(user <> "@example.com"))
        }
      },
      render: fn(n) {
        mail.message()
        |> mail.subject(n.title)
        |> mail.text(n.body)
      },
    )
  #(notifier, outbox)
}

fn with_mail(notifier) {
  with_mail_failing(notifier, fn(_) { Ok(Nil) })
}

fn sent_subjects(outbox: process.Subject(mail.Outgoing)) -> List(String) {
  case process.receive(outbox, 0) {
    Ok(outgoing) -> [outgoing.subject, ..sent_subjects(outbox)]
    Error(Nil) -> []
  }
}

pub fn emails_are_sent_once_test() {
  let #(notifier, outbox) = with_mail(notifier())
  let _ = send(notifier, "u1", "Hello")
  assert deliver(notifier) == Drained(1, 0, 0, 0, 0)
  let assert Ok(outgoing) = process.receive(outbox, 0)
  assert outgoing.to == [mail.address("u1@example.com")]
  assert outgoing.subject == "Hello"
  assert deliver(notifier) == Drained(0, 0, 0, 0, 0)
  assert sent_subjects(outbox) == []
}

pub fn email_after_skips_what_was_read_first_test() {
  let #(notifier, outbox) = with_mail(notifier())
  let notifier = notifications.email_after(notifier, 60)
  let read = send(notifier, "u1", "Read in the app")
  let _ = send(notifier, "u1", "Not read")
  assert deliver(notifier) == Drained(0, 0, 0, 0, 0)
  assert notifications.mark_read(notifier, "u1", read.id) == Ok(Nil)
  advance(60_000)
  // The read one's job is cancelled rather than sent.
  assert deliver(notifier) == Drained(1, 0, 0, 1, 0)
  assert sent_subjects(outbox) == ["Not read"]
}

pub fn failed_emails_are_retried_then_given_up_test() {
  let #(notifier, outbox) =
    with_mail_failing(notifier(), fn(subject) {
      case subject {
        "Flaky" -> Error(mail.Unavailable("down"))
        "Refused" -> Error(mail.Refused("no"))
        _ -> Ok(Nil)
      }
    })
  let _ = send(notifier, "u1", "Flaky")
  let _ = send(notifier, "u1", "Refused")
  let _ = send(notifier, "nobody", "No address")
  // Two give up straight away; the flaky one is tried four more times,
  // 30 seconds after the first and doubling.
  assert deliver(notifier) == Drained(0, 1, 0, 0, 2)
  assert deliver(notifier) == Drained(0, 0, 0, 0, 0)
  advance(30_000)
  assert deliver(notifier) == Drained(0, 1, 0, 0, 0)
  advance(60_000)
  assert deliver(notifier) == Drained(0, 1, 0, 0, 0)
  advance(120_000)
  assert deliver(notifier) == Drained(0, 1, 0, 0, 0)
  advance(240_000)
  assert deliver(notifier) == Drained(0, 0, 0, 0, 1)
  advance(10_000_000)
  assert deliver(notifier) == Drained(0, 0, 0, 0, 0)
  assert sent_subjects(outbox) == []
}

pub fn a_notification_deleted_before_its_email_goes_is_not_sent_test() {
  let #(notifier, outbox) = with_mail(notifier())
  let notifier = notifications.email_after(notifier, 60)
  let gone = send(notifier, "u1", "Deleted")
  assert notifications.delete(notifier, "u1", gone.id) == Ok(Nil)
  advance(60_000)
  assert deliver(notifier) == Drained(0, 0, 0, 1, 0)
  assert sent_subjects(outbox) == []
}

pub fn digests_sent_in_a_burst_are_queued_once_test() {
  let #(notifier, _) = with_digest(notifier())
  let _ = send(notifier, "u1", "One")
  let _ = send(notifier, "u1", "Two")
  let _ = send(notifier, "u1", "Three")
  let assert Ok(waiting) =
    jobs.list(
      notifications.repo(notifier),
      jobs.listing() |> jobs.named("howdy_notifications.digest"),
    )
  assert list.length(waiting) == 1
}

pub fn a_render_that_crashes_gives_up_on_that_email_only_test() {
  let #(notifier, outbox) = with_mail(notifier())
  let notifier =
    notifications.with_email(
      notifier,
      mail.mailer(
        mail.adapter(named: "test", send: fn(outgoing: mail.Outgoing) {
          process.send(outbox, outgoing)
          Ok(mail.Receipt(outgoing.id, None))
        }),
      )
        |> mail.default_from(mail.address("app@example.com")),
      address: fn(user) { Ok(mail.address(user <> "@example.com")) },
      render: fn(n) {
        case n.title {
          "Bad" -> panic as "render failed"
          title -> mail.message() |> mail.subject(title) |> mail.text("")
        }
      },
    )
  let _ = send(notifier, "u1", "Bad")
  let _ = send(notifier, "u1", "Good")
  assert deliver(notifier) == Drained(1, 0, 0, 0, 1)
  assert sent_subjects(outbox) == ["Good"]
  advance(10_000_000)
  assert deliver(notifier) == Drained(0, 0, 0, 0, 0)
}

fn with_digest(notifier) {
  let #(notifier, outbox) = with_mail(notifier)
  let notifier =
    notifier
    |> notifications.with_defaults(fn(_) {
      Delivery(..notifications.default_delivery, email: EmailDigest)
    })
    |> notifications.with_digest(every: 3600, render: fn(all) {
      mail.message()
      |> mail.subject(
        list.map(all, fn(n: notifications.Notification) { n.title })
        |> string.join(", "),
      )
      |> mail.text("Digest")
    })
  #(notifier, outbox)
}

pub fn digests_gather_unread_notifications_test() {
  let #(notifier, outbox) = with_digest(notifier())
  let _ = send(notifier, "u1", "One")
  let read = send(notifier, "u1", "Read")
  let _ = send(notifier, "u1", "Two")
  let _ = send(notifier, "u2", "Other")
  assert notifications.mark_read(notifier, "u1", read.id) == Ok(Nil)

  // The first digest goes at once, one per user however many were sent;
  // read ones are left out.
  assert deliver(notifier) == Drained(2, 0, 0, 0, 0)
  assert list.sort(sent_subjects(outbox), string.compare)
    == ["One, Two", "Other"]

  // The next waits an hour.
  let _ = send(notifier, "u1", "Three")
  let _ = send(notifier, "u1", "Four")
  assert deliver(notifier) == Drained(0, 0, 0, 0, 0)
  advance(3_600_000)
  assert deliver(notifier) == Drained(1, 0, 0, 0, 0)
  assert sent_subjects(outbox) == ["Three, Four"]
  // Nothing waiting, nothing sent.
  advance(3_600_000)
  assert deliver(notifier) == Drained(0, 0, 0, 0, 0)
}

pub fn a_digest_of_only_read_notifications_is_not_sent_test() {
  let #(notifier, outbox) = with_digest(notifier())
  let read = send(notifier, "u1", "Read")
  assert notifications.mark_read(notifier, "u1", read.id) == Ok(Nil)
  // The digest job finds nothing to send.
  assert deliver(notifier) == Drained(1, 0, 0, 0, 0)
  assert deliver(notifier) == Drained(0, 0, 0, 0, 0)
  assert sent_subjects(outbox) == []
}

pub fn without_a_digest_digest_kinds_are_emailed_one_by_one_test() {
  let #(notifier, outbox) = with_mail(notifier())
  let notifier =
    notifications.with_defaults(notifier, fn(_) {
      Delivery(..notifications.default_delivery, email: EmailDigest)
    })
  let _ = send(notifier, "u1", "Alone")
  assert deliver(notifier).completed == 1
  assert sent_subjects(outbox) == ["Alone"]
}

pub fn url_uses_the_base_url_test() {
  let notifier =
    notifier() |> notifications.with_base_url("https://example.com/")
  let n = send(notifier, "u1", "A")
  assert notifications.url(notifier, n) == "https://example.com/"
  let n = notifications.Notification(..n, link: Some("/posts/1"))
  assert notifications.url(notifier, n) == "https://example.com/posts/1"
  let n = notifications.Notification(..n, link: Some("https://other.example/x"))
  assert notifications.url(notifier, n) == "https://other.example/x"
}

// -- Push --------------------------------------------------------------------

pub fn pushes_go_to_the_push_deliverer_test() {
  let pushed = process.new_subject()
  let notifier =
    notifier()
    |> notifications.with_push(fn(n) {
      process.send(pushed, n.title)
      case n.title {
        "Gone" -> GiveUp("no subscriptions")
        "Later" -> Retry("busy")
        _ -> Delivered
      }
    })
  let _ = send(notifier, "u1", "Hello")
  let _ = send(notifier, "u1", "Gone")
  let _ = send(notifier, "u1", "Later")
  let assert Ok(Nil) =
    notifications.set_preference(
      notifier,
      "u2",
      "comment.created",
      Delivery(inbox: True, email: NoEmail, push: False),
    )
  let _ = send(notifier, "u2", "Not pushed")
  assert deliver(notifier) == Drained(1, 1, 0, 0, 1)
  assert list.sort(drain(pushed), string.compare) == ["Gone", "Hello", "Later"]
  advance(30_000)
  assert deliver(notifier) == Drained(0, 1, 0, 0, 0)
  assert drain(pushed) == ["Later"]
}

fn drain(subject: process.Subject(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(value) -> [value, ..drain(subject)]
    Error(Nil) -> []
  }
}

// -- Running for real ------------------------------------------------------

pub fn a_running_runner_delivers_soon_after_a_send_test() {
  let #(notifier, outbox) = with_mail(notifications.new(open()))
  // A long interval, so only the wake-up from `send` can explain a quick
  // delivery.
  let runner =
    jobs.runner(notifications.repo(notifier))
    |> jobs.check_every(600_000)
    |> notifications.handle_jobs(notifier)
  let assert Ok(_) = jobs.start(runner)
  let assert Ok(Some(_)) =
    notifications.draft("x", "Quick") |> notifications.send(notifier, to: "u1")
  let assert Ok(outgoing) = process.receive(outbox, 2000)
  assert outgoing.subject == "Quick"
  jobs.stop(runner)
}
