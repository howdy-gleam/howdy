import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import gleam/string
import howdy/mail
import howdy/mail/outbox
import simplifile

fn mailer(box: outbox.Outbox) -> mail.Mailer {
  mail.mailer(outbox.adapter(box))
  |> mail.default_from(mail.address("hello@acme.test"))
}

fn message(to: String, subject: String) -> mail.Message {
  mail.message()
  |> mail.to([mail.address(to)])
  |> mail.subject(subject)
  |> mail.html("<p>" <> subject <> "</p>")
  |> mail.text(subject)
  |> mail.tag("test")
}

fn temporary_directory() -> String {
  let directory =
    "build/test-outbox-" <> int.to_string(int.random(1_000_000_000))
  let _ = simplifile.delete(directory)
  directory
}

pub fn keeps_messages_newest_first_test() {
  let box = outbox.start()
  let assert Ok(first) = mail.send(mailer(box), message("a@example.com", "One"))
  let assert Ok(_) = mail.send(mailer(box), message("b@example.com", "Two"))
  let assert Ok([newest, oldest]) = outbox.messages(box)
  assert newest.subject == "Two"
  assert oldest.subject == "One"
  assert outbox.get(box, first.id) == Ok(oldest)
  let assert Ok(latest) = outbox.latest_to(box, "A@Example.com")
  assert latest.subject == "One"
  assert outbox.latest_to(box, "nobody@example.com") == Error(Nil)
  assert outbox.directory(box) == None
  assert outbox.clear(box) == Ok(Nil)
  assert outbox.messages(box) == Ok([])
}

pub fn keeps_only_the_newest_test() {
  let box = outbox.start()
  int.range(from: 1, to: outbox.capacity + 4, with: Nil, run: fn(_, n) {
    let assert Ok(_) =
      mail.send(mailer(box), message("a@example.com", int.to_string(n)))
    Nil
  })
  let assert Ok(messages) = outbox.messages(box)
  assert list.length(messages) == outbox.capacity
  let assert [newest, ..] = messages
  assert newest.subject == int.to_string(outbox.capacity + 3)
}

pub fn subscribers_hear_about_changes_test() {
  let box = outbox.start()
  let heard = process.new_subject()
  outbox.subscribe(box, fn() { process.send(heard, Nil) })
  let assert Ok(_) = mail.send(mailer(box), message("a@example.com", "One"))
  assert process.receive(heard, 1000) == Ok(Nil)
  assert outbox.clear(box) == Ok(Nil)
  assert process.receive(heard, 1000) == Ok(Nil)
}

pub fn subscribers_are_dropped_when_they_exit_test() {
  let box = outbox.start()
  let heard = process.new_subject()
  let done = process.new_subject()
  process.spawn(fn() {
    outbox.subscribe(box, fn() { process.send(heard, Nil) })
    process.send(done, Nil)
  })
  let assert Ok(Nil) = process.receive(done, 1000)
  process.sleep(50)
  let assert Ok(_) = mail.send(mailer(box), message("a@example.com", "One"))
  assert process.receive(heard, 100) == Error(Nil)
}

pub fn a_crashing_subscriber_does_not_stop_the_outbox_test() {
  let box = outbox.start()
  outbox.subscribe(box, fn() { panic as "boom" })
  let assert Ok(_) = mail.send(mailer(box), message("a@example.com", "One"))
  let assert Ok(_) = mail.send(mailer(box), message("a@example.com", "Two"))
  let assert Ok(messages) = outbox.messages(box)
  assert list.length(messages) == 2
}

pub fn directory_survives_a_restart_test() {
  let directory = temporary_directory()
  let assert Ok(box) = outbox.start_in(directory)
  assert outbox.directory(box) == Some(directory)
  let assert Ok(_) =
    mail.send(
      mailer(box),
      message("a@example.com", "Grüße")
        |> mail.cc([mail.named("C", "c@example.com")])
        |> mail.reply_to(mail.address("r@acme.test"))
        |> mail.header("X-Test", "yes")
        |> mail.attach(
          mail.attachment("a.bin", "application/octet-stream", <<0, 1, 2, 255>>)
          |> mail.inline("a"),
        ),
    )
  let assert Ok(_) = mail.send(mailer(box), message("b@example.com", "Two"))
  let assert Ok(files) = simplifile.read_directory(directory)
  assert list.count(files, string.ends_with(_, ".eml")) == 2
  assert list.count(files, string.ends_with(_, ".json")) == 2

  let before = outbox.messages(box)
  let assert Ok(again) = outbox.start_in(directory)
  assert outbox.messages(again) == before

  assert outbox.clear(again) == Ok(Nil)
  let assert Ok(files) = simplifile.read_directory(directory)
  assert files == []
  let _ = simplifile.delete(directory)
}

pub fn unreadable_files_are_skipped_test() {
  let directory = temporary_directory()
  let assert Ok(_) = simplifile.create_directory_all(directory)
  let assert Ok(_) = simplifile.write(directory <> "/junk.json", "{not json")
  let assert Ok(box) = outbox.start_in(directory)
  assert outbox.messages(box) == Ok([])
  let _ = simplifile.delete(directory)
}

pub fn a_directory_that_cannot_be_created_is_an_error_test() {
  let directory = temporary_directory()
  let assert Ok(_) = simplifile.create_directory_all(directory)
  let assert Ok(_) = simplifile.write(directory <> "/file", "")
  let assert Error(reason) = outbox.start_in(directory <> "/file/mail")
  assert string.starts_with(reason, "cannot create ")
  let _ = simplifile.delete(directory)
}

pub fn a_supervised_outbox_answers_and_is_restarted_test() {
  let #(box, child) = outbox.supervised()
  // Before the supervisor starts it, the outbox is unavailable, not a crash.
  assert outbox.messages(box)
    == Error(mail.Unavailable("the outbox is not running"))
  assert outbox.latest_to(box, "a@example.com") == Error(Nil)
  let assert Error(mail.Unavailable(_)) =
    mail.send(mailer(box), message("a@example.com", "One"))

  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(child)
    |> static_supervisor.start
  let assert Ok(_) = mail.send(mailer(box), message("a@example.com", "One"))
  let assert Ok([one]) = outbox.messages(box)
  assert one.subject == "One"

  // A crash loses the memory but not the handle.
  let assert [first] = children(supervisor.pid)
  process.kill(first)
  let second = await_restart(supervisor.pid, first)
  assert second != first
  assert outbox.messages(box) == Ok([])
  let assert Ok(_) = mail.send(mailer(box), message("a@example.com", "Two"))
  let assert Ok([two]) = outbox.messages(box)
  assert two.subject == "Two"

  process.unlink(supervisor.pid)
  process.send_exit(supervisor.pid)
  await_stopped(box)
  assert outbox.messages(box)
    == Error(mail.Unavailable("the outbox is not running"))
}

pub fn a_supervised_directory_outbox_keeps_its_messages_across_restarts_test() {
  let directory = temporary_directory()
  let #(box, child) = outbox.supervised_in(directory)
  assert outbox.directory(box) == Some(directory)
  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(child)
    |> static_supervisor.start
  let assert Ok(_) = mail.send(mailer(box), message("a@example.com", "One"))
  let assert [first] = children(supervisor.pid)
  process.kill(first)
  let _ = await_restart(supervisor.pid, first)
  let assert Ok([one]) = outbox.messages(box)
  assert one.subject == "One"
  process.unlink(supervisor.pid)
  process.send_exit(supervisor.pid)
  let _ = simplifile.delete(directory)
}

pub fn an_outbox_that_stops_mid_call_is_unavailable_test() {
  let box = outbox.start()
  let assert Ok(_) = mail.send(mailer(box), message("a@example.com", "One"))
  let assert Ok(pid) = outbox_pid(box)
  process.unlink(pid)
  process.kill(pid)
  await_stopped(box)
  assert outbox.messages(box)
    == Error(mail.Unavailable("the outbox is not running"))
  assert outbox.clear(box)
    == Error(mail.Unavailable("the outbox is not running"))
  assert outbox.get(box, "x") == Error(Nil)
  // Subscribing to a stopped outbox is quietly nothing.
  outbox.subscribe(box, fn() { Nil })
}

@external(erlang, "howdy_mail_test_ffi", "children")
fn children(supervisor: process.Pid) -> List(process.Pid)

/// The pid of the child the supervisor started in place of `old`, polling
/// rather than sleeping a fixed time.
fn await_restart(supervisor: process.Pid, old: process.Pid) -> process.Pid {
  poll(50, fn() {
    case children(supervisor) {
      [new] if new != old -> Ok(new)
      _ -> Error(Nil)
    }
  })
}

fn await_stopped(box: outbox.Outbox) -> Nil {
  poll(50, fn() {
    case outbox.messages(box) {
      Error(mail.Unavailable(_)) -> Ok(Nil)
      _ -> Error(Nil)
    }
  })
}

fn poll(attempts: Int, check: fn() -> Result(a, Nil)) -> a {
  case check(), attempts {
    Ok(value), _ -> value
    Error(Nil), 0 -> panic as "condition not met in time"
    Error(Nil), _ -> {
      process.sleep(20)
      poll(attempts - 1, check)
    }
  }
}

fn outbox_pid(box: outbox.Outbox) -> Result(process.Pid, Nil) {
  outbox.pid(box)
}
