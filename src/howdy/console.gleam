//// Values a running app hands to an interactive console.
////
//// A console such as [GSH](https://hexdocs.pm/gsh/) can attach to a running
//// Erlang node and run Gleam code inside it. That code can call any module,
//// but the database connection, auth configuration and other values `main`
//// built exist only as local variables there. `expose` publishes them under a
//// key so the console can `get` the very ones the server is using, rather than
//// building a second set that might be configured differently.
////
//// Declare each key once, as a function with its type written out, and use it
//// from both sides:
////
//// ```gleam
//// import howdy/console
////
//// pub type Services {
////   Services(db: Repo, identity: auth.Auth)
//// }
////
//// pub fn services() -> console.Key(Services) {
////   console.key("my_app")
//// }
////
//// pub fn main() {
////   let services = Services(db: database.connect(), identity: ...)
////   console.expose(services(), services)
////   ...
//// }
//// ```
////
//// In the console, `console.get(my_app.services())` returns the running
//// server's `Services`.
////
//// Values are kept in `persistent_term`: reading one is as cheap as reading a
//// constant, and exposing one again replaces it. Replacing makes the VM scan
//// every process, so expose values once at startup, not per request.

/// The name of a value exposed to the console, and its type.
pub opaque type Key(a) {
  Key(name: String)
}

/// A key for values of type `a`. The name is shared by every node running
/// the same code, so the key must be declared once, in one function whose
/// return type is written out: two keys with the same name and different
/// types would read each other's values as the wrong type.
pub fn key(name: String) -> Key(a) {
  Key(name:)
}

/// Make `value` available to consoles attached to this node, replacing any
/// value already exposed under the key.
pub fn expose(key: Key(a), value: a) -> Nil {
  put(key.name, value)
}

/// The value exposed under the key on this node. `Error(Nil)` when nothing
/// has been exposed yet, such as in a console on a node where the server was
/// never started.
pub fn get(key: Key(a)) -> Result(a, Nil) {
  fetch(key.name)
}

@external(erlang, "howdy_ffi", "console_put")
fn put(name: String, value: a) -> Nil

@external(erlang, "howdy_ffi", "console_get")
fn fetch(name: String) -> Result(a, Nil)
