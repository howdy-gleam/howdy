//// Live checks that `howdy.tls` serves HTTPS with HTTP/2 offered through
//// ALPN, and that plaintext HTTP/2 with prior knowledge works without it.

import howdy
import howdy/controller

@external(erlang, "howdy_test_ffi", "test_certificate")
fn test_certificate() -> #(BitArray, BitArray)

/// Negotiated ALPN protocol and what the server answered.
@external(erlang, "howdy_test_ffi", "tls_probe")
fn tls_probe(port: Int, alpn: String) -> #(String, Outcome)

@external(erlang, "howdy_test_ffi", "h2c_probe")
fn h2c_probe(port: Int) -> Outcome

/// `settings` for an HTTP/2 SETTINGS frame, an integer for an HTTP/1.1 status.
type Outcome

@external(erlang, "erlang", "==")
fn same(a: Outcome, b: anything) -> Bool

fn app(port: Int) -> howdy.App {
  howdy.new()
  |> howdy.bind("127.0.0.1")
  |> howdy.listening(port)
  |> howdy.controller(
    controller.new("/")
    |> controller.get("/ok", fn(ctx) { controller.text(ctx, "ok") }),
  )
}

fn with_server(app: howdy.App, run: fn(Int) -> a) -> a {
  let assert Ok(started) = howdy.start(app)
  let result = run(started.data.port)
  howdy.stop(started.pid)
  result
}

pub fn tls_serves_http1_and_http2_over_alpn_test() {
  let #(cert, key) = test_certificate()
  use port <- with_server(app(0) |> howdy.tls_pem(cert:, key:))

  let #(protocol, outcome) = tls_probe(port, "h2")
  assert protocol == "h2"
  assert same(outcome, Settings)

  let #(protocol, outcome) = tls_probe(port, "http/1.1")
  assert protocol == "http/1.1"
  assert same(outcome, 200)
}

pub fn plaintext_http2_with_prior_knowledge_test() {
  use port <- with_server(app(0))
  assert same(h2c_probe(port), Settings)
}

type Settings {
  Settings
}
