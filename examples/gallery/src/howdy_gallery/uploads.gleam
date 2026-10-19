//// Somewhere for the uploader examples to send files: local storage in
//// `build/gallery-uploads`, the endpoint that hands out upload URLs, and a
//// form handler that checks the keys it is posted.
////
//// A real app would put the signed-in user's id in each key's prefix and
//// check it when the keys come back; the gallery has no users, so every
//// key is under `uploads/`.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import howdy/body
import howdy/controller.{type Context}
import howdy/form
import howdy/service
import howdy/storage
import howdy/storage/local
import howdy/validate

const prefix = "uploads"

pub fn config() -> local.Config {
  local.new("build/gallery-uploads")
  |> local.serve(at: "/files", secret: "gallery-uploads-not-a-real-secret")
}

type UploadInput {
  UploadInput(name: String, content_type: String, size: Int)
}

fn upload_input() -> decode.Decoder(UploadInput) {
  use name <- decode.field("name", decode.string)
  use content_type <- decode.field("type", decode.string)
  use size <- decode.field("size", decode.int)
  decode.success(UploadInput(name:, content_type:, size:))
}

fn check_upload(input: UploadInput) -> validate.Result(UploadInput) {
  use size <- validate.field("size", input.size, [
    validate.min(1),
    validate.max(5_000_000),
  ])
  validate.ok(UploadInput(..input, size:))
}

/// POST /uploads/start
pub fn start(ctx: Context) {
  let files = local.adapter(config())
  use input <- body.validated(ctx, upload_input(), check_upload)
  let key = storage.new_key(prefix:, file_name: input.name)
  let upload =
    storage.upload_url(
      files,
      key,
      content_type: input.content_type,
      size: input.size,
      expires_in: 600,
    )
  case upload {
    Ok(upload) ->
      controller.json(
        ctx,
        json.object([
          #("key", json.string(key)),
          #("upload", storage.direct_upload_to_json(upload)),
        ]),
      )
    Error(error) -> service.error_response(ctx, storage.to_service_error(error))
  }
}

/// The keys posted as `field`, each with whether it is one of ours and in
/// storage, as `key=found` or `key=missing`.
pub fn check(fields: form.Form, field: String) -> String {
  let files = local.adapter(config())
  form.all(fields, field)
  |> list.map(fn(key) {
    let found =
      string.starts_with(key, prefix <> "/")
      && storage.exists(files, key) == Ok(True)
    case found {
      True -> key <> "=found"
      False -> key <> "=missing"
    }
  })
  |> string.join(" ")
}
