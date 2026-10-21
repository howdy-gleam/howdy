import gleam/http
import gleam/http/response
import gleam/list
import gleam/option.{None}
import gleam/string
import howdy
import howdy/content
import howdy/storage
import howdy/storage/local
import howdy/testing
import simplifile

fn with_folder(run: fn(local.Config, String) -> a) -> a {
  let directory = "build/test-local-" <> random_name()
  let config =
    local.new(directory) |> local.serve(at: "/files", secret: "s3cret")
  use <- testing.cleanup(fn() { simplifile.delete(directory) })
  run(config, directory)
}

fn app(config: local.Config) -> howdy.App {
  howdy.new() |> howdy.controller(local.controller(config))
}

fn header(res: response.Response(a), name: String) -> Result(String, Nil) {
  response.get_header(res, name)
}

pub fn signed_urls_are_served_test() {
  use config, _ <- with_folder
  let files = local.adapter(config)
  let assert Ok(Nil) =
    storage.put(
      files,
      "photos/cat 1.png",
      <<"PNG":utf8>>,
      content_type: "image/png",
    )
  let assert Ok(url) = storage.url(files, "photos/cat 1.png", expires_in: 600)
  assert string.starts_with(url, "/files/photos/cat%201.png?expires=")
  let res = testing.get(url) |> testing.send(app(config))
  assert res.status == 200
  assert testing.bytes(res) == <<"PNG":utf8>>
  assert header(res, "content-type") == Ok("image/png")
  assert header(res, "x-content-type-options") == Ok("nosniff")
  let assert Ok(policy) = header(res, "content-security-policy")
  assert string.contains(policy, "sandbox")
  // Images are shown, not downloaded.
  assert header(res, "content-disposition") == Error(Nil)
  let assert Ok(cache) = header(res, "cache-control")
  assert string.starts_with(cache, "private, max-age=")

  let head = testing.request(http.Head, url) |> testing.send(app(config))
  assert head.status == 200
}

pub fn altered_or_unsigned_urls_are_forbidden_test() {
  use config, _ <- with_folder
  let files = local.adapter(config)
  let assert Ok(Nil) =
    storage.put(files, "a.txt", <<1>>, content_type: "text/plain")
  let assert Ok(Nil) =
    storage.put(files, "b.txt", <<2>>, content_type: "text/plain")
  let assert Ok(url) = storage.url(files, "a.txt", expires_in: 600)
  let send = fn(url) { testing.send(testing.get(url), app(config)).status }
  assert send(url) == 200
  assert send(string.replace(url, "a.txt", "b.txt")) == 403
  assert send(string.replace(url, "expires=", "expires=9")) == 403
  assert send("/files/a.txt") == 403
  // A URL signed with another secret.
  let other =
    local.new("unused")
    |> local.serve(at: "/files", secret: "other")
    |> local.adapter
  let assert Ok(forged) = storage.url(other, "a.txt", expires_in: 600)
  assert send(forged) == 403
}

pub fn expired_urls_are_forbidden_test() {
  use config, _ <- with_folder
  let files = local.adapter(config)
  let assert Ok(Nil) =
    storage.put(files, "a.txt", <<1>>, content_type: "text/plain")
  let assert Ok(url) = storage.url(files, "a.txt", expires_in: 1)
  process_sleep(2100)
  assert testing.send(testing.get(url), app(config)).status == 403
}

pub fn risky_types_are_downloaded_test() {
  use config, _ <- with_folder
  let files = local.adapter(config)
  list.each(["text/html", "image/svg+xml", "application/javascript"], fn(type_) {
    let assert Ok(Nil) =
      storage.put(files, "up/page", <<"<script>":utf8>>, content_type: type_)
    let assert Ok(url) = storage.url(files, "up/page", expires_in: 60)
    let res = testing.send(testing.get(url), app(config))
    assert header(res, "content-disposition")
      == Ok("attachment; filename=\"page\"; filename*=UTF-8''page")
  })
}

pub fn download_urls_name_the_file_test() {
  use config, _ <- with_folder
  let files = local.adapter(config)
  let assert Ok(Nil) =
    storage.put(
      files,
      "r.pdf",
      <<"%PDF":utf8>>,
      content_type: "application/pdf",
    )
  let assert Ok(url) =
    storage.download_url(
      files,
      "r.pdf",
      expires_in: 60,
      file_name: "Q3 Report.pdf",
    )
  let res = testing.send(testing.get(url), app(config))
  assert res.status == 200
  assert header(res, "content-disposition")
    == Ok(
      "attachment; filename=\"Q3 Report.pdf\"; filename*=UTF-8''Q3%20Report.pdf",
    )
  // The name is signed too.
  let renamed = string.replace(url, "Q3", "Q4")
  assert testing.send(testing.get(renamed), app(config)).status == 403
}

pub fn public_folders_need_no_signature_test() {
  use config, _ <- with_folder
  let config = local.public(config)
  let files = local.adapter(config)
  let assert Ok(Nil) =
    storage.write("logo.png", storage.Bytes(<<1>>))
    |> storage.content_type("image/png")
    |> storage.cache_control("public, max-age=31536000, immutable")
    |> storage.put_with(files, _)
  assert storage.public_url(files, "logo.png") == Ok("/files/logo.png")
  let res = testing.send(testing.get("/files/logo.png"), app(config))
  assert res.status == 200
  assert header(res, "cache-control")
    == Ok("public, max-age=31536000, immutable")
}

pub fn missing_and_reserved_keys_test() {
  use config, _ <- with_folder
  let files = local.adapter(config)
  let assert Ok(Nil) =
    storage.put(files, "a.txt", <<1>>, content_type: "text/plain")
  let assert Ok(url) = storage.url(files, "a.txt", expires_in: 60)
  let assert Ok(Nil) = storage.delete(files, "a.txt")
  assert testing.send(testing.get(url), app(config)).status == 404
  let assert Error(storage.Invalid(_)) =
    storage.put(files, ".howdy-storage/x", <<1>>, content_type: "text/plain")
}

pub fn keys_that_clash_in_a_folder_are_refused_test() {
  use config, _ <- with_folder
  let files = local.adapter(config)
  let assert Ok(Nil) =
    storage.put(files, "a", <<1>>, content_type: "text/plain")
  let assert Error(storage.Invalid(_)) =
    storage.put(files, "a/b", <<1>>, content_type: "text/plain")
  let assert Ok(Nil) =
    storage.put(files, "c/d", <<1>>, content_type: "text/plain")
  let assert Error(storage.Invalid(_)) =
    storage.put(files, "c", <<1>>, content_type: "text/plain")
}

pub fn files_put_in_the_folder_by_hand_are_found_test() {
  use config, directory <- with_folder
  let assert Ok(Nil) = simplifile.create_directory_all(directory <> "/docs")
  let assert Ok(Nil) = simplifile.write(directory <> "/docs/readme.txt", "# Hi")
  let files = local.adapter(config)
  let assert Ok(object) = storage.head(files, "docs/readme.txt")
  assert string.starts_with(object.content_type, "text/plain")
  assert object.size == 4
  assert storage.get(files, "docs/readme.txt") == Ok(<<"# Hi":utf8>>)
}

pub fn deleting_removes_empty_directories_test() {
  use config, directory <- with_folder
  let files = local.adapter(config)
  let assert Ok(Nil) =
    storage.put(files, "deep/er/file.txt", <<1>>, content_type: "text/plain")
  let assert Ok(Nil) = storage.delete(files, "deep/er/file.txt")
  assert simplifile.is_directory(directory <> "/deep") == Ok(False)
}

pub fn urls_need_serve_test() {
  let files = local.new("unused") |> local.adapter
  let assert Error(storage.Invalid(_)) = storage.url(files, "a", expires_in: 60)
}

@external(erlang, "howdy_storage_ffi", "random_name")
fn random_name() -> String

@external(erlang, "timer", "sleep")
fn process_sleep(milliseconds: Int) -> Nil

// -- Direct uploads ----------------------------------------------------------

fn put_to(
  config: local.Config,
  url: String,
  content_type: String,
  body: BitArray,
) -> response.Response(content.Content) {
  testing.request(http.Put, url)
  |> testing.bytes_body(body)
  |> testing.header("content-type", content_type)
  |> testing.send(app(config))
}

pub fn direct_uploads_are_written_to_the_folder_test() {
  use config, _ <- with_folder
  let files = local.adapter(config)
  let assert Ok(upload) =
    storage.upload_url(
      files,
      "in/cat.png",
      content_type: "image/png",
      size: 4,
      expires_in: 60,
    )
  assert string.starts_with(upload.url, "/files/in/cat.png?expires=")
  let res = put_to(config, upload.url, "image/png", <<"PNG!":utf8>>)
  assert res.status == 200
  let assert Ok(etag) = header(res, "etag")
  assert storage.get(files, "in/cat.png") == Ok(<<"PNG!":utf8>>)
  let assert Ok(object) = storage.head(files, "in/cat.png")
  assert object.content_type == "image/png"
  assert "\"" <> object.etag <> "\"" == etag
}

pub fn direct_uploads_must_match_what_was_signed_test() {
  use config, _ <- with_folder
  let files = local.adapter(config)
  let assert Ok(upload) =
    storage.upload_url(
      files,
      "in/a.png",
      content_type: "image/png",
      size: 4,
      expires_in: 60,
    )
  assert put_to(config, upload.url, "image/png", <<"PNG":utf8>>).status == 400
  assert put_to(config, upload.url, "image/png", <<"PNG!!":utf8>>).status == 400
  assert put_to(config, upload.url, "text/html", <<"PNG!":utf8>>).status == 403
  assert put_to(
      config,
      string.replace(upload.url, "a.png", "b.png"),
      "image/png",
      <<"PNG!":utf8>>,
    ).status
    == 403
  assert put_to(
      config,
      string.replace(upload.url, "size=4", "size=5"),
      "image/png",
      <<"PNG!!":utf8>>,
    ).status
    == 403
  assert storage.exists(files, "in/a.png") == Ok(False)
  // Nothing half-written is left behind.
  let assert Ok(page) = storage.list(files, prefix: "", after: None, limit: 10)
  assert page.objects == []
}

pub fn read_and_upload_urls_are_not_interchangeable_test() {
  use config, _ <- with_folder
  let files = local.adapter(config)
  let assert Ok(Nil) =
    storage.put(files, "a.png", <<1>>, content_type: "image/png")
  let assert Ok(read) = storage.url(files, "a.png", expires_in: 60)
  assert put_to(config, read, "image/png", <<2>>).status == 403
  let assert Ok(upload) =
    storage.upload_url(
      files,
      "a.png",
      content_type: "image/png",
      size: 1,
      expires_in: 60,
    )
  assert testing.send(testing.get(upload.url), app(config)).status == 403
  assert storage.get(files, "a.png") == Ok(<<1>>)
}
