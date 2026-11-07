//// Generated modules are written formatted, because `gleam format` doesn't
//// skip ignored files: an app's `gleam format --check src` would otherwise
//// fail on them, and `gleam format src` would put them out of date with
//// their templates.
////
//// The formatter changes whitespace and trailing commas, and sorts imports,
//// which the generator has already sorted. So the formatted module lines up
//// with the generated one byte for byte once whitespace and commas are
//// skipped, and that alignment carries positions between the two.

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// `length` bytes at `raw` in the generated code are the same bytes at
/// `formatted` in the formatted code.
pub type Run {
  Run(raw: Int, formatted: Int, length: Int)
}

pub type Formatted {
  Formatted(code: String, runs: List(Run))
}

/// Formats each module with `gleam format`, in one run. A module that
/// can't be formatted, or that doesn't line up after formatting, is
/// `Error(Nil)` and is written as generated.
pub fn format_all(codes: List(String)) -> List(Result(Formatted, Nil)) {
  case codes {
    [] -> []
    _ -> {
      let directory = temporary_directory()
      let paths =
        list.index_map(codes, fn(code, i) {
          let path = directory <> "/m" <> int.to_string(i) <> ".gleam"
          let _ = simplifile.write(path, code)
          path
        })
      let all_ok = run_format([directory])
      let results =
        list.zip(codes, paths)
        |> list.map(fn(pair) {
          let #(code, path) = pair
          // One module the formatter rejects can fail the whole run, so
          // the others are tried one at a time.
          let formatted = case all_ok {
            True -> True
            False -> run_format([path])
          }
          case formatted {
            False -> Error(Nil)
            True -> {
              use formatted <- result.try(
                simplifile.read(path) |> result.replace_error(Nil),
              )
              use runs <- result.map(align(code, formatted))
              Formatted(code: formatted, runs:)
            }
          }
        })
      let _ = simplifile.delete(directory)
      results
    }
  }
}

pub fn format(code: String) -> Result(Formatted, Nil) {
  case format_all([code]) {
    [result] -> result
    _ -> Error(Nil)
  }
}

/// Where a generated offset is in the formatted code. An offset in skipped
/// whitespace or a dropped comma goes to the start of the next run.
pub fn to_formatted(runs: List(Run), offset: Int) -> Int {
  find(runs, offset, fn(run) { run.raw }, fn(run) { run.formatted })
}

/// Where a formatted offset is in the generated code.
pub fn to_raw(runs: List(Run), offset: Int) -> Int {
  find(runs, offset, fn(run) { run.formatted }, fn(run) { run.raw })
}

fn find(
  runs: List(Run),
  offset: Int,
  from: fn(Run) -> Int,
  to: fn(Run) -> Int,
) -> Int {
  case runs {
    [] -> offset
    [run, ..rest] ->
      case offset < from(run) {
        True -> to(run)
        False ->
          case offset < from(run) + run.length {
            True -> to(run) + offset - from(run)
            False ->
              case rest {
                [] -> to(run) + run.length
                _ -> find(rest, offset, from, to)
              }
          }
      }
  }
}

/// Lines the two up, skipping whitespace and commas either side. Fails if
/// anything else differs.
pub fn align(raw: String, formatted: String) -> Result(List(Run), Nil) {
  align_loop(<<raw:utf8>>, <<formatted:utf8>>, 0, 0, [])
}

fn align_loop(
  raw: BitArray,
  formatted: BitArray,
  i: Int,
  j: Int,
  runs: List(Run),
) -> Result(List(Run), Nil) {
  case raw, formatted {
    <<>>, <<>> -> Ok(list.reverse(runs))
    <<a, raw_rest:bytes>>, _ if a == 32 || a == 10 || a == 9 || a == 13 ->
      align_loop(raw_rest, formatted, i + 1, j, runs)
    _, <<b, formatted_rest:bytes>> if b == 32 || b == 10 || b == 9 || b == 13 ->
      align_loop(raw, formatted_rest, i, j + 1, runs)
    <<a, raw_rest:bytes>>, <<b, formatted_rest:bytes>> if a == b ->
      align_loop(raw_rest, formatted_rest, i + 1, j + 1, extend(runs, i, j))
    <<44, raw_rest:bytes>>, _ -> align_loop(raw_rest, formatted, i + 1, j, runs)
    _, <<44, formatted_rest:bytes>> ->
      align_loop(raw, formatted_rest, i, j + 1, runs)
    _, _ -> Error(Nil)
  }
}

fn extend(runs: List(Run), i: Int, j: Int) -> List(Run) {
  case runs {
    [Run(raw:, formatted:, length:), ..rest]
      if raw + length == i && formatted + length == j
    -> [Run(raw:, formatted:, length: length + 1), ..rest]
    _ -> [Run(raw: i, formatted: j, length: 1), ..runs]
  }
}

fn temporary_directory() -> String {
  let directory =
    string.concat([
      system_temporary_directory(),
      "/howdy_templates_",
      int.to_string(unique()),
    ])
  let _ = simplifile.create_directory_all(directory)
  directory
}

@external(erlang, "howdy_templates_ffi", "temporary_directory")
fn system_temporary_directory() -> String

@external(erlang, "howdy_templates_ffi", "unique")
fn unique() -> Int

/// Runs `gleam format` on the paths; whether it succeeded.
@external(erlang, "howdy_templates_ffi", "format")
fn run_format(paths: List(String)) -> Bool
