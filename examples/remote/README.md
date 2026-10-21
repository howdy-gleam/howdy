# howdy_remote example

Two services. `users` owns the user data and serves it as procedures;
`web` is a public howdy app that has no data of its own and asks `users`
for it. `src/users_api.gleam` is the contract between them. In a real system
it would be a small package that both services depend on.

Over Erlang distribution, in two terminals:

```sh
cd examples/remote
ERL_FLAGS="-sname users -setcookie howdy" RPC_TOKEN=secret gleam run -m users
ERL_FLAGS="-sname web -setcookie howdy" gleam run -m web
```

```sh
curl http://localhost:8787/users/1   # {"id":1,"name":"Ada"}, served by the users node
curl -i http://localhost:8787/users/9  # 404, the users service's own NotFound
curl http://localhost:8787/users
```

`web` listens on 127.0.0.1:8787. Stop `users` and the same requests return a
logged `500`. Start it again and `web` reconnects within five seconds: a
supervised actor retries the connection on a timer.

Over HTTP instead, with `users` still running:

```sh
USERS_URL=http://localhost:8788/rpc RPC_TOKEN=secret gleam run -m web
curl -X POST http://localhost:8788/rpc/users.get -H 'authorization: Bearer secret' -d 2
```

Or run both services in one VM as a test:

```sh
gleam test
```
