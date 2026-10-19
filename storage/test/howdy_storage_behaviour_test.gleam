//// Every adapter must behave the same. Each test runs against memory, a
//// local folder and, when `HOWDY_STORAGE_TEST_S3_URL` is set, an S3
//// service such as `http://key:secret@127.0.0.1:9000/bucket`.

import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleam/uri
import howdy/env
import howdy/storage.{type Storage, Invalid, NotFound}
import howdy/storage/internal/sigv4
import howdy/storage/local
import howdy/storage/memory
import howdy/storage/s3
import simplifile

/// Run `check` against every adapter, each under a fresh prefix.
fn each_adapter(check: fn(Storage, String) -> a) -> Nil {
  let run = random_name()
  let _ = check(memory.new(), "")
  let directory = "build/test-storage-" <> run
  let _ =
    check(
      local.new(directory)
        |> local.serve(at: "/files", secret: "s")
        |> local.adapter,
      "",
    )
  let _ = simplifile.delete(directory)
  case s3_config() {
    Ok(config) -> {
      let _ = check(s3.adapter(config), "run-" <> run <> "/")
      Nil
    }
    Error(Nil) -> Nil
  }
}

/// The S3 service to test against, with its bucket created.
pub fn s3_config() -> Result(s3.Config, Nil) {
  use #(config, parsed, bucket, key, secret) <- result.map(s3_settings())
  create_bucket(parsed, bucket, key, secret)
  config
}

/// The S3 service to test against with another bucket, which is not created.
pub fn s3_config_for(bucket: String) -> Result(s3.Config, Nil) {
  use #(_, parsed, _, key, secret) <- result.map(s3_settings())
  s3.new(
    bucket:,
    region: region(parsed),
    access_key_id: key,
    secret_access_key: secret,
  )
  |> s3.endpoint(endpoint(parsed))
}

fn s3_settings() -> Result(#(s3.Config, uri.Uri, String, String, String), Nil) {
  use url <- result.try(env.get("HOWDY_STORAGE_TEST_S3_URL"))
  let assert Ok(parsed) = uri.parse(url)
  let assert Some(userinfo) = parsed.userinfo
  let assert Ok(#(key, secret)) = string.split_once(userinfo, ":")
  let bucket = string.remove_prefix(parsed.path, "/")
  let config =
    s3.new(
      bucket:,
      region: region(parsed),
      access_key_id: key,
      secret_access_key: secret,
    )
    |> s3.endpoint(endpoint(parsed))
  Ok(#(config, parsed, bucket, key, secret))
}

/// The region to sign for, from `?region=` on the URL, such as `garage`
/// for Garage, else `us-east-1`.
fn region(parsed: uri.Uri) -> String {
  let query = option.unwrap(parsed.query, "") |> uri.parse_query
  case query {
    Ok(pairs) -> list.key_find(pairs, "region") |> result.unwrap("us-east-1")
    Error(Nil) -> "us-east-1"
  }
}

fn endpoint(parsed: uri.Uri) -> String {
  let assert Some(host) = parsed.host
  option.unwrap(parsed.scheme, "http")
  <> "://"
  <> host
  <> case parsed.port {
    Some(port) -> ":" <> int.to_string(port)
    None -> ""
  }
}

fn create_bucket(parsed: uri.Uri, bucket: String, key: String, secret: String) {
  let assert Some(host) = parsed.host
  let request =
    request.new()
    |> request.set_method(http.Put)
    |> request.set_scheme(case parsed.scheme {
      Some("https") -> http.Https
      _ -> http.Http
    })
    |> request.set_host(host)
    |> fn(r) { request.Request(..r, port: parsed.port) }
    |> request.set_path("/" <> bucket)
    |> request.set_body(<<>>)
    |> sigv4.sign(
      [],
      sigv4.Credentials(key, secret, None, region(parsed)),
      timestamp.system_time(),
    )
  // Already existing is fine.
  let assert Ok(_) = httpc.dispatch_bits(httpc.configure(), request)
  Nil
}

@external(erlang, "howdy_storage_ffi", "random_name")
fn random_name() -> String

// -- Behaviour ---------------------------------------------------------------

pub fn put_get_and_head_test() {
  use files, prefix <- each_adapter
  let key = prefix <> "notes/hello.txt"
  let assert Ok(Nil) =
    storage.put(files, key, <<"hello":utf8>>, content_type: "text/plain")
  assert storage.get(files, key) == Ok(<<"hello":utf8>>)
  let assert Ok(object) = storage.head(files, key)
  assert object.key == key
  assert object.size == 5
  assert object.content_type == "text/plain"
  assert object.etag != ""
  assert storage.exists(files, key) == Ok(True)

  let assert Ok(Nil) =
    storage.put(files, key, <<"replaced":utf8>>, content_type: "text/markdown")
  assert storage.get(files, key) == Ok(<<"replaced":utf8>>)
  let assert Ok(replaced) = storage.head(files, key)
  assert replaced.content_type == "text/markdown"
  assert replaced.etag != object.etag
  let assert Ok(Nil) = storage.delete(files, key)
}

pub fn put_file_test() {
  use files, prefix <- each_adapter
  let path = "build/test-upload-" <> random_name()
  let content = random_bytes(70_000)
  let assert Ok(Nil) = simplifile.write_bits(path, content)
  let key = prefix <> "uploads/data.bin"
  let assert Ok(Nil) =
    storage.put_file(files, key, path, content_type: "application/octet-stream")
  assert storage.get(files, key) == Ok(content)
  // The source file is left alone.
  assert simplifile.read_bits(path) == Ok(content)
  let assert Ok(Nil) = simplifile.delete(path)
  let assert Ok(Nil) = storage.delete(files, key)
}

pub fn missing_objects_test() {
  use files, prefix <- each_adapter
  let key = prefix <> "nothing/here.txt"
  assert storage.get(files, key) == Error(NotFound)
  assert storage.head(files, key) == Error(NotFound)
  assert storage.exists(files, key) == Ok(False)
  // Deleting what is not there succeeds.
  assert storage.delete(files, key) == Ok(Nil)
}

pub fn delete_test() {
  use files, prefix <- each_adapter
  let key = prefix <> "gone/soon.txt"
  let assert Ok(Nil) =
    storage.put(files, key, <<1>>, content_type: "text/plain")
  assert storage.delete(files, key) == Ok(Nil)
  assert storage.get(files, key) == Error(NotFound)
}

pub fn awkward_keys_test() {
  use files, prefix <- each_adapter
  let keys = [
    prefix <> "spaces and/ünïcødé & $+=?#%.txt",
    prefix <> "tilde~/(brackets)[x]'quote'.txt",
  ]
  list.each(keys, fn(key) {
    let assert Ok(Nil) =
      storage.put(files, key, <<key:utf8>>, content_type: "text/plain")
    assert storage.get(files, key) == Ok(<<key:utf8>>)
  })
  let assert Ok(page) = storage.list(files, prefix:, after: None, limit: 10)
  assert list.map(page.objects, fn(object) { object.key })
    |> list.sort(string.compare)
    == list.sort(keys, string.compare)
  list.each(keys, fn(key) {
    let assert Ok(Nil) = storage.delete(files, key)
  })
}

pub fn list_test() {
  use files, prefix <- each_adapter
  let keys = ["a/1.txt", "a/2.txt", "a/3.txt", "ab.txt", "b/1.txt"]
  list.each(keys, fn(key) {
    let assert Ok(Nil) =
      storage.put(
        files,
        prefix <> key,
        <<key:utf8>>,
        content_type: "text/plain",
      )
  })
  let keys_of = fn(page: storage.Page) {
    list.map(page.objects, fn(object) {
      string.remove_prefix(object.key, prefix)
    })
  }
  let assert Ok(all) =
    storage.list(files, prefix: prefix, after: None, limit: 1000)
  assert keys_of(all) == keys
  assert all.next == None
  let assert [first, ..] = all.objects
  assert first.size == 7

  let assert Ok(page) =
    storage.list(files, prefix: prefix <> "a", after: None, limit: 2)
  assert keys_of(page) == ["a/1.txt", "a/2.txt"]
  assert page.next == Some(prefix <> "a/2.txt")
  let assert Ok(page) =
    storage.list(files, prefix: prefix <> "a", after: page.next, limit: 2)
  assert keys_of(page) == ["a/3.txt", "ab.txt"]
  let assert Ok(page) =
    storage.list(files, prefix: prefix <> "a/", after: None, limit: 10)
  assert keys_of(page) == ["a/1.txt", "a/2.txt", "a/3.txt"]

  list.each(keys, fn(key) {
    let assert Ok(Nil) = storage.delete(files, prefix <> key)
  })
}

pub fn deleting_unused_objects_test() {
  use files, prefix <- each_adapter
  let put = fn(key) {
    let assert Ok(Nil) =
      storage.put(
        files,
        prefix <> key,
        <<"x":utf8>>,
        content_type: "text/plain",
      )
    Nil
  }
  put("uploads/kept.txt")
  put("uploads/orphan-1.txt")
  put("uploads/orphan-2.txt")
  put("avatars/elsewhere.txt")
  // Nothing is old enough yet.
  let assert Ok(0) =
    storage.delete_unused(
      files,
      prefix: prefix <> "uploads/",
      before: timestamp.add(timestamp.system_time(), duration.hours(-1)),
      in_use: fn(_) { False },
    )
  let later = timestamp.add(timestamp.system_time(), duration.minutes(1))
  let assert Ok(2) =
    storage.delete_unused(
      files,
      prefix: prefix <> "uploads/",
      before: later,
      in_use: fn(key) { string.ends_with(key, "kept.txt") },
    )
  let assert Ok(True) = storage.exists(files, prefix <> "uploads/kept.txt")
  let assert Ok(False) = storage.exists(files, prefix <> "uploads/orphan-1.txt")
  let assert Ok(True) = storage.exists(files, prefix <> "avatars/elsewhere.txt")
  let _ = storage.delete(files, prefix <> "uploads/kept.txt")
  let _ = storage.delete(files, prefix <> "avatars/elsewhere.txt")
}

pub fn invalid_keys_are_refused_test() {
  use files, _prefix <- each_adapter
  list.each(
    ["", "/a", "a/", "a//b", "a/./b", "a/../b", "..", "a\\b", "a\nb"],
    fn(key) {
      let assert Error(Invalid(_)) =
        storage.put(files, key, <<1>>, content_type: "text/plain")
      let assert Error(Invalid(_)) = storage.get(files, key)
      let assert Error(Invalid(_)) = storage.url(files, key, expires_in: 60)
    },
  )
  let assert Error(Invalid(_)) =
    storage.put(files, "a.txt", <<1>>, content_type: "text/plain\r\nx: y")
  let assert Error(Invalid(_)) =
    storage.put(files, string.repeat("a", 1025), <<1>>, content_type: "x/y")
}

pub fn signed_urls_test() {
  use files, prefix <- each_adapter
  let key = prefix <> "share/report.txt"
  let assert Ok(Nil) =
    storage.put(files, key, <<"report":utf8>>, content_type: "text/plain")
  let assert Ok(url) = storage.url(files, key, expires_in: 300)
  assert url != ""
  let assert Ok(_) =
    storage.download_url(files, key, expires_in: 300, file_name: "Report.txt")
  let assert Error(Invalid(_)) = storage.url(files, key, expires_in: 0)
  let assert Error(Invalid(_)) =
    storage.url(files, key, expires_in: storage.max_expiry + 1)
  let assert Ok(Nil) = storage.delete(files, key)
}

@external(erlang, "crypto", "strong_rand_bytes")
fn random_bytes(count: Int) -> BitArray

pub fn direct_upload_urls_test() {
  use files, prefix <- each_adapter
  let key = prefix <> "direct/photo.png"
  let assert Ok(upload) =
    storage.upload_url(
      files,
      key,
      content_type: "image/png",
      size: 10,
      expires_in: 300,
    )
  assert upload.method == "PUT"
  assert upload.headers == [#("content-type", "image/png")]
  assert upload.url != ""
  let assert Error(Invalid(_)) =
    storage.upload_url(files, key, content_type: "", size: 10, expires_in: 300)
  let assert Error(Invalid(_)) =
    storage.upload_url(
      files,
      key,
      content_type: "a/b",
      size: -1,
      expires_in: 300,
    )
  let assert Error(Invalid(_)) =
    storage.upload_url(
      files,
      key,
      content_type: "a/b",
      size: storage.max_upload_size + 1,
      expires_in: 300,
    )
  let assert Error(Invalid(_)) =
    storage.upload_url(files, key, content_type: "a/b", size: 1, expires_in: 0)
  let assert Error(Invalid(_)) =
    storage.upload_url(
      files,
      "../x",
      content_type: "a/b",
      size: 1,
      expires_in: 9,
    )
}
