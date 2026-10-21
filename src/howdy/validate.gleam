//// Validation of decoded input before it reaches a service.
////
//// Rules never change a value's type, so every field is checked and all
//// errors are reported together rather than stopping at the first.
////
//// ```gleam
//// pub fn validate(input: NewUserInput) -> validate.Result(NewUser) {
////   use name <- validate.field("name", input.name, [
////     validate.trim(),
////     validate.not_empty(),
////     validate.max_length(50),
////   ])
////   use age <- validate.field("age", input.age, [validate.min(13)])
////   validate.ok(NewUser(name:, age:))
//// }
//// ```

import gleam
import gleam/http/response.{type Response}
import gleam/list
import gleam/string
import howdy/content.{type Content}
import howdy/controller.{type GuardedContext}
import howdy/problem.{type Problem}
import howdy/service

/// One problem with one field.
pub type FieldError =
  service.FieldError

/// The outcome of validating a whole input.
pub type Result(a) =
  gleam.Result(a, List(FieldError))

/// A rule checks a value and may also normalise it, such as trimming. On
/// failure it returns the problem, which `howdy/problem` puts into words.
pub type Rule(a) =
  fn(a) -> gleam.Result(a, Problem)

/// Validate one field with a list of rules, run in order. The first failing
/// rule produces the field's error. The continuation always runs so that
/// later fields are checked too; its result is discarded if any field failed.
pub fn field(
  name: String,
  value: a,
  rules: List(Rule(a)),
  next: fn(a) -> Result(b),
) -> Result(b) {
  case run(rules, value) {
    Ok(value) -> next(value)
    Error(problem) ->
      case next(value) {
        Ok(_) -> Error([service.FieldError(name, problem)])
        Error(rest) -> Error([service.FieldError(name, problem), ..rest])
      }
  }
}

/// Finish a validator with the validated value.
pub fn ok(value: a) -> Result(a) {
  Ok(value)
}

/// Run a validation result in a handler. On failure a `422` is returned with
/// every field error and the continuation never runs.
pub fn check(
  ctx: GuardedContext(guarded),
  result: Result(a),
  next: fn(a) -> Response(Content),
) -> Response(Content) {
  case result {
    Ok(value) -> next(value)
    Error(errors) -> service.error_response(ctx, service.Validation(errors))
  }
}

/// Run rules against a value directly, without a field name.
pub fn run(rules: List(Rule(a)), value: a) -> gleam.Result(a, Problem) {
  list.try_fold(rules, value, fn(value, rule) { rule(value) })
}

// -- Rules -------------------------------------------------------------------

/// Build a rule from a predicate and the problem reported when it fails,
/// such as `problem.Custom("taken", "is already taken")`.
pub fn custom(check: fn(a) -> Bool, problem: Problem) -> Rule(a) {
  fn(value) {
    case check(value) {
      True -> Ok(value)
      False -> Error(problem)
    }
  }
}

/// Remove leading and trailing whitespace. Never fails. Put it before other
/// string rules so they see the trimmed value.
pub fn trim() -> Rule(String) {
  fn(value) { Ok(string.trim(value)) }
}

pub fn not_empty() -> Rule(String) {
  custom(fn(value) { value != "" }, problem.Blank)
}

pub fn min_length(length: Int) -> Rule(String) {
  custom(fn(value) { string.length(value) >= length }, problem.TooShort(length))
}

pub fn max_length(length: Int) -> Rule(String) {
  custom(fn(value) { string.length(value) <= length }, problem.TooLong(length))
}

/// A light check: something before and after a single `@`, and a dot in the
/// part after it. Deliberately permissive; only a delivery attempt can prove
/// an address.
pub fn email() -> Rule(String) {
  custom(
    fn(value) {
      case string.split(value, "@") {
        [local, domain] ->
          local != ""
          && string.contains(domain, ".")
          && !string.starts_with(domain, ".")
          && !string.ends_with(domain, ".")
        _ -> False
      }
    },
    problem.NotEmail,
  )
}

pub fn min(minimum: Int) -> Rule(Int) {
  custom(fn(value) { value >= minimum }, problem.TooSmall(minimum))
}

pub fn max(maximum: Int) -> Rule(Int) {
  custom(fn(value) { value <= maximum }, problem.TooLarge(maximum))
}

/// The value must be one of `allowed`. `show` writes each option for the
/// problem's `allowed`.
pub fn one_of(allowed: List(a), show: fn(a) -> String) -> Rule(a) {
  custom(
    fn(value) { list.contains(allowed, value) },
    problem.NotOneOf(list.map(allowed, show)),
  )
}
