//// Run with `gleam run` from the `examples/openapi` directory. It listens on
//// 127.0.0.1:8787: open http://localhost:8787/docs for the API reference, or
//// try:
////
//// ```sh
//// curl http://localhost:8787/openapi.json
//// curl http://localhost:8787/user?min_age=30      # v1, the default
//// curl http://localhost:8787/v2/user?min_age=30   # v2 wraps the list
//// curl http://localhost:8787/openapi/v2.json
//// curl -X POST http://localhost:8787/user -d '{"name":"Linus","email":"linus@example.com","age":28}'
//// curl -i -X POST http://localhost:8787/user -d '{"name":" ","email":"nope","age":"5"}'   # 422
//// curl -i http://localhost:8787/user/abc   # 400
//// ```

import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import howdy
import howdy/logger
import howdy/openapi
import howdy/version
import logging
import user/controller as user_controller
import user/controller_v2 as user_controller_v2

pub fn app() -> howdy.App {
  // The API's own version. Each version's document shows it with the
  // version's name beside it: `1.0.0 (v1)`, `1.0.0 (v2)`.
  let spec =
    openapi.new(title: "Users API", version: "1.0.0")
    |> openapi.description("A small user directory, documented by Howdy.")
    |> openapi.api_key_header("api_key", header: "x-api-key")

  // Versions come from the path, as in `/v2/user`. v2 only declares what
  // changed and falls back to v1 for the rest. A path without a version
  // gets v1.
  let api =
    version.new(version.path())
    |> version.default("v1")
    |> version.add("v1", [user_controller.controller()])
    |> version.add("v2", [user_controller_v2.controller()])

  howdy.new()
  |> howdy.middleware(logger.log)
  |> howdy.versions(api)
  // After the controllers it documents. Serves /openapi.json (v1, the
  // default) and /openapi/v1.json and /openapi/v2.json.
  |> openapi.serve(spec, at: "/openapi.json")
  |> openapi.reference(at: "/docs", document: "/openapi.json")
}

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Info)

  // Supervised inside an OTP application: restarted on a crash, drained on
  // SIGTERM. A local demo, so it listens on 127.0.0.1:8787 only.
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(howdy.supervised(app() |> howdy.bind(to: "127.0.0.1")))
    |> howdy.start_application(name: "howdy_openapi_server")

  process.sleep_forever()
}
