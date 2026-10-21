import gleam/erlang/process
import howdy/testing

pub fn cleanup_runs_after_the_test_and_keeps_its_result_test() {
  let cleaned = process.new_subject()
  let result = {
    use <- testing.cleanup(fn() { process.send(cleaned, "cleaned") })
    "the result"
  }
  assert result == "the result"
  assert process.receive(cleaned, 0) == Ok("cleaned")
}

pub fn cleanup_runs_when_the_test_crashes_test() {
  let cleaned = process.new_subject()
  let crashed =
    rescue(fn() {
      use <- testing.cleanup(fn() { process.send(cleaned, "cleaned") })
      panic as "an assertion failed"
    })
  // The crash still happens, after the cleanup.
  assert crashed == Error(Nil)
  assert process.receive(cleaned, 0) == Ok("cleaned")
}

fn rescue(run: fn() -> a) -> Result(a, Nil) {
  case howdy_rescue(run) {
    Ok(value) -> Ok(value)
    Error(_) -> Error(Nil)
  }
}

@external(erlang, "howdy_ffi", "rescue")
fn howdy_rescue(run: fn() -> a) -> Result(a, String)
