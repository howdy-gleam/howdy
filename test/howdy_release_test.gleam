import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import howdy
import howdy_release.{Life, Version}

pub fn versions_parse_and_order_test() {
  assert howdy_release.parse_version("2.10.3") == Ok(Version(2, 10, 3))
  assert howdy_release.parse_version("2.1") == Error(Nil)
  assert howdy_release.parse_version("v2.1.0") == Error(Nil)
  let assert Ok(a) = howdy_release.parse_version("2.9.0")
  let assert Ok(b) = howdy_release.parse_version("2.10.0")
  assert howdy_release.compare(a, b) == order.Lt
  assert howdy_release.compare(b, b) == order.Eq
}

fn api(modules: List(#(String, List(#(String, Bool))))) {
  dict.from_list(
    list.map(modules, fn(module) { #(module.0, dict.from_list(module.1)) }),
  )
}

pub fn since_follows_the_api_across_releases_test() {
  let first =
    howdy_release.update_since(
      dict.new(),
      [#("howdy_ui", api([#("howdy/ui/button", [#("button", False)])]))],
      "2.0.0",
    )
  let second =
    howdy_release.update_since(
      first,
      [
        #(
          "howdy_ui",
          api([
            #("howdy/ui/button", [#("button", True), #("sized", False)]),
            #("howdy/ui/kbd", [#("kbd", False)]),
          ]),
        ),
      ],
      "2.1.0",
    )
  let assert Ok(ui) = dict.get(second, "howdy_ui")
  let assert Ok(#(button, items)) = dict.get(ui, "howdy/ui/button")
  assert button == Life("2.0.0", None, None)
  assert dict.get(items, "button") == Ok(Life("2.0.0", Some("2.1.0"), None))
  assert dict.get(items, "sized") == Ok(Life("2.1.0", None, None))
  let assert Ok(#(kbd, _)) = dict.get(ui, "howdy/ui/kbd")
  assert kbd == Life("2.1.0", None, None)

  // A module that goes is kept, marked removed, with its items.
  let third =
    howdy_release.update_since(
      second,
      [#("howdy_ui", api([#("howdy/ui/button", [#("sized", False)])]))],
      "3.0.0",
    )
  let assert Ok(ui) = dict.get(third, "howdy_ui")
  let assert Ok(#(kbd, kbd_items)) = dict.get(ui, "howdy/ui/kbd")
  assert kbd.removed == Some("3.0.0")
  assert dict.get(kbd_items, "kbd") == Ok(Life("2.1.0", None, Some("3.0.0")))
  let assert Ok(#(_, items)) = dict.get(ui, "howdy/ui/button")
  assert dict.get(items, "button")
    == Ok(Life("2.0.0", Some("2.1.0"), Some("3.0.0")))

  // Written and read back unchanged.
  let text = json.to_string(howdy_release.since_to_json(third))
  assert json.parse(text, howdy_release.since_decoder()) == Ok(third)
}

pub fn since_drops_modules_marked_internal_test() {
  let first =
    howdy_release.update_since(
      dict.new(),
      [
        #(
          "howdy_auth",
          api([
            #("howdy/auth", [#("new", False)]),
            #("howdy/auth/internal/token", [#("sign", False)]),
          ]),
        ),
      ],
      "2.0.0",
    )
  // Marked internal, it leaves the interface: forgotten, not removed.
  let second =
    howdy_release.update_since(
      first,
      [#("howdy_auth", api([#("howdy/auth", [#("new", False)])]))],
      "2.2.0",
    )
  let assert Ok(auth) = dict.get(second, "howdy_auth")
  assert dict.keys(auth) == ["howdy/auth"]
}

pub fn pretty_json_keeps_strings_intact_test() {
  assert howdy_release.pretty("{\"a\":[1,2],\"b\":\"x,{y}:\\\"z\"}")
    == "{\n  \"a\": [\n    1,\n    2\n  ],\n  \"b\": \"x,{y}:\\\"z\"\n}"
  assert howdy_release.pretty("{\"a\":{}}") == "{\n  \"a\": {}\n}"
}

pub fn banner_version_matches_gleam_toml_test() {
  let assert Ok(versions) = howdy_release.package_versions()
  assert list.key_find(versions, "howdy") == Ok(howdy.version)
}
