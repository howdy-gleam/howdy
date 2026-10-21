//// Dispatch-only benchmark: run with `gleam run -m routing_benchmark`.

import gleam/http
import gleam/http/response
import gleam/int
import gleam/list
import howdy
import howdy/controller
import howdy/testing
import howdy/version

pub fn main() {
  use count <- list.each([1, 32, 128, 512])
  let controllers =
    list.repeat(Nil, count)
    |> list.index_map(fn(_, i) { i + 1 })
    |> list.map(fn(i) {
      controller.new("/r" <> int.to_string(i))
      |> controller.middleware(fn(ctx, next) {
        next(ctx) |> response.set_header("x-controller", "yes")
      })
      |> controller.get("/:id", fn(ctx) { controller.text(ctx, "get") })
      |> controller.post("/:id", fn(ctx) { controller.text(ctx, "post") })
    })
  let app =
    list.fold(controllers, howdy.new(), howdy.controller)
    |> howdy.middleware(fn(ctx, next) {
      next(ctx) |> response.set_header("x-app", "yes")
    })
    |> howdy.controller(
      controller.new("/files")
      |> controller.get("/*path", fn(ctx) { controller.text(ctx, "file") }),
    )
    |> howdy.versions(
      version.new(version.path()) |> version.add("v1", controllers),
    )
  let serve = howdy.serve(app)
  let last = "/r" <> int.to_string(count) <> "/42"
  let requests = [
    testing.get("/r1/42"),
    testing.get(last),
    testing.get("/missing"),
    testing.delete(last),
    testing.request(http.Options, last),
    testing.get("/files/a/b"),
    testing.get("/v1" <> last),
  ]
  let expected = [200, 200, 404, 405, 204, 200, 200]
  assert list.map(requests, fn(req) { serve(req).status }) == expected
  measure(
    int.to_string(count),
    fn(index) {
      let assert Ok(req) = list.first(list.drop(requests, index))
      serve(req).status
    },
    list.length(requests),
  )
}

@external(erlang, "routing_benchmark_ffi", "measure")
fn measure(label: String, request: fn(Int) -> Int, cases: Int) -> Nil
