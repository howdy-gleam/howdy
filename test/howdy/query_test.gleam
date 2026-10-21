import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import howdy
import howdy/content.{type Content}
import howdy/controller
import howdy/query
import howdy/testing

fn app(handler: controller.Handler) -> howdy.App {
  howdy.new()
  |> howdy.controller(controller.new("/users") |> controller.get("/", handler))
}

/// Send a raw query string, so tests control the exact encoding.
fn send(raw: String, handler: controller.Handler) {
  testing.get("/users?" <> raw) |> testing.send(app(handler))
}

fn assert_bad_request(res: Response(Content), message: String) {
  assert res.status == 400
  assert response.get_header(res, "content-type")
    == Ok("application/json; charset=utf-8")
  assert testing.error(res) == Ok(message)
}

pub fn required_values_test() {
  let res =
    send("name=Ada&page=2&active=false", fn(ctx) {
      use name <- query.string(ctx, "name")
      use page <- query.int(ctx, "page")
      use active <- query.bool(ctx, "active")
      assert name == "Ada"
      assert page == 2
      assert active == False
      controller.text(ctx, "ok")
    })
  assert res.status == 200
  assert testing.text(res) == "ok"
}

pub fn defaults_test() {
  let res =
    send("", fn(ctx) {
      use name <- query.string_or(ctx, "name", default: "Ada")
      use page <- query.int_or(ctx, "page", default: 1)
      use active <- query.bool_or(ctx, "active", default: True)
      assert name == "Ada"
      assert page == 1
      assert active == True
      controller.text(ctx, "ok")
    })
  assert res.status == 200
}

pub fn present_values_override_defaults_test() {
  let res =
    send("name=&page=0&active=false", fn(ctx) {
      use name <- query.string_or(ctx, "name", default: "Ada")
      use page <- query.int_or(ctx, "page", default: 1)
      use active <- query.bool_or(ctx, "active", default: True)
      assert name == ""
      assert page == 0
      assert active == False
      controller.text(ctx, "ok")
    })
  assert res.status == 200
}

pub fn optional_values_test() {
  list.each(["", "name=&page=-2&active=true"], fn(raw) {
    let res =
      send(raw, fn(ctx) {
        use name <- query.optional_string(ctx, "name")
        use page <- query.optional_int(ctx, "page")
        use active <- query.optional_bool(ctx, "active")
        case raw {
          "" -> {
            assert name == None
            assert page == None
            assert active == None
          }
          _ -> {
            assert name == Some("")
            assert page == Some(-2)
            assert active == Some(True)
          }
        }
        controller.text(ctx, "ok")
      })
    assert res.status == 200
  })
}

pub fn required_missing_stops_handler_test() {
  list.each(
    [
      fn(ctx) {
        use _ <- query.string(ctx, "value")
        panic as "must not continue"
      },
      fn(ctx) {
        use _ <- query.int(ctx, "value")
        panic as "must not continue"
      },
      fn(ctx) {
        use _ <- query.bool(ctx, "value")
        panic as "must not continue"
      },
    ],
    fn(handler) {
      assert_bad_request(send("", handler), "missing query parameter value")
    },
  )
}

pub fn invalid_integers_never_continue_test() {
  list.each(["page=hello", "page=", "page=1.5"], fn(raw) {
    list.each(
      [
        fn(ctx) {
          use _ <- query.int(ctx, "page")
          panic as "must not continue"
        },
        fn(ctx) {
          use _ <- query.optional_int(ctx, "page")
          panic as "must not continue"
        },
        fn(ctx) {
          use _ <- query.int_or(ctx, "page", default: 1)
          panic as "must not continue"
        },
      ],
      fn(handler) {
        assert_bad_request(
          send(raw, handler),
          "query parameter page must be an integer",
        )
      },
    )
  })
}

pub fn invalid_booleans_never_continue_test() {
  list.each(["active=1", "active=True", "active="], fn(raw) {
    list.each(
      [
        fn(ctx) {
          use _ <- query.bool(ctx, "active")
          panic as "must not continue"
        },
        fn(ctx) {
          use _ <- query.optional_bool(ctx, "active")
          panic as "must not continue"
        },
        fn(ctx) {
          use _ <- query.bool_or(ctx, "active", default: True)
          panic as "must not continue"
        },
      ],
      fn(handler) {
        assert_bad_request(
          send(raw, handler),
          "query parameter active must be true or false",
        )
      },
    )
  })
}

pub fn duplicate_singular_keys_test() {
  list.each(
    [
      fn(ctx) {
        use _ <- query.string(ctx, "name")
        panic as "must not continue"
      },
      fn(ctx) {
        use _ <- query.optional_string(ctx, "name")
        panic as "must not continue"
      },
      fn(ctx) {
        use _ <- query.string_or(ctx, "name", default: "Ada")
        panic as "must not continue"
      },
    ],
    fn(handler) {
      assert_bad_request(
        send("name=Ada&%6Eame=Grace", handler),
        "query parameter name must occur only once",
      )
    },
  )
}

pub fn decoding_and_repeated_values_test() {
  let res =
    send("tag=gleam&other=x&tag=web+apps&tag=&name=Ada%20%26%20Grace", fn(ctx) {
      use tags <- query.strings(ctx, "tag")
      use absent <- query.strings(ctx, "absent")
      use name <- query.string(ctx, "name")
      assert tags == ["gleam", "web apps", ""]
      assert absent == []
      assert name == "Ada & Grace"
      controller.text(ctx, "ok")
    })
  assert res.status == 200
}

pub fn query_pairs_are_encoded_test() {
  let res =
    testing.get("/users")
    |> testing.query([#("name", "Ada & Grace"), #("tag", "a"), #("tag", "b")])
    |> testing.send(
      app(fn(ctx) {
        use name <- query.string(ctx, "name")
        use tags <- query.strings(ctx, "tag")
        assert name == "Ada & Grace"
        assert tags == ["a", "b"]
        controller.text(ctx, "ok")
      }),
    )
  assert res.status == 200
}

pub fn invalid_encoding_stops_handler_test() {
  let res =
    send("page=%GG", fn(ctx) {
      use _ <- query.int_or(ctx, "page", default: 1)
      panic as "must not continue"
    })
  assert_bad_request(res, "query string has invalid encoding")
}

pub fn absent_query_and_guarded_context_test() {
  let users =
    controller.guarded("/users", fn(_) { Ok("guard value") })
    |> controller.get("/", fn(ctx) {
      use page <- query.int_or(ctx, "page", default: 1)
      assert ctx.guard == "guard value"
      controller.text(ctx, int.to_string(page))
    })
    |> controller.build
  let res =
    testing.get("/users")
    |> testing.send(howdy.new() |> howdy.controller(users))
  assert res.status == 200
  assert testing.text(res) == "1"
}
