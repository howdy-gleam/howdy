import gleam/bytes_tree
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/string
import howdy
import howdy/conditional
import howdy/content
import howdy/controller.{type Context}
import howdy/testing

// One resource, served with `validators` by `handler`, for every method.
fn app(
  validators: conditional.Validators,
  handler: fn(Context) -> response.Response(content.Content),
) -> howdy.App {
  let answer = fn(ctx) {
    use <- conditional.when(ctx, validators)
    handler(ctx)
  }
  howdy.new()
  |> howdy.controller(
    controller.new("/")
    |> controller.get("/note", answer)
    |> controller.put("/note", answer),
  )
}

fn note(ctx: Context) {
  controller.text(ctx, "the note")
}

fn never(_ctx: Context) -> response.Response(content.Content) {
  panic as "the handler must not run when the client is up to date"
}

fn get(app: howdy.App, headers: List(#(String, String))) {
  send(app, http.Get, headers)
}

fn send(app: howdy.App, method: http.Method, headers: List(#(String, String))) {
  list.fold(headers, testing.request(method, "/note"), fn(req, header) {
    request.set_header(req, header.0, header.1)
  })
  |> testing.send(app)
}

fn header(res: response.Response(a), name: String) -> String {
  let assert Ok(value) = response.get_header(res, name)
  value
}

pub fn a_fresh_response_carries_its_validators_test() {
  let res =
    app(conditional.etag(["note", "1", "v3"]), note)
    |> get([])
  assert res.status == 200
  assert testing.text(res) == "the note"
  let etag = header(res, "etag")
  assert string.starts_with(etag, "W/\"")
  assert string.ends_with(etag, "\"")
  assert header(res, "cache-control") == "private, no-cache"
  assert response.get_header(res, "last-modified") == Error(Nil)
}

pub fn a_matching_if_none_match_skips_the_handler_test() {
  let etag = header(get(app(conditional.etag(["n"]), note), []), "etag")
  let res =
    app(conditional.etag(["n"]), never) |> get([#("if-none-match", etag)])
  assert res.status == 304
  assert res.body == content.Empty
  assert header(res, "etag") == etag
  assert header(res, "cache-control") == "private, no-cache"

  // Weak comparison: the strong form of the tag, `*`, and lists all match.
  let strong = string.drop_start(etag, 2)
  let app = app(conditional.etag(["n"]), never)
  assert { get(app, [#("if-none-match", strong)]) }.status == 304
  assert { get(app, [#("if-none-match", "*")]) }.status == 304
  assert { get(app, [#("if-none-match", "\"old\", " <> etag)]) }.status == 304
}

pub fn a_changed_version_runs_the_handler_test() {
  let old = header(get(app(conditional.etag(["n", "1"]), note), []), "etag")
  let res =
    app(conditional.etag(["n", "2"]), note) |> get([#("if-none-match", old)])
  assert res.status == 200
  assert header(res, "etag") != old
}

pub fn parts_are_kept_apart_test() {
  let tag = fn(parts) {
    header(get(app(conditional.etag(parts), note), []), "etag")
  }
  assert tag(["ab", "c"]) != tag(["a", "bc"])
  assert tag(["ab", "c"]) == tag(["ab", "c"])
  assert tag([]) != tag([""])
}

pub fn modification_times_answer_if_modified_since_test() {
  let validators = conditional.modified_at(1_700_000_000)
  let res = app(validators, note) |> get([])
  let modified = header(res, "last-modified")
  assert modified == "Tue, 14 Nov 2023 22:13:20 GMT"
  assert response.get_header(res, "etag") == Error(Nil)

  let app = app(validators, note)
  assert { get(app, [#("if-modified-since", modified)]) }.status == 304
  assert { get(app, [#("if-modified-since", "Tue, 14 Nov 2023 22:13:19 GMT")]) }.status
    == 200
  assert { get(app, [#("if-modified-since", "yesterday")]) }.status == 200
}

pub fn if_none_match_wins_over_if_modified_since_test() {
  let validators =
    conditional.etag(["n"]) |> conditional.last_modified(1_700_000_000)
  let res =
    app(validators, note)
    |> get([
      #("if-none-match", "\"something-else\""),
      #("if-modified-since", "Tue, 14 Nov 2023 22:13:20 GMT"),
    ])
  assert res.status == 200
}

pub fn writes_check_if_match_against_strong_tags_test() {
  let current = conditional.strong_etag(["note", "v2"])
  let tag = header(get(app(current, note), []), "etag")
  assert !string.starts_with(tag, "W/")
  let old =
    header(get(app(conditional.strong_etag(["note", "v1"]), note), []), "etag")

  // Edited an old copy: refused before the handler runs.
  let res = app(current, never) |> send(http.Put, [#("if-match", old)])
  assert res.status == 412
  assert testing.error(res) == Ok("precondition failed")

  // Edited the current copy: the write goes ahead, and its response is not
  // given the validators of the version it replaced.
  let res = app(current, note) |> send(http.Put, [#("if-match", tag)])
  assert res.status == 200
  assert response.get_header(res, "etag") == Error(Nil)
  assert response.get_header(res, "cache-control") == Error(Nil)

  assert { app(current, note) |> send(http.Put, [#("if-match", "*")]) }.status
    == 200

  // `if-match` never matches a weak tag.
  let weak = conditional.etag(["note", "v2"])
  let weak_tag = header(get(app(weak, note), []), "etag")
  assert { app(weak, never) |> send(http.Put, [#("if-match", weak_tag)]) }.status
    == 412
}

pub fn writes_check_if_unmodified_since_test() {
  let validators = conditional.modified_at(1_700_000_000)
  let res =
    app(validators, never)
    |> send(http.Put, [
      #("if-unmodified-since", "Tue, 14 Nov 2023 22:13:19 GMT"),
    ])
  assert res.status == 412
  let res =
    app(validators, note)
    |> send(http.Put, [
      #("if-unmodified-since", "Tue, 14 Nov 2023 22:13:20 GMT"),
    ])
  assert res.status == 200
}

pub fn a_write_with_a_matching_if_none_match_is_refused_test() {
  // `if-none-match: *` on a PUT means "only if it does not exist yet".
  let res =
    app(conditional.etag(["n"]), never)
    |> send(http.Put, [#("if-none-match", "*")])
  assert res.status == 412
}

pub fn errors_are_not_stamped_test() {
  let res =
    app(conditional.etag(["n"]), fn(ctx) { controller.status(ctx, 404) })
    |> get([])
  assert res.status == 404
  assert response.get_header(res, "etag") == Error(Nil)
  assert response.get_header(res, "cache-control") == Error(Nil)
}

pub fn headers_the_handler_set_are_kept_test() {
  let res =
    app(conditional.etag(["n"]), fn(ctx) {
      note(ctx) |> response.set_header("cache-control", "no-store")
    })
    |> get([])
  assert header(res, "cache-control") == "no-store"
}

pub fn cache_control_can_be_chosen_or_left_alone_test() {
  let policy =
    conditional.public()
    |> conditional.max_age(60)
    |> conditional.shared_max_age(600)
  let validators = conditional.etag(["n"]) |> conditional.cache_control(policy)
  let res = app(validators, note) |> get([])
  assert header(res, "cache-control") == "public, max-age=60, s-maxage=600"
  let res =
    app(validators, never) |> get([#("if-none-match", header(res, "etag"))])
  assert header(res, "cache-control") == "public, max-age=60, s-maxage=600"

  let res =
    app(conditional.etag(["n"]) |> conditional.without_cache_control, note)
    |> get([])
  assert response.get_header(res, "cache-control") == Error(Nil)
}

pub fn cache_control_header_values_test() {
  assert conditional.to_string(conditional.private()) == "private, no-cache"
  assert conditional.to_string(conditional.public()) == "public, no-cache"
  assert conditional.to_string(conditional.no_store() |> conditional.max_age(5))
    == "no-store"
  assert conditional.public()
    |> conditional.max_age(31_536_000)
    |> conditional.immutable
    |> conditional.to_string
    == "public, max-age=31536000, immutable"
  assert conditional.private()
    |> conditional.max_age(0)
    |> conditional.stale_while_revalidate(30)
    |> conditional.must_revalidate
    |> conditional.to_string
    == "private, max-age=0, stale-while-revalidate=30, must-revalidate"
  assert conditional.to_string(conditional.public() |> conditional.max_age(-5))
    == "public, max-age=0"
  // Without `max_age`, browsers ask every time but a CDN keeps its copy.
  assert conditional.to_string(
      conditional.public() |> conditional.shared_max_age(600),
    )
    == "public, max-age=0, s-maxage=600"
}

pub fn vary_merges_header_names_test() {
  let res =
    response.new(200)
    |> response.set_body(content.Empty)
    |> conditional.vary(["Accept"])
    |> conditional.vary(["accept", "Accept-Language", ""])
  assert header(res, "vary") == "accept, accept-language"
}

pub fn is_fresh_reports_without_answering_test() {
  let validators = conditional.etag(["n"])
  let tag = header(get(app(validators, note), []), "etag")
  let probe =
    howdy.new()
    |> howdy.controller(
      controller.new("/")
      |> controller.get("/note", fn(ctx) {
        case conditional.is_fresh(ctx, validators) {
          True -> controller.text(ctx, "fresh")
          False -> controller.text(ctx, "stale")
        }
      }),
    )
  assert testing.text(get(probe, [#("if-none-match", tag)])) == "fresh"
  assert testing.text(get(probe, [])) == "stale"
}

fn with_auto_etag(
  handler: fn(Context) -> response.Response(content.Content),
) -> howdy.App {
  howdy.new()
  |> howdy.middleware(conditional.auto_etag)
  |> howdy.controller(
    controller.new("/")
    |> controller.get("/note", handler)
    |> controller.put("/note", handler),
  )
}

pub fn auto_etag_hashes_bodies_test() {
  let app = with_auto_etag(note)
  let res = get(app, [])
  let tag = header(res, "etag")
  assert string.starts_with(tag, "W/\"")
  assert header(get(app, []), "etag") == tag
  assert header(
      get(with_auto_etag(fn(ctx) { controller.text(ctx, "other") }), []),
      "etag",
    )
    != tag

  let res = get(app, [#("if-none-match", tag)])
  assert res.status == 304
  assert res.body == content.Empty
  assert header(res, "etag") == tag
  assert response.get_header(res, "content-type") == Error(Nil)

  // Bytes bodies are hashed too.
  let bytes =
    with_auto_etag(fn(_ctx) {
      response.new(200)
      |> response.set_body(content.Bytes(bytes_tree.from_string("the note")))
    })
  assert header(get(bytes, []), "etag") == tag
}

pub fn auto_etag_leaves_some_responses_alone_test() {
  let untouched = fn(handler) {
    let res = get(with_auto_etag(handler), [])
    response.get_header(res, "etag")
  }
  assert untouched(fn(ctx) {
      note(ctx) |> response.set_header("set-cookie", "a=b")
    })
    == Error(Nil)
  assert untouched(fn(ctx) {
      note(ctx) |> response.set_header("cache-control", "private, no-store")
    })
    == Error(Nil)
  assert untouched(fn(ctx) {
      note(ctx) |> response.set_header("etag", "\"mine\"")
    })
    == Ok("\"mine\"")
  assert untouched(fn(ctx) { controller.status(ctx, 200) }) == Error(Nil)
  assert untouched(fn(ctx) { note(ctx) |> controller.with_status(201) })
    == Error(Nil)
  let put = send(with_auto_etag(note), http.Put, [])
  assert response.get_header(put, "etag") == Error(Nil)
}

pub fn http_dates_round_trip_test() {
  assert conditional.http_date(784_111_777) == "Sun, 06 Nov 1994 08:49:37 GMT"
  assert conditional.parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT")
    == Ok(784_111_777)
  // The two obsolete formats HTTP still allows.
  assert conditional.parse_http_date("Sunday, 06-Nov-94 08:49:37 GMT")
    == Ok(784_111_777)
  assert conditional.parse_http_date("Sun Nov  6 08:49:37 1994")
    == Ok(784_111_777)
  // A leap second is the same instant as the next second.
  assert conditional.parse_http_date("Sat, 31 Dec 2016 23:59:60 GMT")
    == Ok(1_483_228_800)
  assert conditional.parse_http_date("Sun, 31 Feb 1994 08:49:37 GMT")
    == Error(Nil)
  assert conditional.parse_http_date("Sun, 06 Nov 1994 25:49:37 GMT")
    == Error(Nil)
  assert conditional.parse_http_date("yesterday") == Error(Nil)
}

pub fn obsolete_dates_still_guard_writes_test() {
  let res =
    app(conditional.modified_at(1_700_000_000), never)
    |> send(http.Put, [
      #("if-unmodified-since", "Sunday, 06-Nov-94 08:49:37 GMT"),
    ])
  assert res.status == 412
}

pub fn tags_may_contain_commas_test() {
  let tag = "\"a,b\""
  let validators = conditional.quoted_etag(tag)
  assert { app(validators, never) |> get([#("if-none-match", tag)]) }.status
    == 304
  assert {
      app(validators, never)
      |> get([#("if-none-match", "\"x\", W/" <> tag <> ", \"y\"")])
    }.status
    == 304
  assert { app(validators, note) |> get([#("if-none-match", "\"a\"")]) }.status
    == 200
  assert { app(validators, note) |> send(http.Put, [#("if-match", tag)]) }.status
    == 200
  assert {
      app(validators, never) |> send(http.Put, [#("if-match", "\"a\", \"b\"")])
    }.status
    == 412
}

pub fn two_digit_years_follow_the_fifty_year_rule_test() {
  // Read against the real clock: a year that would be more than fifty
  // years ahead is the last one in the past with those digits.
  let assert Ok(now) =
    conditional.parse_http_date(conditional.http_date(system_seconds()))
  let assert Ok(far) =
    conditional.parse_http_date("Friday, 31-Dec-99 08:49:37 GMT")
  let assert Ok(near) =
    conditional.parse_http_date("Friday, 01-Jan-27 08:49:37 GMT")
  assert far < now
  assert near - now < 51 * 365 * 86_400
}

@external(erlang, "os", "system_time")
fn os_system_time(unit: Atom) -> Int

type Atom

@external(erlang, "erlang", "binary_to_atom")
fn atom(name: String) -> Atom

fn system_seconds() -> Int {
  os_system_time(atom("second"))
}

pub fn quotes_are_found_next_to_combining_marks_test() {
  let tag = "\"\u{301}a,b\""
  let validators = conditional.quoted_etag(tag)
  assert { app(validators, never) |> get([#("if-none-match", tag)]) }.status
    == 304
  assert { app(validators, note) |> send(http.Put, [#("if-match", tag)]) }.status
    == 200
}
