import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam/uri
import gloo/adapter/sqlite
import howdy
import howdy/controller
import howdy/database
import howdy/jobs
import howdy/migration
import howdy/notifications.{Delivered, GiveUp, Retry}
import howdy/notifications/web_push.{Subscription}
import howdy/service
import howdy/testing

fn b64(text: String) -> BitArray {
  let assert Ok(bits) = bit_array.base64_url_decode(text)
  bits
}

// -- Encryption --------------------------------------------------------------

/// The worked example in RFC 8291, section 5.
pub fn encryption_matches_rfc_8291_test() {
  let assert Ok(body) =
    web_push.encrypt(
      <<"When I grow up, I want to be a watermelon":utf8>>,
      b64(
        "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
      ),
      b64("BTBZMqHH6r4Tts7J_aSIgg"),
      b64(
        "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
      ),
      b64("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"),
      b64("DGv6ra1nlYgDCS1FRnbzlw"),
    )
  assert bit_array.base64_url_encode(body, False)
    == "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
}

@external(erlang, "howdy_notifications_push_ffi", "generate_keys")
fn generate() -> #(BitArray, BitArray)

@external(erlang, "howdy_notifications_push_ffi", "ecdh")
fn ecdh(public: BitArray, private: BitArray) -> Result(BitArray, Nil)

@external(erlang, "howdy_notifications_push_ffi", "hmac")
fn hmac(key: BitArray, data: BitArray) -> BitArray

@external(erlang, "howdy_notifications_push_ffi", "decrypt")
fn aes_gcm_open(
  key: BitArray,
  nonce: BitArray,
  sealed: BitArray,
  tag_size: Int,
) -> Result(BitArray, Nil)

@external(erlang, "howdy_notifications_push_ffi", "verify")
fn verify(message: BitArray, signature: BitArray, public: BitArray) -> Bool

/// What a browser does with a pushed body: read the header, agree the
/// same keys and open the record.
fn browser_decrypt(
  body: BitArray,
  public: BitArray,
  private: BitArray,
  auth: BitArray,
) -> Result(BitArray, Nil) {
  let assert <<
    salt:bytes-size(16),
    4096:size(32),
    65,
    server:bytes-size(65),
    sealed:bytes,
  >> = body
  use shared <- result.try(ecdh(server, private))
  let prk_key = hmac(auth, shared)
  let key_info = bit_array.concat([<<"WebPush: info":utf8, 0>>, public, server])
  let prk = hmac(salt, hmac(prk_key, <<key_info:bits, 1>>))
  let assert <<cek:bytes-size(16), _:bytes>> =
    hmac(prk, <<"Content-Encoding: aes128gcm":utf8, 0, 1>>)
  let assert <<nonce:bytes-size(12), _:bytes>> =
    hmac(prk, <<"Content-Encoding: nonce":utf8, 0, 1>>)
  aes_gcm_open(cek, nonce, sealed, 16)
}

// -- Keys and VAPID ----------------------------------------------------------

pub fn keys_round_trip_test() {
  let keys = web_push.generate_keys()
  let assert Ok(again) =
    web_push.keys(
      public: web_push.public_key(keys),
      private: web_push.private_key(keys),
    )
  assert web_push.public_key(again) == web_push.public_key(keys)
  let other = web_push.generate_keys()
  assert web_push.keys(
      public: web_push.public_key(other),
      private: web_push.private_key(keys),
    )
    == Error(Nil)
  assert web_push.keys(public: "nope", private: "nope") == Error(Nil)
}

pub fn vapid_tokens_are_signed_es256_test() {
  let keys = web_push.generate_keys()
  let header =
    web_push.vapid(
      keys,
      "https://fcm.googleapis.com",
      "mailto:ops@example.com",
      1_000_000,
    )
  let assert "vapid t=" <> rest = header
  let assert Ok(#(token, key)) = string.split_once(rest, ", k=")
  assert key == web_push.public_key(keys)
  let assert [head, claims, signature] = string.split(token, ".")
  assert bit_array.to_string(b64(head))
    == Ok("{\"typ\":\"JWT\",\"alg\":\"ES256\"}")
  let assert Ok(claims) = bit_array.to_string(b64(claims))
  assert json.parse(claims, {
      use aud <- decode.field("aud", decode.string)
      use exp <- decode.field("exp", decode.int)
      use sub <- decode.field("sub", decode.string)
      decode.success(#(aud, exp, sub))
    })
    == Ok(#(
      "https://fcm.googleapis.com",
      1_000_000 + 43_200,
      "mailto:ops@example.com",
    ))
  let assert Ok(public) = bit_array.base64_url_decode(web_push.public_key(keys))
  assert verify(
    <<{ head <> "." <> token_claims(token) }:utf8>>,
    b64(signature),
    public,
  )
}

fn token_claims(token: String) -> String {
  let assert [_, claims, _] = string.split(token, ".")
  claims
}

// -- Subscriptions -----------------------------------------------------------

fn open_push(
  post: fn(Request(BitArray)) -> Result(response.Response(BitArray), String),
) -> #(notifications.Notifier, web_push.WebPush) {
  let assert Ok(db) = sqlite.start(sqlite.memory())
  let assert Ok(Nil) = database.sqlite_defaults(db)
  let assert Ok(Nil) =
    migration.run(db, [jobs.schema(), notifications.schema()])
  let notifier = notifications.new(db)
  let push =
    web_push.new(notifier, web_push.generate_keys(), contact: "mailto:a@b.c")
    |> web_push.with_post(post)
  #(notifications.with_push(notifier, web_push.deliver(push)), push)
}

fn deliver(notifier: notifications.Notifier) -> jobs.Drained {
  let assert Ok(drained) =
    jobs.runner(notifications.repo(notifier))
    |> notifications.handle_jobs(notifier)
    |> jobs.drain
  drained
}

/// A browser's subscription, with the browser's keys for reading what is
/// sent to it.
fn browser(
  endpoint: String,
) -> #(web_push.Subscription, #(BitArray, BitArray, BitArray)) {
  let #(public, private) = generate()
  let auth = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>
  #(
    Subscription(
      endpoint:,
      p256dh: bit_array.base64_url_encode(public, False),
      auth: bit_array.base64_url_encode(auth, False),
    ),
    #(public, private, auth),
  )
}

fn created(_request) {
  Ok(response.new(201) |> response.set_body(<<>>))
}

pub fn subscriptions_are_checked_and_kept_per_browser_test() {
  let #(_, push) = open_push(created)
  let #(chrome, _) = browser("https://fcm.googleapis.com/fcm/send/abc")
  let #(firefox, _) =
    browser("https://updates.push.services.mozilla.com/wpush/v2/def")
  assert web_push.subscribe(push, "u1", chrome) == Ok(Nil)
  assert web_push.subscribe(push, "u1", firefox) == Ok(Nil)
  assert web_push.subscriptions(push, "u1") |> result.map(list.length) == Ok(2)
  // The same browser, now someone else's.
  assert web_push.subscribe(push, "u2", chrome) == Ok(Nil)
  assert web_push.subscriptions(push, "u1") == Ok([firefox])
  assert web_push.subscriptions(push, "u2") == Ok([chrome])
  // Only the owner can forget one.
  assert web_push.unsubscribe(push, "u1", chrome.endpoint) == Ok(Nil)
  assert web_push.subscriptions(push, "u2") == Ok([chrome])
  assert web_push.unsubscribe(push, "u2", chrome.endpoint) == Ok(Nil)
  assert web_push.subscriptions(push, "u2") == Ok([])

  let refused = fn(subscription) {
    case web_push.subscribe(push, "u1", subscription) {
      Error(service.Invalid(_)) -> True
      _ -> False
    }
  }
  assert refused(
    Subscription(..firefox, endpoint: "http://fcm.googleapis.com/x"),
  )
  assert refused(Subscription(..firefox, endpoint: "https://127.0.0.1/x"))
  assert refused(Subscription(..firefox, endpoint: "https://evil.example/x"))
  assert refused(Subscription(..firefox, p256dh: "short"))
  assert refused(Subscription(..firefox, auth: "AAAA"))

  let custom =
    push
    |> web_push.allow_endpoints(fn(endpoint) {
      endpoint.host == Some("push.example.com")
    })
  let #(own, _) = browser("https://push.example.com/x")
  assert web_push.subscribe(custom, "u1", own) == Ok(Nil)
  assert web_push.known_push_service(
    uri.Uri(..uri.empty, host: Some("db5p.notify.windows.com")),
  )
  // Chromium's own builds, as Chromium 154 on Arch Linux subscribed.
  assert web_push.known_push_service(
    uri.Uri(..uri.empty, host: Some("jmt17.google.com")),
  )
  assert !web_push.known_push_service(
    uri.Uri(..uri.empty, host: Some("evil.google.com.example")),
  )
}

// -- Delivering --------------------------------------------------------------

pub fn notifications_are_encrypted_for_each_browser_test() {
  let sent = process.new_subject()
  let #(notifier, push) =
    open_push(fn(request) {
      process.send(sent, request)
      created(request)
    })
  let #(chrome, #(public, private, auth)) =
    browser("https://fcm.googleapis.com/fcm/send/abc")
  assert web_push.subscribe(push, "u1", chrome) == Ok(Nil)
  let assert Ok(Some(n)) =
    notifications.draft("x", "Ana commented")
    |> notifications.body("Looks good")
    |> notifications.link("/posts/1")
    |> notifications.send(notifier, to: "u1")
  assert deliver(notifier) == jobs.Drained(1, 0, 0, 0, 0)

  let assert Ok(request) = process.receive(sent, 0)
  assert request.method == http.Post
  assert request.host == "fcm.googleapis.com"
  assert request.path == "/fcm/send/abc"
  assert request.get_header(request, "content-encoding") == Ok("aes128gcm")
  assert request.get_header(request, "ttl") == Ok("86400")
  let assert Ok("vapid t=" <> _) = request.get_header(request, "authorization")
  let assert Ok(plaintext) =
    browser_decrypt(request.body, public, private, auth)
  let message = bit_array.byte_size(plaintext) - 1
  let assert <<message:bytes-size(message), 2>> = plaintext
  let assert Ok(message) = bit_array.to_string(message)
  assert json.parse(message, {
      use id <- decode.field("id", decode.string)
      use title <- decode.field("title", decode.string)
      use body <- decode.field("body", decode.string)
      use link <- decode.field("link", decode.optional(decode.string))
      decode.success(#(id, title, body, link))
    })
    == Ok(#(n.id, "Ana commented", "Looks good", Some("/posts/1")))
}

pub fn push_service_answers_decide_the_outcome_test() {
  let answer = fn(status) {
    let #(_, push) =
      open_push(fn(_) { Ok(response.new(status) |> response.set_body(<<>>)) })
    let #(chrome, _) = browser("https://fcm.googleapis.com/fcm/send/abc")
    let assert Ok(Nil) = web_push.subscribe(push, "u1", chrome)
    let outcome = web_push.send(push, chrome, "{}")
    let kept = web_push.subscriptions(push, "u1") == Ok([chrome])
    #(outcome, kept)
  }
  assert answer(201) == #(Delivered, True)
  assert answer(410) == #(GiveUp("the subscription has gone"), False)
  assert answer(404) == #(GiveUp("the subscription has gone"), False)
  assert answer(429) == #(Retry("the push service asked to slow down"), True)
  assert answer(503) == #(Retry("the push service answered 503"), True)
  assert answer(403) == #(GiveUp("the push service answered 403"), True)
}

pub fn a_user_without_subscriptions_is_done_at_once_test() {
  let #(notifier, _) = open_push(fn(_) { panic as "nothing to send" })
  let assert Ok(Some(_)) =
    notifications.draft("x", "Hi") |> notifications.send(notifier, to: "u1")
  assert deliver(notifier) == jobs.Drained(1, 0, 0, 0, 0)
}

// -- Routes ------------------------------------------------------------------

fn app(push) -> howdy.App {
  howdy.new()
  |> howdy.controller(
    web_push.routes(push, at: "/push", identify: fn(ctx: controller.Context) {
      list.key_find(ctx.request.headers, "x-user")
      |> result.replace_error(service.Unauthorized)
    }),
  )
}

pub fn routes_serve_the_worker_key_and_subscriptions_test() {
  let #(_, push) = open_push(created)
  let app = app(push)
  let res = testing.get("/push/worker.js") |> testing.send(app)
  assert res.status == 200
  assert response.get_header(res, "content-type")
    == Ok("text/javascript; charset=utf-8")
  assert string.contains(testing.text(res), "showNotification")

  let res = testing.get("/push/key") |> testing.send(app)
  let assert Ok(key) =
    testing.json(res, decode.field("key", decode.string, decode.success))
  assert bit_array.byte_size(b64(key)) == 65

  let #(chrome, _) = browser("https://fcm.googleapis.com/fcm/send/abc")
  let subscription =
    json.object([
      #("endpoint", json.string(chrome.endpoint)),
      #("expirationTime", json.null()),
      #(
        "keys",
        json.object([
          #("p256dh", json.string(chrome.p256dh)),
          #("auth", json.string(chrome.auth)),
        ]),
      ),
    ])
  let res =
    testing.post("/push/subscriptions", subscription) |> testing.send(app)
  assert res.status == 401
  let res =
    testing.post("/push/subscriptions", subscription)
    |> testing.header("x-user", "u1")
    |> testing.send(app)
  assert res.status == 204
  assert web_push.subscriptions(push, "u1") == Ok([chrome])
  let res =
    testing.request(http.Delete, "/push/subscriptions")
    |> testing.json_body(
      json.object([#("endpoint", json.string(chrome.endpoint))]),
    )
    |> testing.header("x-user", "u1")
    |> testing.send(app)
  assert res.status == 204
  assert web_push.subscriptions(push, "u1") == Ok([])
}

pub fn a_contact_must_be_mailto_or_https_test() {
  let #(notifier, _) = open_push(fn(_) { Error("unused") })
  let keys = web_push.generate_keys()
  let _ = web_push.new(notifier, keys, contact: "https://example.com/contact")
  assert crashes(fn() {
    web_push.new(notifier, keys, contact: "ops@example.com")
  })
  assert crashes(fn() {
    web_push.new(notifier, keys, contact: "http://example.com")
  })
}

@external(erlang, "howdy_notifications_test_ffi", "crashes")
fn crashes(run: fn() -> a) -> Bool
