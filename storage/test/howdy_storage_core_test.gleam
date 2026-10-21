import gleam/list
import gleam/string
import howdy/service
import howdy/storage
import howdy/storage/s3

pub fn new_keys_are_unguessable_and_keep_the_extension_test() {
  let key = storage.new_key(prefix: "avatars/", file_name: "Me & You.JPEG")
  assert string.starts_with(key, "avatars/")
  assert string.ends_with(key, ".jpeg")
  assert string.length(key) == string.length("avatars/") + 32 + 5
  assert storage.new_key(prefix: "avatars", file_name: "x.png") != key
  // Odd extensions are dropped rather than trusted.
  let key = storage.new_key(prefix: "", file_name: "evil.p<h>p")
  assert string.length(key) == 32
  assert string.length(storage.new_key(prefix: "", file_name: "no-extension"))
    == 32
  assert storage.valid_key(storage.new_key(prefix: "a/b", file_name: "c.txt"))
}

pub fn valid_keys_test() {
  list.each(["a", "a/b.txt", "ünï/cødé", "with space/and+plus"], fn(key) {
    assert storage.valid_key(key)
  })
  list.each(["", "/a", "a/", "a//b", ".", "a/..", "a\\b", "a\u{0}b"], fn(key) {
    assert !storage.valid_key(key)
  })
  assert storage.valid_key(string.repeat("a", 255))
  assert !storage.valid_key(string.repeat("a", 256))
}

pub fn attachment_test() {
  assert storage.attachment("report.pdf")
    == "attachment; filename=\"report.pdf\"; filename*=UTF-8''report.pdf"
  assert storage.attachment("naïve \"quote\" 100%.txt")
    == "attachment; filename=\"na_ve _quote_ 100_.txt\"; filename*=UTF-8''na%C3%AFve%20%22quote%22%20100%25.txt"
}

pub fn percent_encode_test() {
  assert storage.percent_encode("aZ09-._~ /+=é") == "aZ09-._~%20%2F%2B%3D%C3%A9"
}

pub fn errors_test() {
  assert storage.retryable(storage.Unavailable("x"))
  assert !storage.retryable(storage.Refused("x"))
  assert !storage.retryable(storage.NotFound)
  assert storage.to_service_error(storage.NotFound)
    == service.NotFound("file not found")
  assert storage.to_service_error(storage.Invalid("bad"))
    == service.Invalid("bad")
  let assert service.Internal(_) =
    storage.to_service_error(storage.Refused("no"))
}

pub fn from_env_test() {
  let names = [
    "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "S3_BUCKET", "BUCKET_NAME",
    "AWS_REGION", "AWS_DEFAULT_REGION", "AWS_ENDPOINT_URL_S3",
    "AWS_ENDPOINT_URL", "AWS_SESSION_TOKEN",
  ]
  list.each(names, unset)
  assert s3.from_env() == Error(s3.MissingVariable("AWS_ACCESS_KEY_ID"))
  set("AWS_ACCESS_KEY_ID", "AKID")
  set("AWS_SECRET_ACCESS_KEY", "secret")
  assert s3.from_env() == Error(s3.MissingVariable("S3_BUCKET or BUCKET_NAME"))
  set("BUCKET_NAME", "tigris-bucket")
  set("AWS_ENDPOINT_URL_S3", "https://fly.storage.tigris.dev")
  set("AWS_REGION", "auto")
  let assert Ok(config) = s3.from_env()
  let assert Ok(url) = storage.url(s3.adapter(config), "k", expires_in: 60)
  assert string.starts_with(
    url,
    "https://fly.storage.tigris.dev/tigris-bucket/k?",
  )
  assert string.contains(url, "%2Fauto%2Fs3%2F")
  list.each(names, unset)
}

@external(erlang, "os", "putenv")
fn putenv(name: List(Int), value: List(Int)) -> Bool

@external(erlang, "os", "unsetenv")
fn unsetenv(name: List(Int)) -> Bool

@external(erlang, "unicode", "characters_to_list")
fn chars(text: String) -> List(Int)

fn set(name: String, value: String) -> Nil {
  let _ = putenv(chars(name), chars(value))
  Nil
}

fn unset(name: String) -> Nil {
  let _ = unsetenv(chars(name))
  Nil
}
