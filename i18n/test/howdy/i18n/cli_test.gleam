import gleam/dynamic/decode
import gleam/json
import gleam/string
import howdy/i18n/cli
import simplifile

pub fn add_keeps_json_control_characters_test() {
  let directory = "build/howdy_i18n_cli_control_test"
  let _ = simplifile.delete(directory)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let text = "a\u{8}b\u{c}c\u{0}d\n\r\t\"\\"
  let source = json.object([#("greeting", json.string(text))]) |> json.to_string
  let assert Ok(Nil) = simplifile.write(directory <> "/en.json", source)
  let added = cli.execute(["add", "de", "--locales=" <> directory])
  let generated = simplifile.read(directory <> "/de.json")
  let assert Ok(Nil) = simplifile.delete(directory)
  let assert Ok(_) = added
  let assert Ok(generated) = generated
  assert json.parse(generated, decode.at(["greeting"], decode.string))
    == Ok(text)
}

pub fn add_rejects_paths_as_locale_tags_test() {
  let directory = "build/howdy_i18n_cli_safe_tag_test"
  let escaped = "build/howdy_i18n_cli_escape.json"
  let _ = simplifile.delete(directory)
  let assert Ok(False) = simplifile.is_file(escaped)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let assert Ok(Nil) = simplifile.write(directory <> "/en.json", "{}")
  let added =
    cli.execute(["add", "../howdy_i18n_cli_escape", "--locales=" <> directory])
  let assert Ok(Nil) = simplifile.delete(directory)
  let assert Error(error) = added
  assert string.starts_with(error, "invalid locale ")
  assert simplifile.is_file(escaped) == Ok(False)
  let assert Error(error) = cli.execute(["add", "de", "--source=../escape"])
  assert string.starts_with(error, "invalid source locale ")
}
