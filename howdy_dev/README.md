# howdy_dev

Hot reload for [howdy](https://github.com/howdy-gleam/howdy/blob/v1.0.0/README.md) apps in development.

```sh
gleam add --dev howdy_dev
```

Add a development entry point and run it with `gleam dev`:

```gleam
// dev/my_app_dev.gleam
import gleam/erlang/process
import howdy/dev
import my_app

pub fn main() {
  let assert Ok(_) = dev.start(my_app.app)
  process.sleep_forever()
}
```

`my_app.app` is the function that builds your `howdy.App`. Pass it by name
rather than calling it: the server rebuilds the app from it for every
request, which is how a reloaded module takes effect at once.

## Development access

The development listener defaults to `127.0.0.1`, overriding the app's bind
address. Pages and reload connections accept only the exact hosts `localhost`,
`127.0.0.1` and `[::1]` by default. Reload requires a same-origin browser request
and a random token generated once per server run. HTML responses containing the
token use `Cache-Control: no-store`. Refresh the page after restarting the
development server to obtain its new token.

To deliberately expose development pages on a trusted network:

```gleam
dev.new(my_app.app)
|> dev.bind(to: "0.0.0.0")
|> dev.allow_hosts(["dev.example.test"])
|> dev.run
```

Host entries are names without ports (bracket IPv6 literals), not URLs or
wildcards. Anyone able to fetch an allowed development page can obtain its reload
token and see compiler diagnostics. The token protects against blind socket
connections; it is not user authentication. Keep network exposure restricted to
trusted clients. Each development server has a separate reload channel.

## What happens on a change

1. Every file under `src` is checked four times a second for a changed
   size, modification time or contents. Contents are checksummed so a
   same-size edit in the same second is not missed. This is plain polling, so
   it needs no native file watcher and behaves the same on Linux, macOS and
   Windows.
2. On a change, `gleam build` runs.
3. If it succeeds, the modules whose compiled code changed are loaded into
   the running VM, and every open page reloads over a WebSocket that the
   server adds to each HTML response.
4. If it fails, the compiler output is printed in the terminal and shown
   over the page. The previous code keeps serving until the next
   successful build.

Watch more directories with `dev.new(my_app.app) |> dev.watch("priv/static")
|> dev.run`, and change the polling rate with `dev.interval`.

## Staying out of production

`howdy_dev` is a dev dependency and the entry point lives in `dev/`.
`gleam export erlang-shipment` includes neither, so a deployed app has no
reload code in it. `gleam run` starts `src/my_app.gleam` as usual.

## Limits

- Processes started once in `main`, such as a shared live runtime, keep
  running the code they were started with. Erlang ends them when that code
  is purged, which happens two reloads later. Restart `gleam dev` after
  changing them.
- Changes to `dev/`, `test/`, `gleam.toml` or dependencies need a restart.
- WebSocket connections other than the reload socket are closed by a
  reload. Live components from `howdy_ui` reconnect on their own.
