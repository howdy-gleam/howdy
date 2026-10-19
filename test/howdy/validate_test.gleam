import gleam/dict
import gleam/int
import gleam/option.{None}
import howdy/context.{Context}
import howdy/controller.{type Context}
import howdy/problem
import howdy/service.{FieldError}
import howdy/testing
import howdy/validate

type Input {
  Input(name: String, email: String, age: Int)
}

type Valid {
  Valid(name: String, email: String, age: Int)
}

fn validate_input(input: Input) -> validate.Result(Valid) {
  use name <- validate.field("name", input.name, [
    validate.trim(),
    validate.not_empty(),
    validate.max_length(10),
  ])
  use email <- validate.field("email", input.email, [validate.email()])
  use age <- validate.field("age", input.age, [
    validate.min(13),
    validate.max(150),
  ])
  validate.ok(Valid(name:, email:, age:))
}

pub fn valid_input_test() {
  assert validate_input(Input("  Ada ", "ada@example.com", 36))
    == Ok(Valid("Ada", "ada@example.com", 36))
}

pub fn collects_every_field_error_test() {
  assert validate_input(Input("   ", "nope", 5))
    == Error([
      FieldError("name", problem.Blank),
      FieldError("email", problem.NotEmail),
      FieldError("age", problem.TooSmall(13)),
    ])
}

pub fn first_failing_rule_wins_test() {
  // Both not_empty and max_length would fail on a long-enough string only
  // for max_length; an empty string fails not_empty first.
  assert validate_input(Input("", "a@b.co", 20))
    == Error([FieldError("name", problem.Blank)])
  assert validate_input(Input("a very long name", "a@b.co", 20))
    == Error([FieldError("name", problem.TooLong(10))])
}

// -- individual rules --------------------------------------------------------

pub fn min_length_test() {
  assert validate.run([validate.min_length(3)], "ab")
    == Error(problem.TooShort(3))
  assert validate.run([validate.min_length(3)], "abc") == Ok("abc")
}

pub fn max_test() {
  assert validate.run([validate.max(150)], 151) == Error(problem.TooLarge(150))
  assert validate.run([validate.max(150)], 150) == Ok(150)
}

pub fn email_test() {
  let ok = fn(s) { validate.run([validate.email()], s) == Ok(s) }
  assert ok("a@b.co")
  assert ok("first.last+tag@sub.example.org")
  assert !ok("nope")
  assert !ok("@b.co")
  assert !ok("a@b")
  assert !ok("a@.co")
  assert !ok("a@b.")
  assert !ok("a@b@c.co")
}

pub fn one_of_test() {
  let rule = validate.one_of([1, 2, 3], int.to_string)
  assert validate.run([rule], 2) == Ok(2)
  assert validate.run([rule], 9) == Error(problem.NotOneOf(["1", "2", "3"]))
}

pub fn custom_test() {
  let even =
    validate.custom(
      fn(n) { n % 2 == 0 },
      problem.Custom("even", "must be even"),
    )
  assert validate.run([even], 3)
    == Error(problem.Custom("even", "must be even"))
  assert validate.run([even], 4) == Ok(4)
}

pub fn rules_run_in_order_and_transform_test() {
  // trim runs first, so not_empty sees "" and fails.
  assert validate.run([validate.trim(), validate.not_empty()], "   ")
    == Error(problem.Blank)
  // Without trim the padded string passes not_empty untouched.
  assert validate.run([validate.not_empty()], "   ") == Ok("   ")
}

// -- check / response --------------------------------------------------------

fn ctx() -> Context {
  Context(
    request: testing.get("/"),
    params: dict.new(),
    guard: Nil,
    version: None,
  )
}

pub fn check_ok_runs_continuation_test() {
  let res = {
    use valid <- validate.check(
      ctx(),
      validate_input(Input("Ada", "a@b.co", 30)),
    )
    controller.text(ctx(), valid.name)
  }
  assert testing.text(res) == "Ada"
}

pub fn check_error_returns_422_with_fields_test() {
  let res = {
    use _ <- validate.check(ctx(), validate_input(Input("", "a@b.co", 5)))
    panic as "continuation must not run"
  }
  assert res.status == 422
  assert testing.error(res) == Ok("validation failed")
  assert testing.field_errors(res)
    == Ok([
      FieldError("name", problem.Blank),
      FieldError("age", problem.TooSmall(13)),
    ])
}

pub fn service_can_return_validation_error_test() {
  let res =
    service.respond(
      Error(
        service.Validation([
          FieldError("email", problem.Custom("taken", "already taken")),
        ]),
      ),
      ctx(),
      fn(_) { panic as "no value to encode" },
    )
  assert res.status == 422
  assert testing.field_errors(res)
    == Ok([FieldError("email", problem.Custom("taken", "already taken"))])
}
