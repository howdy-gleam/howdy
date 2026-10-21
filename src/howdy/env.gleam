//// Configuration from the process environment, read once at startup.
////
//// Howdy apps take their settings from environment variables in `main`,
//// build their configuration values from them, and pass those values into
//// the app. Nothing reads the environment per request.
////
//// ```gleam
//// pub fn main() -> Nil {
////   let port = env.int_or("PORT", 8787)
////   let assert Ok(database_url) = env.get("DATABASE_URL")
////   ...
//// }
//// ```
////
//// An unset variable and an empty one are both `Error(Nil)`: a deployment
//// that sets `SMTP_URL=` has not configured SMTP.

import gleam/int

/// The value of `name`, or `Error(Nil)` when it is unset or empty.
pub fn get(name: String) -> Result(String, Nil) {
  case getenv(name) {
    Ok("") -> Error(Nil)
    other -> other
  }
}

/// The value of `name`, or `default` when it is unset or empty.
pub fn get_or(name: String, default: String) -> String {
  case get(name) {
    Ok(value) -> value
    Error(Nil) -> default
  }
}

/// The value of `name` as an integer, or `Error(Nil)` when it is unset,
/// empty or not a whole number.
pub fn int(name: String) -> Result(Int, Nil) {
  case get(name) {
    Ok(value) -> int.parse(value)
    Error(Nil) -> Error(Nil)
  }
}

/// The value of `name` as an integer, or `default` when it is unset, empty
/// or not a whole number.
pub fn int_or(name: String, default: Int) -> Int {
  case int(name) {
    Ok(value) -> value
    Error(Nil) -> default
  }
}

/// Whether `name` is set to `true`, `1`, `yes` or `on`, in any case.
pub fn flag(name: String) -> Bool {
  case get(name) {
    Ok("true")
    | Ok("TRUE")
    | Ok("True")
    | Ok("1")
    | Ok("yes")
    | Ok("YES")
    | Ok("on")
    | Ok("ON") -> True
    _ -> False
  }
}

@external(erlang, "howdy_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)
