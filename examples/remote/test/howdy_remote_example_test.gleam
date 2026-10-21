//// Both services in one VM: the users server is started on this node and
//// the web app finds it through `remote.cluster()`, exactly as it would
//// across two nodes.

import gleam/dynamic/decode
import gleeunit
import howdy/remote
import howdy/testing
import users
import web

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn web_asks_the_users_service_test() {
  let assert Ok(_) = remote.start(users.server())
  let app = web.app(remote.cluster())

  let res = testing.get("/users/2") |> testing.send(app)
  assert res.status == 200
  assert testing.json(res, decode.at(["name"], decode.string)) == Ok("Grace")

  let res = testing.get("/users/9") |> testing.send(app)
  assert res.status == 404
  assert testing.error(res) == Ok("user not found")

  let res = testing.get("/users") |> testing.send(app)
  assert res.status == 200
  assert testing.json(res, decode.list(decode.at(["id"], decode.int)))
    == Ok([1, 2, 3])
}
