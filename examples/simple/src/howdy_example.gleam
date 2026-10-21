//// Run with `gleam run` from the `examples/simple` directory. It listens on
//// 127.0.0.1:8787, so try:
////
//// ```sh
//// curl http://localhost:8787/                 # index.html from priv/public
//// curl -i http://localhost:8787/style.css
//// curl http://localhost:8787/user/all
//// curl http://localhost:8787/user/2
//// curl -X POST http://localhost:8787/user -d '{"name":"Linus","email":"linus@example.com","age":28}'
//// curl -i -X POST http://localhost:8787/user -d '{"name":" ","email":"nope","age":5}'   # 422
//// curl -i http://localhost:8787/user/abc         # 400 from param.int
//// curl -i -X DELETE http://localhost:8787/user/2   # 401 without the key
//// curl -i -X DELETE http://localhost:8787/user/2 -H 'x-api-key: secret'
//// curl -i -X OPTIONS http://localhost:8787/user -H 'Origin: http://localhost:5173' -H 'Access-Control-Request-Method: POST'   # CORS preflight
//// for i in 1 2 3 4; do curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8787/user -H 'x-api-key: secret' -d '{"name":"A","email":"a@b.co","age":20}'; done   # 3 x 201 then 429
//// ```

import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import howdy
import howdy/cors
import howdy/logger
import howdy/rate_limit
import howdy/static
import logging
import user/controller as user_controller

/// The app, separate from the server so tests can send requests through it
/// with `howdy/testing`. See `test/user_controller_test.gleam`.
pub fn app() -> howdy.App {
  // Limiters own shared counters, so create them where the app is built,
  // which main does once, rather than inside a handler.
  let api = rate_limit.fixed_window(limit: 100, per_seconds: 60)

  // A browser app served from a Vite dev server may call this API.
  let cors =
    cors.new()
    |> cors.allow_origins(["http://localhost:5173"])
    |> cors.allow_headers(["content-type", "x-api-key"])
    |> cors.max_age(600)

  howdy.new()
  // Logs requests that reach the middleware pipeline.
  |> howdy.middleware(logger.log)
  // Outermost of the rest, so preflights are answered before the rate
  // limiter or any auth middleware can reject them.
  |> howdy.middleware(cors.middleware(cors))
  // Everyone gets 100 requests a minute, counted by client IP.
  |> howdy.middleware(rate_limit.by_ip(api))
  |> howdy.controller(user_controller.controller())
  // Files under priv/public are served at the site root. Mounted last, so
  // it only answers paths no other controller does.
  |> howdy.controller(static.serve("/", from: "priv/public"))
}

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Info)

  // The server runs under a supervisor inside an OTP application, so a
  // crash restarts it and SIGTERM lets open requests finish before exit.
  // A local demo, so it listens on 127.0.0.1:8787 only.
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(howdy.supervised(app() |> howdy.bind(to: "127.0.0.1")))
    |> howdy.start_application(name: "howdy_example_server")

  process.sleep_forever()
}
