import gleam/option.{None, Some}
import howdy/env
import howdy/url

@external(erlang, "howdy_test_ffi", "putenv")
fn putenv(name: String, value: String) -> Nil

@external(erlang, "howdy_test_ffi", "unsetenv")
fn unsetenv(name: String) -> Nil

pub fn unset_and_empty_are_both_missing_test() {
  unsetenv("HOWDY_ENV_TEST")
  assert env.get("HOWDY_ENV_TEST") == Error(Nil)
  putenv("HOWDY_ENV_TEST", "")
  assert env.get("HOWDY_ENV_TEST") == Error(Nil)
  assert env.get_or("HOWDY_ENV_TEST", "fallback") == "fallback"
  putenv("HOWDY_ENV_TEST", "set")
  assert env.get("HOWDY_ENV_TEST") == Ok("set")
  unsetenv("HOWDY_ENV_TEST")
}

pub fn integers_and_flags_test() {
  putenv("HOWDY_ENV_INT", "8080")
  assert env.int("HOWDY_ENV_INT") == Ok(8080)
  putenv("HOWDY_ENV_INT", "eighty")
  assert env.int("HOWDY_ENV_INT") == Error(Nil)
  assert env.int_or("HOWDY_ENV_INT", 1) == 1
  putenv("HOWDY_ENV_FLAG", "Yes")
  assert !env.flag("HOWDY_ENV_FLAG")
  putenv("HOWDY_ENV_FLAG", "yes")
  assert env.flag("HOWDY_ENV_FLAG")
  putenv("HOWDY_ENV_FLAG", "0")
  assert !env.flag("HOWDY_ENV_FLAG")
  unsetenv("HOWDY_ENV_INT")
  unsetenv("HOWDY_ENV_FLAG")
}

pub fn url_credentials_test() {
  assert url.credentials(None) == Ok(None)
  assert url.credentials(Some("ada")) == Ok(Some(#("ada", None)))
  assert url.credentials(Some("ada:s%3Acret"))
    == Ok(Some(#("ada", Some("s:cret"))))
  assert url.credentials(Some("ada:")) == Ok(Some(#("ada", Some(""))))
  assert url.credentials(Some(":x")) == Error(Nil)
  assert url.credentials(Some("a%zz")) == Error(Nil)
}

pub fn local_hosts_test() {
  assert url.is_local("localhost")
  assert url.is_local("127.0.0.1")
  assert url.is_local("::1")
  assert url.is_local("db")
  assert !url.is_local("db.internal")
  assert !url.is_local("2001:db8::1")
}
