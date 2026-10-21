import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/string
import howdy/testing
import howdy/websocket/presence
import howdy_chat_example.{app, people}

pub fn room_starts_empty_test() {
  let res = testing.get("/rooms/lobby") |> testing.send(app())

  let members = {
    use members <- decode.field("members", decode.int)
    decode.success(members)
  }
  assert res.status == 200
  assert testing.json(res, members) == Ok(0)
}

pub fn announce_is_accepted_test() {
  let res =
    testing.post(
      "/rooms/lobby/announce",
      json.object([#("text", json.string("hi"))]),
    )
    |> testing.send(app())

  assert res.status == 202
}

pub fn chat_requires_a_name_test() {
  let res = testing.get("/chat/lobby") |> testing.send(app())

  assert res.status == 400
  assert testing.error(res) == Ok("missing query parameter name")
}

pub fn chat_cannot_upgrade_without_a_connection_test() {
  let res = testing.get("/chat/lobby?name=Ada") |> testing.send(app())

  assert res.status == 426
}

pub fn the_presence_client_is_served_test() {
  let res = testing.get("/howdy/presence.js") |> testing.send(app())

  assert res.status == 200
  assert string.contains(testing.text(res), "export class Presence")
}

pub fn members_counts_people_not_tabs_test() {
  let room = "room:counted"
  let first = process.spawn_unlinked(fn() { process.sleep_forever() })
  let second = process.spawn_unlinked(fn() { process.sleep_forever() })
  let here = howdy_chat_example.Here(name: "Ada", typing: False)
  presence.track(people(), first, room, key: "Ada", meta: here)
  presence.track(people(), second, room, key: "Ada", meta: here)

  let res = testing.get("/rooms/counted") |> testing.send(app())

  let members = decode.field("members", decode.int, decode.success)
  assert testing.json(res, members) == Ok(1)
  process.kill(first)
  process.kill(second)
}
