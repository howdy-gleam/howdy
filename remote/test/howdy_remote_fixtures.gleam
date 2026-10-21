//// Procedures shared by the tests and the peer nodes they start, the way
//// two real services would share an API module.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import howdy/codec
import howdy/remote
import howdy/service

pub type User {
  User(id: Int, name: String)
}

pub fn user() -> codec.Codec(User) {
  codec.new(
    encode: fn(user: User) {
      json.object([
        #("id", json.int(user.id)),
        #("name", json.string(user.name)),
      ])
    },
    decoder: {
      use id <- decode.field("id", decode.int)
      use name <- decode.field("name", decode.string)
      decode.success(User(id:, name:))
    },
  )
}

pub fn get_user(prefix: String) -> remote.Procedure(Int, User) {
  remote.procedure(prefix <> ".users.get", input: codec.int(), output: user())
}

/// Which node served the call.
pub fn whoami(prefix: String) -> remote.Procedure(Nil, String) {
  remote.procedure(
    prefix <> ".whoami",
    input: codec.nil(),
    output: codec.string(),
  )
}

pub fn find_user(id: Int) -> service.Result(User) {
  case id {
    1 -> Ok(User(id: 1, name: "Ada"))
    _ -> Error(service.NotFound("user not found"))
  }
}

pub fn users_server(prefix: String) -> remote.Server {
  remote.server()
  |> remote.handle(get_user(prefix), find_user)
  |> remote.handle(whoami(prefix), fn(_) { Ok(remote.self()) })
}

/// Run on a peer node through `remote.apply`. The process `erpc` runs this
/// in exits abnormally once it has replied, so the server is unlinked from
/// it to outlive the call.
pub fn serve_users(prefix: String) -> Bool {
  let assert Ok(started) = remote.start(users_server(prefix))
  process.unlink(started.pid)
  True
}

/// Wait until `node` is among the providers of `procedure`, which takes a
/// moment after a server starts on another node.
pub fn await_provider(
  procedure: remote.Procedure(i, o),
  node: String,
  attempts: Int,
) -> Bool {
  case list.contains(remote.providers(procedure), node), attempts {
    True, _ -> True
    False, 0 -> False
    False, _ -> {
      process.sleep(20)
      await_provider(procedure, node, attempts - 1)
    }
  }
}

/// Poll until nothing serves `procedure` on `node` any more, as a stopped
/// server or node is noticed asynchronously.
pub fn await_no_provider(
  procedure: remote.Procedure(i, o),
  node: String,
  attempts: Int,
) -> Bool {
  case list.contains(remote.providers(procedure), node), attempts {
    False, _ -> True
    True, 0 -> False
    True, _ -> {
      process.sleep(20)
      await_no_provider(procedure, node, attempts - 1)
    }
  }
}

/// Run on a fresh peer through `remote.apply`: the first call it makes must
/// find a server on another node before `pg` has synced.
pub fn first_call_via_cluster(prefix: String) -> String {
  let assert Ok(node) =
    remote.call(remote.cluster(), whoami(prefix), Nil, timeout: 2000)
  node
}
