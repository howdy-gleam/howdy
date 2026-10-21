//// The users service. It owns the data and offers it to the cluster over
//// Erlang distribution, and to callers outside the cluster over HTTP.
////
//// ```sh
//// ERL_FLAGS="-sname users -setcookie howdy" RPC_TOKEN=secret gleam run -m users
//// ```

import envoy
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/otp/static_supervisor as supervisor
import gleam/result
import howdy
import howdy/remote
import howdy/service
import users_api.{type User, User}

const users = [User(1, "Ada"), User(2, "Grace"), User(3, "Barbara")]

pub fn find(id: Int) -> service.Result(User) {
  list.find(users, fn(user) { user.id == id })
  |> result.replace_error(service.NotFound("user not found"))
}

pub fn server() -> remote.Server {
  remote.server()
  |> remote.handle(users_api.get_user(), find)
  |> remote.handle(users_api.list_users(), fn(_) { Ok(users) })
}

pub fn main() -> Nil {
  let server = server()
  // The procedure directory and, with a token, the HTTP transport run under
  // one supervisor inside an OTP application, so each is restarted on a
  // crash and SIGTERM stops them in order.
  let tree =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(remote.supervised(server))
  let tree = case envoy.get("RPC_TOKEN") {
    Ok(token) ->
      supervisor.add(
        tree,
        howdy.new()
          |> howdy.controller(remote.controller(server, at: "/rpc", token:))
          |> howdy.bind(to: "127.0.0.1")
          |> howdy.listening(on: 8788)
          |> howdy.supervised,
      )
    Error(Nil) -> {
      io.println("Set RPC_TOKEN to serve over HTTP as well")
      tree
    }
  }
  let assert Ok(_) = howdy.start_application(tree, name: "howdy_remote_users")
  io.println("Serving users procedures as " <> remote.self())

  process.sleep_forever()
}
