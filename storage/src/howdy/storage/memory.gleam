//// Storage kept in one process, for tests. Everything is lost when the
//// process stops, and other nodes do not see it.
////
//// ```gleam
//// let files = memory.new()
//// let assert Ok(Nil) =
////   storage.put(files, "a.txt", <<"hi">>, content_type: "text/plain")
//// ```
////
//// Signed URLs are `memory:` followed by the key and the expiry, which no
//// browser can open; they let tests check that a URL was asked for.

import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import howdy/storage.{type Error, type Put, type Storage, Invalid, NotFound}
import howdy/storage/internal/page
import simplifile

/// Empty storage, in a process linked to the caller.
pub fn new() -> Storage {
  let assert Ok(started) =
    actor.new(dict.new())
    |> actor.on_message(handle)
    |> actor.start
    as "howdy/storage/memory: the storage process did not start"
  let subject = started.data
  storage.adapter(
    named: "memory",
    put: fn(put) {
      use stored <- result.try(stored(put))
      ask(subject, Save(put.key, stored, _))
    },
    get: fn(key) {
      ask(subject, Find(key, _)) |> result.map(fn(stored) { stored.bytes })
    },
    head: fn(key) {
      use stored <- result.map(ask(subject, Find(key, _)))
      storage.Object(
        key:,
        size: bit_array.byte_size(stored.bytes),
        content_type: stored.content_type,
        etag: stored.etag,
        last_modified: stored.last_modified,
      )
    },
    delete: fn(key) { ask(subject, Remove(key, _)) },
    list: fn(prefix, after, limit) {
      ask(subject, List(prefix, after, limit, _))
    },
    url: fn(request) {
      Ok(
        "memory:"
        <> request.key
        <> "?expires_in="
        <> int.to_string(request.expires_in),
      )
    },
  )
}

type Stored {
  Stored(
    bytes: BitArray,
    content_type: String,
    etag: String,
    last_modified: Timestamp,
  )
}

fn stored(put: Put) -> Result(Stored, Error) {
  use bytes <- result.map(case put.body {
    storage.Bytes(bytes) -> Ok(bytes)
    storage.File(path) ->
      simplifile.read_bits(path)
      |> result.map_error(fn(error) {
        Invalid(
          "cannot read " <> path <> ": " <> simplifile.describe_error(error),
        )
      })
  })
  Stored(
    bytes:,
    content_type: put.content_type,
    etag: crypto.hash(crypto.Md5, bytes)
      |> bit_array.base16_encode
      |> string.lowercase,
    last_modified: timestamp.system_time(),
  )
}

type Message {
  Save(key: String, stored: Stored, reply: Subject(Result(Nil, Error)))
  Find(key: String, reply: Subject(Result(Stored, Error)))
  Remove(key: String, reply: Subject(Result(Nil, Error)))
  List(
    prefix: String,
    after: Option(String),
    limit: Int,
    reply: Subject(Result(storage.Page, Error)),
  )
}

fn handle(
  objects: Dict(String, Stored),
  message: Message,
) -> actor.Next(Dict(String, Stored), Message) {
  case message {
    Save(key:, stored:, reply:) -> {
      process.send(reply, Ok(Nil))
      actor.continue(dict.insert(objects, key, stored))
    }
    Find(key:, reply:) -> {
      process.send(
        reply,
        dict.get(objects, key) |> result.replace_error(NotFound),
      )
      actor.continue(objects)
    }
    Remove(key:, reply:) -> {
      process.send(reply, Ok(Nil))
      actor.continue(dict.delete(objects, key))
    }
    List(prefix:, after:, limit:, reply:) -> {
      let matching =
        dict.to_list(objects)
        |> list.filter(fn(entry) { page.wanted(entry.0, prefix, after) })
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        |> list.map(fn(entry) {
          let #(key, stored) = entry
          storage.Summary(
            key:,
            size: bit_array.byte_size(stored.bytes),
            etag: stored.etag,
            last_modified: stored.last_modified,
          )
        })
      process.send(reply, Ok(page.of(matching, limit)))
      actor.continue(objects)
    }
  }
}

fn ask(
  subject: Subject(Message),
  message: fn(Subject(Result(a, Error))) -> Message,
) -> Result(a, Error) {
  let gone = storage.Unavailable("the memory storage process has stopped")
  case process.subject_owner(subject) {
    Error(Nil) -> Error(gone)
    Ok(pid) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(pid)
      process.send(subject, message(reply))
      let outcome =
        process.new_selector()
        |> process.select(reply)
        |> process.select_specific_monitor(monitor, fn(_) { Error(gone) })
        |> process.selector_receive(within: 5000)
      process.demonitor_process(monitor)
      case outcome {
        Ok(answer) -> answer
        Error(Nil) ->
          Error(storage.Unavailable("the memory storage did not answer"))
      }
    }
  }
}
