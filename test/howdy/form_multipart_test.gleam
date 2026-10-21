import ewe
import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import howdy
import howdy/context
import howdy/controller
import howdy/form.{type Form, type UploadedFile, UploadedFile}
import howdy/problem
import howdy/service.{FieldError}
import howdy/testing.{type FormFile, FormFile}
import howdy/validate
import simplifile

fn app(handler: controller.Handler) -> howdy.App {
  howdy.new()
  |> howdy.controller(
    controller.new("/upload") |> controller.post("/", handler),
  )
}

fn accepting(max_files: Int, max_file_size: Int) -> form.Limits {
  form.limits() |> form.accept_files(max_files:, max_file_size:)
}

fn photo() -> FormFile {
  FormFile("photo", "cat.png", "image/png", <<"PNG\r\n--not-a-boundary":utf8>>)
}

/// A raw multipart body with boundary `b`.
fn raw(body: String) {
  testing.request(http.Post, "/upload")
  |> testing.bytes_body(<<body:utf8>>)
  |> testing.header("content-type", "multipart/form-data; boundary=b")
}

fn error_for(req, limits: form.Limits) -> #(Int, Result(String, Nil)) {
  let res =
    testing.send(
      req,
      app(fn(ctx) {
        use _fields <- form.read_with(ctx, limits)
        controller.text(ctx, "ok")
      }),
    )
  #(res.status, testing.error(res))
}

// -- Reading -----------------------------------------------------------------

pub fn text_fields_are_read_in_order_test() {
  let pairs = [
    #("name", "Zoë ✓"),
    #("tags", "x"),
    #("tags", "y"),
    #("empty", ""),
    #("lines", "a\r\nb\r\n--b"),
  ]
  let res =
    testing.post_multipart("/upload", pairs, [])
    |> testing.send(
      app(fn(ctx) {
        // `read` takes a multipart form that has no files.
        use fields <- form.read(ctx)
        assert form.fields(fields) == pairs
        assert form.uploaded_files(fields) == []
        controller.text(ctx, "ok")
      }),
    )
  assert res.status == 200
}

pub fn files_are_written_to_temporary_files_test() {
  let report = process.new_subject()
  let notes = FormFile("notes", "a \"quoted\" name.txt", "text/plain", <<>>)
  let res =
    testing.post_multipart("/upload", [#("title", "Cat")], [photo(), notes])
    |> testing.send(
      app(fn(ctx) {
        use fields <- form.read_with(ctx, accepting(2, 100))
        assert form.fields(fields) == [#("title", "Cat")]
        let assert [#("photo", photo), #("notes", notes)] =
          form.uploaded_files(fields)
        assert photo.file_name == "cat.png"
        assert photo.content_type == "image/png"
        assert photo.size == 21
        assert simplifile.read_bits(photo.path)
          == Ok(<<"PNG\r\n--not-a-boundary":utf8>>)
        // A named empty file is still a file.
        assert notes.file_name == "a %22quoted%22 name.txt"
        assert notes.size == 0
        assert simplifile.read_bits(notes.path) == Ok(<<>>)
        assert form.get_file(fields, "photo") == Ok(photo)
        assert form.all_files(fields, "notes") == [notes]
        process.send(report, [photo.path, notes.path])
        controller.text(ctx, "ok")
      }),
    )
  assert res.status == 200
  let assert Ok(paths) = process.receive(report, 0)
  list.each(paths, fn(path) {
    assert simplifile.is_file(path) == Ok(False)
  })
}

pub fn any_chunk_size_reads_the_same_form_test() {
  let fields = [#("a", "1"), #("b", "two\r\n")]
  let files = [photo(), FormFile("photo", "dog.png", "image/png", <<1, 2, 3>>)]
  list.each([1, 2, 3, 7, 13, 64, 65_536], fn(size) {
    let res =
      testing.post_multipart("/upload", fields, files)
      |> testing.send(
        app(fn(ctx) {
          let limits = accepting(2, 100) |> form.chunk_size(size)
          use read <- form.read_with(ctx, limits)
          assert form.fields(read) == fields
          let contents =
            form.all_files(read, "photo")
            |> list.map(fn(file) { simplifile.read_bits(file.path) })
          assert contents == list.map(files, fn(file) { Ok(file.content) })
          controller.text(ctx, "ok")
        }),
      )
    assert res.status == 200
  })
}

pub fn preamble_epilogue_and_quoted_boundary_test() {
  let res =
    testing.request(http.Post, "/upload")
    |> testing.bytes_body(<<
      "ignored preamble\r\n--b\r\ncontent-disposition: form-data; name=\"a\"\r\n\r\n1\r\n--b--\r\nignored epilogue":utf8,
    >>)
    |> testing.header("content-type", "Multipart/Form-Data; boundary=\"b\"")
    |> testing.send(
      app(fn(ctx) {
        use fields <- form.read(ctx)
        controller.text(ctx, form.value(fields, "a"))
      }),
    )
  assert res.status == 200
  assert testing.text(res) == "1"
}

pub fn a_form_with_no_parts_is_empty_test() {
  let res =
    raw("--b--\r\n")
    |> testing.send(
      app(fn(ctx) {
        use fields <- form.read(ctx)
        assert form.fields(fields) == []
        controller.text(ctx, "ok")
      }),
    )
  assert res.status == 200
}

pub fn an_empty_file_input_is_not_a_file_test() {
  let res =
    testing.post_multipart("/upload", [], [
      FormFile("photo", "", "application/octet-stream", <<>>),
    ])
    |> testing.send(
      app(fn(ctx) {
        // Even a form that takes no files accepts an input left empty.
        use fields <- form.read(ctx)
        assert form.uploaded_files(fields) == []
        controller.text(ctx, "ok")
      }),
    )
  assert res.status == 200
}

pub fn file_names_lose_their_directories_test() {
  let res =
    testing.post_multipart("/upload", [], [
      FormFile("a", "C:\\Users\\ada\\cat.png", "image/png", <<1>>),
      FormFile("b", "../../etc/passwd", "text/plain", <<1>>),
      FormFile("c", "semi;colon = \\odd.txt", "text/plain", <<1>>),
    ])
    |> testing.send(
      app(fn(ctx) {
        use fields <- form.read_with(ctx, accepting(3, 10))
        let names =
          form.uploaded_files(fields)
          |> list.map(fn(file) { { file.1 }.file_name })
        controller.text(ctx, string.join(names, ","))
      }),
    )
  assert testing.text(res) == "cat.png,passwd,odd.txt"
}

pub fn files_go_to_the_temporary_directory_given_test() {
  let directory =
    "build/test-uploads-" <> int.to_string(int.random(1_000_000)) <> "/nested"
  let res =
    testing.post_multipart("/upload", [], [photo()])
    |> testing.send(
      app(fn(ctx) {
        let limits = accepting(1, 100) |> form.temporary_directory(directory)
        use fields <- form.read_with(ctx, limits)
        let assert Ok(file) = form.get_file(fields, "photo")
        assert string.starts_with(file.path, directory <> "/howdy-upload-")
        controller.text(ctx, "ok")
      }),
    )
  assert res.status == 200
  assert simplifile.read_directory(directory) == Ok([])
  let assert Ok(Nil) = simplifile.delete(directory)
}

pub fn files_are_deleted_when_the_handler_crashes_test() {
  let report = process.new_subject()
  let crashed =
    rescue(fn() {
      testing.post_multipart("/upload", [], [photo()])
      |> testing.send(
        app(fn(ctx) {
          use fields <- form.read_with(ctx, accepting(1, 100))
          let assert Ok(file) = form.get_file(fields, "photo")
          process.send(report, file.path)
          panic as "handler crashed"
        }),
      )
    })
  assert crashed == Error(Nil)
  let assert Ok(path) = process.receive(report, 0)
  assert simplifile.is_file(path) == Ok(False)
}

fn rescue(run: fn() -> a) -> Result(a, Nil) {
  case howdy_rescue(run) {
    Ok(value) -> Ok(value)
    Error(_) -> Error(Nil)
  }
}

@external(erlang, "howdy_ffi", "rescue")
fn howdy_rescue(run: fn() -> a) -> Result(a, String)

pub fn files_are_deleted_when_the_request_process_dies_test() {
  let report = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      testing.post_multipart("/upload", [], [photo()])
      |> testing.send(
        app(fn(ctx) {
          use fields <- form.read_with(ctx, accepting(1, 100))
          let assert Ok(file) = form.get_file(fields, "photo")
          process.send(report, file.path)
          process.sleep_forever()
          controller.text(ctx, "never")
        }),
      )
    })
  let assert Ok(path) = process.receive(report, 1000)
  assert simplifile.is_file(path) == Ok(True)
  process.kill(pid)
  assert eventually(fn() { simplifile.is_file(path) == Ok(False) }, 50)
}

fn eventually(check: fn() -> Bool, tries: Int) -> Bool {
  case check(), tries {
    True, _ -> True
    False, 0 -> False
    False, _ -> {
      process.sleep(10)
      eventually(check, tries - 1)
    }
  }
}

// -- Limits and malformed forms ----------------------------------------------

pub fn files_are_refused_unless_accepted_test() {
  let req = testing.post_multipart("/upload", [], [photo()])
  assert error_for(req, form.limits())
    == #(400, Ok("this form does not accept files"))
}

pub fn file_limits_test() {
  let two = testing.post_multipart("/upload", [], [photo(), photo()])
  assert error_for(two, accepting(1, 100)) == #(400, Ok("too many files"))
  assert error_for(two, accepting(2, 20))
    == #(400, Ok("the file in photo is too large"))
  assert error_for(two, accepting(2, 100) |> form.max_total_file_size(40))
    == #(400, Ok("the files are too large"))
  assert error_for(two, accepting(2, 21)).0 == 200
}

pub fn fields_limit_counts_everything_but_files_test() {
  let req = testing.post_multipart("/upload", [#("a", "1")], [photo()])
  assert error_for(req, accepting(1, 100) |> form.max_fields_size(40))
    == #(400, Ok("request body too large"))
  assert error_for(req, accepting(1, 100) |> form.max_fields_size(400)).0 == 200
  // Headers that never end are refused once they exceed the limit.
  let endless =
    raw("--b\r\ncontent-disposition: form-data; " <> string.repeat("x", 100))
  assert error_for(endless, form.limits() |> form.max_fields_size(50))
    == #(400, Ok("request body too large"))
}

pub fn malformed_forms_are_rejected_test() {
  let limits = accepting(1, 100)
  let no_boundary =
    testing.request(http.Post, "/upload")
    |> testing.bytes_body(<<"--b--":utf8>>)
    |> testing.header("content-type", "multipart/form-data")
  assert error_for(no_boundary, limits)
    == #(400, Ok("multipart form has no valid boundary"))
  let cut_short =
    raw("--b\r\ncontent-disposition: form-data; name=\"a\"\r\n\r\n1")
  assert error_for(cut_short, limits)
    == #(400, Ok("multipart form ended early"))
  assert error_for(raw("--b\r\nnonsense\r\n\r\n1\r\n--b--"), limits)
    == #(400, Ok("multipart form has a malformed part header"))
  assert error_for(raw("--b\r\n\r\n1\r\n--b--"), limits)
    == #(400, Ok("multipart form has a part that is not form-data"))
  assert error_for(
      raw("--b\r\ncontent-disposition: form-data\r\n\r\n1\r\n--b--"),
      limits,
    )
    == #(400, Ok("multipart form has a part with no name"))
  assert error_for(raw("--bX"), limits)
    == #(400, Ok("multipart form has a malformed boundary"))
  let not_utf8 =
    testing.request(http.Post, "/upload")
    |> testing.bytes_body(<<
      "--b\r\ncontent-disposition: form-data; name=\"a\"\r\n\r\n":utf8,
      0xff,
      "\r\n--b--":utf8,
    >>)
    |> testing.header("content-type", "multipart/form-data; boundary=b")
  assert error_for(not_utf8, limits)
    == #(400, Ok("the field a is not valid UTF-8"))
}

pub fn files_written_before_a_failure_are_deleted_test() {
  let directory = "build/test-uploads-" <> int.to_string(int.random(1_000_000))
  let req = testing.post_multipart("/upload", [], [photo(), photo()])
  let limits = accepting(1, 100) |> form.temporary_directory(directory)
  assert error_for(req, limits) == #(400, Ok("too many files"))
  assert simplifile.read_directory(directory) == Ok([])
  let assert Ok(Nil) = simplifile.delete(directory)
}

// -- Typed files -------------------------------------------------------------

type Upload {
  Upload(avatar: UploadedFile, cover: option.Option(UploadedFile), extras: Int)
}

fn upload(fields: Form) -> validate.Result(Upload) {
  use avatar <- form.file(fields, "avatar", [
    form.file_type(["image/png", "image/JPEG"]),
    form.max_size(1_048_576),
  ])
  use cover <- form.optional_file(fields, "cover", [form.file_type(["image/*"])])
  use extras <- form.files(fields, "extras", [form.max_size(2000)])
  validate.ok(Upload(avatar:, cover:, extras: list.length(extras)))
}

fn file(content_type: String, size: Int) -> UploadedFile {
  UploadedFile(file_name: "f", content_type:, size:, path: "/nowhere")
}

pub fn typed_files_test() {
  let avatar = file("image/jpeg; charset=binary", 10)
  let fields =
    form.from_fields([])
    |> form.with_files([
      #("avatar", avatar),
      #("extras", file("text/plain", 1)),
      #("extras", file("text/plain", 2)),
    ])
  assert upload(fields) == Ok(Upload(avatar:, cover: None, extras: 2))

  let cover = file("image/gif", 1)
  let fields = form.with_files(fields, [#("cover", cover)])
  assert upload(fields) == Ok(Upload(avatar:, cover: Some(cover), extras: 2))
}

pub fn file_errors_test() {
  assert upload(form.from_fields([]))
    == Error([FieldError("avatar", problem.Required)])
  let fields =
    form.from_fields([])
    |> form.with_files([
      #("avatar", file("image/gif", 2_000_000)),
      #("cover", file("application/pdf", 1)),
      #("extras", file("text/plain", 3000)),
    ])
  assert upload(fields)
    == Error([
      FieldError("avatar", problem.FileType(["image/png", "image/jpeg"])),
      FieldError("cover", problem.FileType(["image/*"])),
      FieldError("extras", problem.FileTooLarge(2000)),
    ])
  let too_big =
    form.from_fields([])
    |> form.with_files([#("avatar", file("image/png", 2_000_000))])
  assert upload(too_big)
    == Error([FieldError("avatar", problem.FileTooLarge(1_048_576))])
  let twice =
    form.from_fields([])
    |> form.with_files([#("avatar", avatar()), #("avatar", avatar())])
  assert upload(twice) == Error([FieldError("avatar", problem.Repeated)])
}

fn avatar() -> UploadedFile {
  file("image/png", 1)
}

pub fn validated_with_accepts_files_test() {
  let res =
    testing.post_multipart("/upload", [], [
      FormFile("avatar", "me.png", "image/png", <<1, 2>>),
    ])
    |> testing.send(
      app(fn(ctx) {
        use upload <- form.validated_with(ctx, accepting(1, 100), upload)
        controller.text(ctx, upload.avatar.file_name)
      }),
    )
  assert testing.text(res) == "me.png"
}

// -- Over a socket -----------------------------------------------------------

@external(erlang, "howdy_test_ffi", "with_http_server")
fn with_http_server(start: fn() -> #(process.Pid, Int), run: fn(Int) -> a) -> a

@external(erlang, "howdy_test_ffi", "plain_post")
fn plain_post(
  port: Int,
  path: String,
  content_type: String,
  body: BitArray,
) -> #(Int, String)

@external(erlang, "howdy_test_ffi", "plain_post")
fn chunked_post(
  port: Int,
  path: String,
  content_type: String,
  chunks: List(BitArray),
) -> #(Int, String)

@external(erlang, "crypto", "strong_rand_bytes")
fn random_bytes(count: Int) -> BitArray

pub fn live_uploads_are_read_from_the_socket_test() {
  let content = random_bytes(1_000_000)
  let req =
    testing.post_multipart("/upload", [#("title", "big")], [
      FormFile("photo", "big.bin", "application/octet-stream", content),
    ])
  let assert Ok(content_type) = request.get_header(req, "content-type")
  let body = testing_body(req)
  let app =
    app(fn(ctx) {
      use fields <- form.read_with(ctx, accepting(1, 2_000_000))
      let assert Ok(file) = form.get_file(fields, "photo")
      let same = simplifile.read_bits(file.path) == Ok(content)
      controller.text(
        ctx,
        form.value(fields, "title")
          <> " "
          <> int.to_string(file.size)
          <> " "
          <> string.inspect(same),
      )
    })
  use port <- with_http_server(fn() {
    let assert Ok(started) =
      ewe.new(handler: howdy.handler(app))
      |> ewe.bind("127.0.0.1")
      |> ewe.listening(0)
      |> ewe.quiet
      |> ewe.start
    let assert ewe.TcpSocketAddress(_, port) = started.data
    #(started.pid, port)
  })
  assert plain_post(port, "/upload", content_type, body)
    == #(200, "big 1000000 True")
  assert chunked_post(port, "/upload", content_type, split(body, 4099, []))
    == #(200, "big 1000000 True")
  let too_big =
    testing_body(
      testing.post_multipart("/upload", [], [
        FormFile(
          "photo",
          "big.bin",
          "application/octet-stream",
          random_bytes(2_100_000),
        ),
      ]),
    )
  let #(status, _) = plain_post(port, "/upload", content_type, too_big)
  assert status == 400
}

/// The bytes of a request built with `howdy/testing`.
fn testing_body(req: request.Request(context.Body)) -> BitArray {
  let assert Ok(body) = context.read_body(req, limit: 10_000_000)
  body
}

fn split(bits: BitArray, size: Int, chunks: List(BitArray)) -> List(BitArray) {
  case bit_array.byte_size(bits) <= size {
    True -> list.reverse([bits, ..chunks])
    False -> {
      let assert Ok(chunk) = bit_array.slice(bits, 0, size)
      let assert Ok(rest) =
        bit_array.slice(bits, size, bit_array.byte_size(bits) - size)
      split(rest, size, [chunk, ..chunks])
    }
  }
}

// -- Reading a body in pieces ------------------------------------------------

pub fn bodies_can_be_read_in_pieces_test() {
  let read_all = fn(limit) {
    let res =
      testing.request(http.Put, "/upload")
      |> testing.bytes_body(<<"abcdefghij":utf8>>)
      |> testing.send(
        howdy.new()
        |> howdy.controller(
          controller.new("/upload")
          |> controller.put("/", fn(ctx) {
            let reader = controller.body_reader(ctx, limit:)
            controller.text(ctx, string.inspect(pieces(reader, [])))
          }),
        ),
      )
    testing.text(res)
  }
  assert read_all(100) == "Ok([\"abcd\", \"efgh\", \"ij\"])"
  assert read_all(5) == "Error(BodyTooLarge)"
}

fn pieces(
  reader: context.Reader,
  found: List(String),
) -> Result(List(String), context.BodyError) {
  case context.read_chunk(reader, max_bytes: 4) {
    Ok(Some(#(chunk, reader))) -> {
      let assert Ok(text) = bit_array.to_string(chunk)
      pieces(reader, [text, ..found])
    }
    Ok(None) -> Ok(list.reverse(found))
    Error(error) -> Error(error)
  }
}
