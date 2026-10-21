import howdy
import howdy/controller
import howdy/param
import howdy/testing

fn app() -> howdy.App {
  howdy.new()
  |> howdy.controller(
    controller.new("/users")
    |> controller.get("/:name", fn(ctx) {
      use name <- param.string(ctx, "name")
      controller.text(ctx, "user:" <> name)
    }),
  )
  |> howdy.controller(
    controller.new("/files")
    |> controller.get("/*path", fn(ctx) {
      use path <- param.string(ctx, "path")
      controller.text(ctx, "file:" <> path)
    }),
  )
}

pub fn captures_are_percent_decoded_test() {
  let res = testing.get("/users/john%20doe") |> testing.send(app())
  assert testing.text(res) == "user:john doe"
  let res = testing.get("/files/a%20b/c%2Bd.txt") |> testing.send(app())
  assert testing.text(res) == "file:a b/c+d.txt"
}

pub fn an_escaped_slash_or_nul_matches_nothing_test() {
  assert { testing.get("/users/a%2Fb") |> testing.send(app()) }.status == 404
  assert { testing.get("/users/a%00b") |> testing.send(app()) }.status == 404
  assert { testing.get("/files/a%2F..%2Fb") |> testing.send(app()) }.status
    == 404
}

pub fn a_malformed_escape_matches_nothing_test() {
  assert { testing.get("/users/a%zz") |> testing.send(app()) }.status == 404
}

pub fn literal_segments_are_not_decoded_test() {
  // `%75sers` is not `users`: literal segments match as written.
  assert { testing.get("/%75sers/ada") |> testing.send(app()) }.status == 404
}
