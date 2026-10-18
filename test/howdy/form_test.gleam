import gleam/http
import gleam/option.{None, Some}
import howdy
import howdy/controller
import howdy/form.{type Form}
import howdy/service.{FieldError}
import howdy/testing
import howdy/validate

type Signup {
  Signup(
    email: String,
    age: Int,
    nickname: option.Option(String),
    referrer: option.Option(Int),
    newsletter: Bool,
    tags: List(String),
  )
}

fn signup(fields: Form) -> validate.Result(Signup) {
  use email <- form.string(fields, "email", [validate.trim(), validate.email()])
  use age <- form.int(fields, "age", [validate.min(13)])
  use nickname <- form.optional_string(fields, "nickname", [
    validate.trim(),
    validate.max_length(5),
  ])
  use referrer <- form.optional_int(fields, "referrer", [validate.min(1)])
  use newsletter <- form.checkbox(fields, "newsletter")
  use tags <- form.strings(fields, "tags")
  validate.ok(Signup(email:, age:, nickname:, referrer:, newsletter:, tags:))
}

fn app(handler: controller.Handler) -> howdy.App {
  howdy.new()
  |> howdy.controller(
    controller.new("/signup") |> controller.post("/", handler),
  )
}

fn ok_handler(ctx) {
  use _fields <- form.read(ctx)
  controller.text(ctx, "ok")
}

// -- Reading -----------------------------------------------------------------

pub fn read_decodes_fields_in_order_test() {
  let res =
    testing.request(http.Post, "/signup")
    |> testing.text_body(
      "name=Ada+Lovelace&note=a%26b%3Dc&tags=x&tags=y&empty=",
    )
    |> testing.header(
      "content-type",
      "Application/X-WWW-Form-Urlencoded; charset=UTF-8",
    )
    |> testing.send(
      app(fn(ctx) {
        use fields <- form.read(ctx)
        assert form.fields(fields)
          == [
            #("name", "Ada Lovelace"),
            #("note", "a&b=c"),
            #("tags", "x"),
            #("tags", "y"),
            #("empty", ""),
          ]
        assert form.get(fields, "name") == Ok("Ada Lovelace")
        assert form.get(fields, "tags") == Ok("x")
        assert form.get(fields, "missing") == Error(Nil)
        assert form.all(fields, "tags") == ["x", "y"]
        assert form.all(fields, "missing") == []
        assert form.value(fields, "note") == "a&b=c"
        assert form.value(fields, "missing") == ""
        controller.text(ctx, "ok")
      }),
    )
  assert res.status == 200
}

pub fn post_form_round_trips_awkward_values_test() {
  let pairs = [#("q", "a b&c=d+e%"), #("name", "Zoë ✓"), #("q", "")]
  let res =
    testing.post_form("/signup", pairs)
    |> testing.send(
      app(fn(ctx) {
        use fields <- form.read(ctx)
        assert form.fields(fields) == pairs
        controller.text(ctx, "ok")
      }),
    )
  assert res.status == 200
}

pub fn empty_body_is_an_empty_form_test() {
  let res =
    testing.post_form("/signup", [])
    |> testing.send(
      app(fn(ctx) {
        use fields <- form.read(ctx)
        assert form.fields(fields) == []
        controller.text(ctx, "ok")
      }),
    )
  assert res.status == 200
}

pub fn other_content_types_are_rejected_test() {
  let res =
    testing.request(http.Post, "/signup")
    |> testing.text_body("a=1")
    |> testing.send(app(ok_handler))
  assert res.status == 415
  assert testing.error(res)
    == Ok(
      "content type must be application/x-www-form-urlencoded or multipart/form-data",
    )

  let res =
    testing.request(http.Post, "/signup")
    |> testing.bytes_body(<<"a=1":utf8>>)
    |> testing.send(app(ok_handler))
  assert res.status == 415
}

pub fn invalid_encoding_is_rejected_test() {
  let send = fn(bits) {
    testing.post_form("/signup", [])
    |> testing.bytes_body(bits)
    |> testing.send(app(ok_handler))
  }
  let res = send(<<"a=%zz":utf8>>)
  assert res.status == 400
  assert testing.error(res) == Ok("request body is not a valid urlencoded form")
  assert send(<<"a=%ff":utf8>>).status == 400
  assert send(<<"a=":utf8, 0xff>>).status == 400
}

pub fn body_over_the_limit_is_rejected_test() {
  let res =
    testing.post_form("/signup", [#("a", "12345")])
    |> testing.send(
      app(fn(ctx) {
        use _fields <- form.read_with_limit(ctx, 4)
        controller.text(ctx, "ok")
      }),
    )
  assert res.status == 400
  assert testing.error(res) == Ok("request body too large")
}

// -- Typed fields ------------------------------------------------------------

pub fn typed_fields_test() {
  let fields =
    form.from_fields([
      #("email", " ada@example.com "),
      #("age", "36"),
      #("nickname", " ada "),
      #("referrer", "7"),
      #("newsletter", "on"),
      #("tags", "maths"),
      #("tags", "engines"),
    ])
  assert signup(fields)
    == Ok(
      Signup(
        email: "ada@example.com",
        age: 36,
        nickname: Some("ada"),
        referrer: Some(7),
        newsletter: True,
        tags: ["maths", "engines"],
      ),
    )
}

pub fn absent_and_blank_optionals_are_none_test() {
  let expected =
    Ok(
      Signup(
        email: "ada@example.com",
        age: 36,
        nickname: None,
        referrer: None,
        newsletter: False,
        tags: [],
      ),
    )
  let required = [#("email", "ada@example.com"), #("age", "36")]
  assert signup(form.from_fields(required)) == expected
  assert signup(
      form.from_fields([#("nickname", ""), #("referrer", ""), ..required]),
    )
    == expected
  // Rules that leave nothing behind count as blank too.
  assert signup(form.from_fields([#("nickname", "   "), ..required]))
    == expected
}

pub fn every_field_error_is_reported_test() {
  let fields =
    form.from_fields([
      #("age", "old"),
      #("nickname", "far too long"),
      #("referrer", "0"),
    ])
  assert signup(fields)
    == Error([
      FieldError("email", "is required"),
      FieldError("age", "must be an integer"),
      FieldError("nickname", "must be at most 5 characters"),
      FieldError("referrer", "must be at least 1"),
    ])
}

pub fn blank_required_fields_test() {
  // A blank string is kept for the rules to judge; a blank int is missing.
  assert signup(form.from_fields([#("email", ""), #("age", "")]))
    == Error([
      FieldError("email", "must be a valid email address"),
      FieldError("age", "is required"),
    ])
}

pub fn repeated_singular_fields_are_rejected_test() {
  let fields =
    form.from_fields([
      #("email", "a@example.com"),
      #("email", "b@example.com"),
      #("age", "36"),
      #("age", "37"),
      #("nickname", "a"),
      #("nickname", "b"),
      #("referrer", "1"),
      #("referrer", "2"),
    ])
  assert signup(fields)
    == Error([
      FieldError("email", "must occur only once"),
      FieldError("age", "must occur only once"),
      FieldError("nickname", "must occur only once"),
      FieldError("referrer", "must occur only once"),
    ])
}

pub fn error_finds_a_fields_message_test() {
  let errors = [FieldError("email", "is required"), FieldError("age", "bad")]
  assert form.error(errors, "age") == Some("bad")
  assert form.error(errors, "name") == None
}

// -- Handlers ----------------------------------------------------------------

pub fn pages_can_render_errors_with_submitted_values_test() {
  let res =
    testing.post_form("/signup", [#("email", "nope"), #("age", "36")])
    |> testing.send(
      app(fn(ctx) {
        use fields <- form.read(ctx)
        case signup(fields) {
          Ok(_) -> controller.text(ctx, "welcome")
          Error(errors) -> {
            let assert Some(message) = form.error(errors, "email")
            controller.html(ctx, form.value(fields, "email") <> ": " <> message)
            |> controller.with_status(422)
          }
        }
      }),
    )
  assert res.status == 422
  assert testing.text(res) == "nope: must be a valid email address"
}

pub fn validated_test() {
  let handler = fn(ctx) {
    use signup <- form.validated(ctx, signup)
    controller.text(ctx, signup.email)
  }
  let res =
    testing.post_form("/signup", [#("email", "ada@example.com"), #("age", "36")])
    |> testing.send(app(handler))
  assert res.status == 200
  assert testing.text(res) == "ada@example.com"

  let res =
    testing.post_form("/signup", [#("email", "ada@example.com"), #("age", "9")])
    |> testing.send(app(handler))
  assert res.status == 422
  assert testing.field_errors(res)
    == Ok([FieldError("age", "must be at least 13")])
}
