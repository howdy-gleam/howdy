import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/json
import gleam/string
import gleam/time/timestamp
import howdy/storage
import howdy/storage/s3
import howdy_storage_behaviour_test.{s3_config, s3_config_for}
import simplifile

fn now() {
  let assert Ok(time) = timestamp.parse_rfc3339("2026-10-18T12:00:00Z")
  time
}

fn aws(bucket: String) -> s3.Config {
  s3.new(
    bucket:,
    region: "eu-west-2",
    access_key_id: "AKID",
    secret_access_key: "secret",
  )
}

fn url_for(config: s3.Config, key: String) -> String {
  let assert Ok(url) = s3.presign(config, key, [], 60, now())
  let assert Ok(#(base, _)) = string.split_once(url, "?")
  base
}

// -- Addressing --------------------------------------------------------------

pub fn aws_buckets_go_in_the_host_test() {
  assert url_for(aws("acme"), "a b/ü.txt")
    == "https://acme.s3.eu-west-2.amazonaws.com/a%20b/%C3%BC.txt"
  assert url_for(aws("acme") |> s3.path_style(True), "k")
    == "https://s3.eu-west-2.amazonaws.com/acme/k"
  // A dotted name is not a valid certificate host, so it goes in the path.
  assert url_for(aws("my.bucket"), "k")
    == "https://s3.eu-west-2.amazonaws.com/my.bucket/k"
}

pub fn other_services_take_the_bucket_in_the_path_test() {
  let local = aws("acme") |> s3.endpoint("http://localhost:9000")
  assert url_for(local, "k") == "http://localhost:9000/acme/k"
  assert url_for(local |> s3.path_style(False), "k")
    == "http://acme.localhost:9000/k"
  let r2 =
    aws("acme") |> s3.endpoint("https://account.r2.cloudflarestorage.com/")
  assert url_for(r2, "k") == "https://account.r2.cloudflarestorage.com/acme/k"
}

pub fn invalid_endpoints_are_refused_test() {
  let files = aws("acme") |> s3.endpoint("ftp://nope") |> s3.adapter
  let assert Error(storage.Refused(_)) = storage.get(files, "k")
  let files = aws("acme") |> s3.endpoint("http://host/with/path") |> s3.adapter
  let assert Error(storage.Refused(_)) = storage.url(files, "k", expires_in: 60)
}

pub fn presigned_urls_carry_the_credential_scope_test() {
  let assert Ok(url) = s3.presign(aws("acme"), "k", [], 900, now())
  assert string.contains(
    url,
    "X-Amz-Credential=AKID%2F20261018%2Feu-west-2%2Fs3%2Faws4_request",
  )
  assert string.contains(url, "X-Amz-Expires=900")
}

pub fn public_urls_test() {
  let files =
    aws("acme") |> s3.public_url("https://cdn.example.com/") |> s3.adapter
  assert storage.public_url(files, "a b/c.png")
    == Ok("https://cdn.example.com/a%20b/c.png")
  let assert Error(storage.Invalid(_)) =
    storage.public_url(s3.adapter(aws("acme")), "c.png")
}

// -- Against a service -------------------------------------------------------

pub fn signed_urls_open_in_a_browser_test() {
  case s3_config() {
    Error(Nil) -> Nil
    Ok(config) -> {
      let files = s3.adapter(config)
      let key = "urls/" <> random_name() <> "/report.html"
      let assert Ok(Nil) =
        storage.write(key, storage.Bytes(<<"<p>hi</p>":utf8>>))
        |> storage.content_type("text/html; charset=utf-8")
        |> storage.cache_control("private, max-age=60")
        |> storage.put_with(files, _)

      let assert Ok(url) = storage.url(files, key, expires_in: 60)
      let response = fetch(url)
      assert response.status == 200
      assert response.body == <<"<p>hi</p>":utf8>>
      assert response.get_header(response, "content-type")
        == Ok("text/html; charset=utf-8")
      assert response.get_header(response, "cache-control")
        == Ok("private, max-age=60")

      let assert Ok(url) =
        storage.download_url(
          files,
          key,
          expires_in: 60,
          file_name: "Ré port.html",
        )
      let response = fetch(url)
      assert response.status == 200
      assert response.get_header(response, "content-disposition")
        == Ok(
          "attachment; filename=\"R_ port.html\"; filename*=UTF-8''R%C3%A9%20port.html",
        )

      // Changing the key breaks the signature.
      let tampered = string.replace(url, "report.html", "other.html")
      assert fetch(tampered).status == 403
      let assert Ok(Nil) = storage.delete(files, key)
      Nil
    }
  }
}

pub fn large_files_are_uploaded_in_parts_test() {
  case s3_config() {
    Error(Nil) -> Nil
    Ok(config) -> {
      let files =
        config
        |> s3.multipart(threshold: 5_242_880, part_size: 5_242_880)
        |> s3.adapter
      let path = "build/test-large-" <> random_name()
      // Three parts: two full and one short.
      let content = random_bytes(11 * 1_048_576 + 17)
      let assert Ok(Nil) = simplifile.write_bits(path, content)
      let key = "large/" <> random_name() <> ".bin"
      let assert Ok(Nil) =
        storage.put_file(files, key, path, content_type: "application/zip")
      assert storage.get(files, key) == Ok(content)
      let assert Ok(object) = storage.head(files, key)
      assert object.size == 11 * 1_048_576 + 17
      assert object.content_type == "application/zip"
      let assert Ok(Nil) = storage.delete(files, key)
      let assert Ok(Nil) = simplifile.delete(path)
      Nil
    }
  }
}

pub fn a_missing_bucket_is_refused_test() {
  case s3_config_for("howdy-missing-" <> random_name()) {
    Error(Nil) -> Nil
    Ok(config) -> {
      let files = s3.adapter(config)
      // Not `NotFound`: the object is not missing, the bucket is.
      let assert Error(storage.Refused(reason)) = storage.get(files, "k")
      assert string.contains(reason, "NoSuchBucket")
      Nil
    }
  }
}

fn fetch(url: String) -> response.Response(BitArray) {
  let assert Ok(req) = request.to(url)
  let assert Ok(response) =
    httpc.dispatch_bits(httpc.configure(), request.set_body(req, <<>>))
  response
}

@external(erlang, "howdy_storage_ffi", "random_name")
fn random_name() -> String

@external(erlang, "crypto", "strong_rand_bytes")
fn random_bytes(count: Int) -> BitArray

// -- Direct uploads ----------------------------------------------------------

fn upload_with(
  upload: storage.DirectUpload,
  content_type: String,
  body: BitArray,
) -> response.Response(BitArray) {
  let assert Ok(req) = request.to(upload.url)
  let req =
    req
    |> request.set_method(http.Put)
    |> request.set_header("content-type", content_type)
    |> request.set_body(body)
  let assert Ok(response) = httpc.dispatch_bits(httpc.configure(), req)
  response
}

pub fn browsers_upload_straight_to_the_bucket_test() {
  case s3_config() {
    Error(Nil) -> Nil
    Ok(config) -> {
      let files = s3.adapter(config)
      let key = "direct/" <> random_name() <> ".png"
      let content = random_bytes(1000)
      let assert Ok(upload) =
        storage.upload_url(
          files,
          key,
          content_type: "image/png",
          size: 1000,
          expires_in: 60,
        )
      // Another size or type does not match the signature.
      assert upload_with(upload, "image/png", random_bytes(999)).status >= 400
      assert upload_with(upload, "image/png", random_bytes(1001)).status >= 400
      assert upload_with(upload, "text/html", content).status >= 400
      assert storage.exists(files, key) == Ok(False)

      assert upload_with(upload, "image/png", content).status == 200
      assert storage.get(files, key) == Ok(content)
      let assert Ok(object) = storage.head(files, key)
      assert object.content_type == "image/png"
      let assert Ok(Nil) = storage.delete(files, key)
      Nil
    }
  }
}

pub fn direct_upload_json_test() {
  let upload =
    storage.DirectUpload(url: "https://b/k?x=1", method: "PUT", headers: [
      #("content-type", "image/png"),
    ])
  assert json.to_string(storage.direct_upload_to_json(upload))
    == "{\"url\":\"https://b/k?x=1\",\"method\":\"PUT\",\"headers\":{\"content-type\":\"image/png\"}}"
}
