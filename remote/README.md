# howdy_remote

Typed calls from one Howdy service to another, over Erlang distribution or
HTTP.

```sh
gleam add howdy_remote@2
```

## Procedures

A procedure is a name, an input codec and an output codec. Define each one
once, in a module both services import. A small shared package works best:
the caller and the server then always agree on names and types.

```gleam
import howdy/codec
import howdy/remote

pub fn get_user() -> remote.Procedure(Int, User) {
  remote.procedure("users.get", input: codec.int(), output: user())
}

fn user() -> codec.Codec(User) {
  codec.new(encode: user_to_json, decoder: user_decoder())
}
```

Codecs come from `howdy/codec` in the core package: `int`, `float`, `string`,
`bool`, `nil`, `list` and `optional` cover the simple cases. The name is all
that crosses the wire, so prefix names with the service, as in `"users.get"`.

Inputs and outputs travel as JSON and are decoded on arrival, even between
Erlang nodes. Two services deployed at different times can disagree on a
type. Decoding turns that into an error at the boundary, not an ill-typed
value that crashes somewhere else later. It also means one procedure works
over both transports.

## Serving

Handlers return `service.Result`, the same type controllers use, so one
service function can back an HTTP route and a procedure:

```gleam
let server =
  remote.server()
  |> remote.handle(users_api.get_user(), user_service.find)
  |> remote.handle(users_api.list_users(), fn(_) { user_service.all() })

// To every node in the cluster, over Erlang distribution:
let assert Ok(_) = remote.start(server)

// And/or over HTTP, as one `POST /rpc/<name>` route per procedure:
howdy.new()
|> howdy.controller(remote.controller(server, at: "/rpc", token: secret))
```

`start` links the server to the calling process; `supervised` gives a child
specification instead. Each call runs in its own process on the serving node,
so a slow or crashing handler affects only its own call. A node can run
several servers, and several nodes can serve the same procedure.

An `Internal` error's detail is logged on the serving node and never sent to
the caller. Over HTTP a crash's detail stays in the log too.

## Calling

```gleam
case remote.call(target, users_api.get_user(), 42, timeout: 5000) {
  Ok(user) -> ...
  Error(remote.Failed(service.NotFound(_))) -> ...  // the handler's own error
  Error(remote.NoHandler(_)) -> ...                 // nothing serves it
  Error(remote.Unavailable(_)) -> ...               // node down, HTTP failed
  Error(remote.Timeout) -> ...                      // it may still have run
  Error(remote.Crashed(_)) -> ...
  Error(remote.BadResponse(_)) -> ...               // output did not decode
  Error(remote.Refused) -> ...                      // HTTP token rejected
}
```

The target decides the route. Nothing else at the call site changes:

- `remote.cluster()`: any connected node serving the procedure. This node
  goes first; otherwise each call picks a node at random. Nodes appear and
  disappear as servers start and nodes connect or drop.
- `remote.node("users@10.0.0.5")`: one node, connected on first use.
- `remote.http("https://users.internal/rpc", token: secret)`: a server
  mounted with `controller`.

In a controller, `remote.respond` answers like `service.respond`. The
handler's own errors pass through, so a remote `NotFound` is still a `404`.
Transport failures become a logged `500`:

```gleam
use id <- param.int(ctx, "id")
remote.call(users, users_api.get_user(), id, timeout: 5000)
|> remote.respond(ctx, user.to_json)
```

Also available:

- `cast`: fire and forget.
- `multicall`: call every node serving a procedure in parallel, for example
  to clear caches everywhere.
- `providers`: which nodes serve a procedure, for health checks.
- `connect`: connect to a node ahead of the first call.
- `self`: this node's name.

## Plain Erlang and Elixir

`apply` calls any exported function on a node, for services that do not use
this package. Nothing checks the arguments; the result is checked with a
decoder:

```gleam
remote.apply(
  on: "billing@10.0.0.7",
  module: "Elixir.Billing",
  function: "balance",
  args: [dynamic.int(account_id)],
  decoder: decode.int,
  timeout: 5000,
)
```

## Running a cluster

Nodes need a name and a shared cookie:

```sh
ERL_FLAGS="-sname users -setcookie $COOKIE" gleam run -m users
ERL_FLAGS="-sname web -setcookie $COOKIE" gleam run -m web
```

Use `-name users@10.0.0.5` for nodes on different hosts. Connect each node to
one other with `remote.connect`, and Erlang connects the rest. Erlang does not
reconnect a lost node by itself; `examples/remote` retries every few seconds.

## Security

**Connected Erlang nodes trust each other completely.** A node holding the
cookie can run any code on yours, whatever this package allows. Use
`cluster` and `node` only between your own nodes on a private network, and
consider TLS distribution (`-proto_dist inet_tls`). Never expose the
distribution port (epmd's 4369 and the node's own port) to the internet.

Across a trust boundary, serve with `controller` and call with `http`. The
endpoint only runs the procedures you registered, requires
`authorization: Bearer <token>` (compared in constant time), and caps
request bodies at 1 MiB. Use a long random token and TLS. An empty token
refuses every request.
