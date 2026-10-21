import howdy/console

type Services {
  Services(port: Int, name: String)
}

fn services() -> console.Key(Services) {
  console.key("howdy_console_test.services")
}

pub fn missing_until_exposed_test() {
  let key: console.Key(Int) = console.key("howdy_console_test.never")
  assert console.get(key) == Error(Nil)
}

pub fn expose_then_get_test() {
  console.expose(services(), Services(port: 8787, name: "first"))
  assert console.get(services()) == Ok(Services(port: 8787, name: "first"))

  console.expose(services(), Services(port: 8788, name: "second"))
  assert console.get(services()) == Ok(Services(port: 8788, name: "second"))
}

pub fn exposes_functions_test() {
  let key: console.Key(fn(Int) -> Int) = console.key("howdy_console_test.fn")
  console.expose(key, fn(n) { n * 2 })
  let assert Ok(double) = console.get(key)
  assert double(21) == 42
}
