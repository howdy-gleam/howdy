# howdy_storage

File storage for [howdy](https://github.com/mikeyjones/howdy/blob/v1.0.0/README.md) apps: one API for keeping files in
an S3-compatible bucket, a local folder, or memory, with signed URLs that
let browsers fetch them directly.

```toml
howdy_storage = { git = "https://github.com/mikeyjones/howdy.git", ref = "v1.0.0", path = "storage" }
```

## Storing an upload

```gleam
import howdy/form
import howdy/storage
import howdy/storage/s3

fn change_avatar(ctx: Context, files: storage.Storage) {
  let limits =
    form.limits() |> form.accept_files(max_files: 1, max_file_size: 5_000_000)
  use fields <- form.read_with(ctx, limits)
  let assert Ok(upload) = form.get_file(fields, "avatar")
  let key = storage.new_key(prefix: "avatars", file_name: upload.file_name)
  case storage.put_file(files, key, upload.path, content_type: "image/png") {
    Ok(Nil) -> // save `key` with the user
    Error(error) -> service.error_response(ctx, storage.to_service_error(error))
  }
}
```

`put_file` reads the file in parts, so a large upload is never held in
memory. `storage.url(files, key, expires_in: 3600)` gives a signed URL the
browser can fetch the file from; `download_url` makes it download under a
name of your choosing.

For large files the browser can upload straight to storage instead:
`storage.upload_url(files, key, content_type:, size:, expires_in:)` gives a
URL signed for exactly that size and type, which storage holds the upload
to, so your limits apply even though the file never reaches your app.
howdy_ui's `uploader` does the browser's part, with progress.

## Adapters

- `howdy/storage/s3`: AWS S3, Cloudflare R2, Tigris, MinIO, Garage,
  SeaweedFS, Backblaze B2 and other S3-compatible services. `s3.from_env()`
  reads the standard `AWS_*` variables and `S3_BUCKET` or `BUCKET_NAME`.
  Files over 16 MiB go up in parts, and `s3.put_cors` sets the CORS rule
  direct uploads need.
- `howdy/storage/local`: a folder, for development and single servers.
  `local.controller` serves its signed URLs from your app, with headers
  that stop an uploaded HTML or SVG file running script on your site.
- `howdy/storage/memory`: for tests.
- `storage.adapter(...)`: your own.

See the [storage docs](https://github.com/mikeyjones/howdy/blob/v1.0.0/docs/storage/overview.djot) for keys, URLs,
errors and testing.
