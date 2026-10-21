//// Web Push: notifications from the browser itself, which reach people
//// whose tabs are closed.
////
//// ```gleam
//// import howdy/notifications/web_push
////
//// let assert Ok(public) = env.get("VAPID_PUBLIC_KEY")
//// let assert Ok(private) = env.get("VAPID_PRIVATE_KEY")
//// let assert Ok(keys) = web_push.keys(public:, private:)
//// let push = web_push.new(notifier, keys, contact: "mailto:ops@example.com")
//// let notifier = notifications.with_push(notifier, web_push.deliver(push))
////
//// howdy.new()
//// |> howdy.controller(web_push.routes(push, at: "/notifications/push", identify:))
//// ```
////
//// Make the keys once with `gleam run -m howdy/notifications/web_push` and
//// keep them in the environment: browsers subscribe with the public key,
//// and every subscription stops working if it changes.
////
//// A user turns push on in each browser they want it in. `howdy/ui/bell`
//// offers that in its panel when given the routes' path with `bell.push`:
//// the browser registers the service worker served by `routes`, subscribes
//// with the push service its maker runs (Google's for Chrome, Mozilla's for
//// Firefox, Apple's for Safari), and the app keeps the subscription. A
//// notification then goes to each of the user's subscriptions, encrypted
//// so that only that browser can read it (RFC 8291), and signed with the
//// app's keys (RFC 8292). Clicking it opens its link.
////
//// The app sends to whatever address a subscription gives, so only the
//// push services of the major browsers are accepted, by default; see
//// `allow_endpoints`. Subscriptions the push service says have gone are
//// deleted.

import argv
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri.{type Uri}
import gloo/sql
import howdy/body
import howdy/controller.{type Context, type Controller}
import howdy/database
import howdy/notifications.{
  type Notification, type Notifier, type Outcome, Delivered, GiveUp, Retry,
}
import howdy/service

// -- Keys --------------------------------------------------------------------

/// The app's VAPID key pair, which identifies it to push services.
pub opaque type Keys {
  Keys(public: BitArray, private: BitArray)
}

/// A new key pair. Make one once and keep it; see the module docs.
pub fn generate_keys() -> Keys {
  let #(public, private) = generate()
  Keys(public:, private:)
}

/// Keys as `generate_keys` makes them and `public_key` and `private_key`
/// write them: base64url, the public key an uncompressed P-256 point and
/// the private key its 32 byte scalar. An error when they are not, or do
/// not belong together.
pub fn keys(
  public public: String,
  private private: String,
) -> Result(Keys, Nil) {
  use public <- result.try(bit_array.base64_url_decode(public))
  use private <- result.try(bit_array.base64_url_decode(private))
  use derived <- result.try(derive_public(private))
  case derived == public {
    True -> Ok(Keys(public:, private:))
    False -> Error(Nil)
  }
}

/// The public key, base64url, which browsers subscribe with.
pub fn public_key(keys: Keys) -> String {
  bit_array.base64_url_encode(keys.public, False)
}

/// The private key, base64url. Keep it secret.
pub fn private_key(keys: Keys) -> String {
  bit_array.base64_url_encode(keys.private, False)
}

/// Print a new key pair, as environment variables:
/// `gleam run -m howdy/notifications/web_push`.
pub fn main() -> Nil {
  case argv.load().arguments {
    [] | ["keys"] -> {
      let keys = generate_keys()
      io.println("VAPID_PUBLIC_KEY=" <> public_key(keys))
      io.println("VAPID_PRIVATE_KEY=" <> private_key(keys))
    }
    _ -> io.println("usage: gleam run -m howdy/notifications/web_push [keys]")
  }
}

// -- Setting up --------------------------------------------------------------

pub opaque type WebPush {
  WebPush(
    notifier: Notifier,
    keys: Keys,
    contact: String,
    ttl: Int,
    allow: fn(Uri) -> Bool,
    post: fn(Request(BitArray)) -> Result(Response(BitArray), String),
  )
}

/// Push for `notifier`'s users. `contact` is a `mailto:` or `https:` URL
/// a push service can use to reach whoever runs the app. Panics on any
/// other: Apple's push service refuses every notification signed without
/// one. Make it a real address, not one on `localhost`, which Apple also
/// refuses.
pub fn new(notifier: Notifier, keys: Keys, contact contact: String) -> WebPush {
  let assert True =
    string.starts_with(contact, "mailto:")
    || string.starts_with(contact, "https://")
    as "howdy/notifications/web_push: contact must be a mailto: or https: URL"
  WebPush(
    notifier:,
    keys:,
    contact:,
    ttl: 86_400,
    allow: known_push_service,
    post: fn(request) {
      httpc.configure()
      |> httpc.timeout(15_000)
      |> httpc.dispatch_bits(request)
      |> result.map_error(string.inspect)
    },
  )
}

/// How long a push service keeps a notification for a browser that is
/// offline, in seconds. Defaults to a day.
pub fn time_to_live(push: WebPush, seconds: Int) -> WebPush {
  WebPush(..push, ttl: int.max(seconds, 0))
}

/// Accept subscriptions whose endpoint `allow` accepts, as well as or
/// instead of the major browsers' push services. Endpoints are always
/// `https`.
pub fn allow_endpoints(push: WebPush, allow: fn(Uri) -> Bool) -> WebPush {
  WebPush(..push, allow:)
}

/// Whether an endpoint belongs to the push service of Chrome, Edge,
/// Firefox or Safari. Chromium builds other than Google's own, such as
/// Linux distributions', subscribe through `jmt17.google.com`.
pub fn known_push_service(endpoint: Uri) -> Bool {
  case endpoint.host {
    Some(host) ->
      list.any(
        [
          "fcm.googleapis.com", "jmt17.google.com",
          "updates.push.services.mozilla.com", "push.services.mozilla.com",
          "web.push.apple.com",
        ],
        fn(known) { host == known },
      )
      || string.ends_with(host, ".notify.windows.com")
      || string.ends_with(host, ".push.apple.com")
    None -> False
  }
}

/// Send requests some other way, for tests.
@internal
pub fn with_post(
  push: WebPush,
  post: fn(Request(BitArray)) -> Result(Response(BitArray), String),
) -> WebPush {
  WebPush(..push, post:)
}

// -- Subscriptions -----------------------------------------------------------

/// Where and how to reach one browser, as its `PushSubscription` gives it.
pub type Subscription {
  Subscription(endpoint: String, p256dh: String, auth: String)
}

/// The JSON a browser's `subscription.toJSON()` gives.
pub fn subscription_decoder() -> decode.Decoder(Subscription) {
  use endpoint <- decode.field("endpoint", decode.string)
  use p256dh <- decode.subfield(["keys", "p256dh"], decode.string)
  use auth <- decode.subfield(["keys", "auth"], decode.string)
  decode.success(Subscription(endpoint:, p256dh:, auth:))
}

/// Keep a browser's subscription for `recipient`. A subscription is one
/// browser, so one already kept for someone else, after they signed out
/// on a shared computer, moves to `recipient`.
pub fn subscribe(
  push: WebPush,
  recipient: String,
  subscription: Subscription,
) -> service.Result(Nil) {
  use _ <- result.try(check(push, subscription))
  let repo = notifications.repo(push.notifier)
  use conn <- database.write_transaction(
    repo,
    touching: "howdy_notifications_push_subscriptions",
  )
  use _ <- result.try(
    database.execute(
      conn,
      "DELETE FROM howdy_notifications_push_subscriptions WHERE endpoint = $1",
      [sql.string(subscription.endpoint)],
    ),
  )
  database.execute(
    conn,
    "INSERT INTO howdy_notifications_push_subscriptions
       (endpoint, user_id, p256dh, auth, created_at)
     VALUES ($1, $2, $3, $4, $5)",
    [
      sql.string(subscription.endpoint),
      sql.string(recipient),
      sql.string(subscription.p256dh),
      sql.string(subscription.auth),
      sql.int(now_ms()),
    ],
  )
}

/// Forget a browser's subscription, if it is `recipient`'s.
pub fn unsubscribe(
  push: WebPush,
  recipient: String,
  endpoint: String,
) -> service.Result(Nil) {
  database.execute(
    notifications.repo(push.notifier),
    "DELETE FROM howdy_notifications_push_subscriptions
     WHERE endpoint = $1 AND user_id = $2",
    [sql.string(endpoint), sql.string(recipient)],
  )
}

/// Every browser `recipient` has turned push on in.
pub fn subscriptions(
  push: WebPush,
  recipient: String,
) -> service.Result(List(Subscription)) {
  database.query(
    notifications.repo(push.notifier),
    "SELECT endpoint, p256dh, auth FROM howdy_notifications_push_subscriptions
     WHERE user_id = $1 ORDER BY created_at, endpoint",
    [sql.string(recipient)],
    {
      use endpoint <- decode.field(0, decode.string)
      use p256dh <- decode.field(1, decode.string)
      use auth <- decode.field(2, decode.string)
      decode.success(Subscription(endpoint:, p256dh:, auth:))
    },
  )
}

fn check(push: WebPush, subscription: Subscription) -> service.Result(Nil) {
  let invalid = fn(message) { Error(service.Invalid(message)) }
  case uri.parse(subscription.endpoint) {
    Ok(endpoint) if endpoint.scheme == Some("https") ->
      case push.allow(endpoint) {
        False -> invalid("that push service is not accepted")
        True ->
          case
            decode_key(subscription.p256dh, 65),
            decode_key(subscription.auth, 16)
          {
            Ok(_), Ok(_) -> Ok(Nil)
            _, _ -> invalid("the subscription's keys are not valid")
          }
      }
    _ -> invalid("a push endpoint is an https URL")
  }
}

fn decode_key(key: String, size: Int) -> Result(BitArray, Nil) {
  use bits <- result.try(bit_array.base64_url_decode(key))
  case bit_array.byte_size(bits) == size {
    True -> Ok(bits)
    False -> Error(Nil)
  }
}

// -- Sending -----------------------------------------------------------------

/// Deliver a notification to every browser its recipient turned push on
/// in, for `notifications.with_push`. A recipient with none is done at
/// once. Subscriptions the push service says have gone are deleted.
///
/// If any browser's push service asks to be tried later, the whole
/// notification is tried again, so the others may get it twice; it is
/// sent with its ID as the tag, so the browser shows it once.
pub fn deliver(push: WebPush) -> fn(Notification) -> Outcome {
  fn(notification: Notification) {
    case subscriptions(push, notification.recipient) {
      Error(error) -> Retry(service.message(error))
      Ok([]) -> Delivered
      Ok(subscriptions) -> {
        let outcomes =
          list.map(subscriptions, fn(subscription) {
            send(push, subscription, payload(notification))
          })
        case list.find(outcomes, fn(outcome) { outcome != Delivered }) {
          Error(Nil) -> Delivered
          Ok(_) ->
            case
              list.find(outcomes, fn(outcome) {
                case outcome {
                  Retry(_) -> True
                  _ -> False
                }
              })
            {
              Ok(retry) -> retry
              // Only gone or refused ones: the rest got it.
              Error(Nil) ->
                case list.any(outcomes, fn(outcome) { outcome == Delivered }) {
                  True -> Delivered
                  False -> {
                    let assert Ok(failure) = list.first(outcomes)
                    failure
                  }
                }
            }
        }
      }
    }
  }
}

/// What the service worker is sent.
fn payload(notification: Notification) -> String {
  json.object([
    #("id", json.string(notification.id)),
    #("title", json.string(notification.title)),
    #("body", json.string(notification.body)),
    #("link", json.nullable(notification.link, json.string)),
  ])
  |> json.to_string
}

/// Encrypt and send one message to one browser.
pub fn send(
  push: WebPush,
  subscription: Subscription,
  message: String,
) -> Outcome {
  let request = {
    use endpoint <- result.try(uri.parse(subscription.endpoint))
    use body <- result.try(encrypt_for(subscription, <<message:utf8>>))
    use request <- result.map(request.from_uri(endpoint))
    request
    |> request.set_method(http.Post)
    |> request.set_header("content-encoding", "aes128gcm")
    |> request.set_header("content-type", "application/octet-stream")
    |> request.set_header("ttl", int.to_string(push.ttl))
    |> request.set_header("urgency", "normal")
    |> request.set_header(
      "authorization",
      vapid(push.keys, audience(endpoint), push.contact, now_ms() / 1000),
    )
    |> request.set_body(body)
  }
  case request {
    Error(Nil) -> {
      forget(push, subscription)
      GiveUp("the subscription is not valid")
    }
    Ok(request) ->
      case push.post(request) {
        Error(reason) -> Retry(reason)
        Ok(response) ->
          case response.status {
            status if status >= 200 && status < 300 -> Delivered
            // The browser unsubscribed, or the subscription expired.
            404 | 410 -> {
              forget(push, subscription)
              GiveUp("the subscription has gone")
            }
            429 -> Retry("the push service asked to slow down")
            status if status >= 500 ->
              Retry("the push service answered " <> int.to_string(status))
            status ->
              GiveUp("the push service answered " <> int.to_string(status))
          }
      }
  }
}

fn forget(push: WebPush, subscription: Subscription) -> Nil {
  let _ =
    database.execute(
      notifications.repo(push.notifier),
      "DELETE FROM howdy_notifications_push_subscriptions WHERE endpoint = $1",
      [sql.string(subscription.endpoint)],
    )
  Nil
}

/// The origin a VAPID token is for.
fn audience(endpoint: Uri) -> String {
  let port = case endpoint.port {
    Some(port) -> ":" <> int.to_string(port)
    None -> ""
  }
  option.unwrap(endpoint.scheme, "https")
  <> "://"
  <> option.unwrap(endpoint.host, "")
  <> port
}

// -- Encryption (RFC 8291 and RFC 8188) ---------------------------------------

fn encrypt_for(
  subscription: Subscription,
  plaintext: BitArray,
) -> Result(BitArray, Nil) {
  use browser_public <- result.try(decode_key(subscription.p256dh, 65))
  use auth <- result.try(decode_key(subscription.auth, 16))
  let #(public, private) = generate()
  encrypt(plaintext, browser_public, auth, public, private, random_bytes(16))
}

/// The `aes128gcm` body for one browser: its header, with the salt and the
/// app's one-time public key, then the record.
@internal
pub fn encrypt(
  plaintext: BitArray,
  browser_public: BitArray,
  auth: BitArray,
  public: BitArray,
  private: BitArray,
  salt: BitArray,
) -> Result(BitArray, Nil) {
  use shared <- result.map(ecdh(browser_public, private))
  let prk_key = hmac(auth, shared)
  let key_info =
    bit_array.concat([<<"WebPush: info":utf8, 0>>, browser_public, public])
  let ikm = hmac(prk_key, <<key_info:bits, 1>>)
  let prk = hmac(salt, ikm)
  let assert <<cek:bytes-size(16), _:bytes>> =
    hmac(prk, <<"Content-Encoding: aes128gcm":utf8, 0, 1>>)
  let assert <<nonce:bytes-size(12), _:bytes>> =
    hmac(prk, <<"Content-Encoding: nonce":utf8, 0, 1>>)
  // One record, so it is the last, marked with 2 and no padding.
  let sealed = aes_gcm(cek, nonce, <<plaintext:bits, 2>>)
  bit_array.concat([salt, <<4096:size(32), 65>>, public, sealed])
}

// -- VAPID (RFC 8292) ---------------------------------------------------------

/// The `authorization` header value for an endpoint at `audience`, valid
/// for twelve hours from `now` in unix seconds.
@internal
pub fn vapid(
  keys: Keys,
  audience: String,
  contact: String,
  now: Int,
) -> String {
  let encode = fn(json) {
    json.to_string(json)
    |> bit_array.from_string
    |> bit_array.base64_url_encode(False)
  }
  let header =
    encode(
      json.object([#("typ", json.string("JWT")), #("alg", json.string("ES256"))]),
    )
  let claims =
    encode(
      json.object([
        #("aud", json.string(audience)),
        #("exp", json.int(now + 12 * 3600)),
        #("sub", json.string(contact)),
      ]),
    )
  let signed = header <> "." <> claims
  let signature =
    sign(<<signed:utf8>>, keys.private) |> bit_array.base64_url_encode(False)
  "vapid t=" <> signed <> "." <> signature <> ", k=" <> public_key(keys)
}

// -- Routes ------------------------------------------------------------------

/// What browsers need to turn push on and off, for `bell.push` or a page
/// of your own. `identify` names the signed-in user, as for
/// `notifications.routes`, and must refuse cross-site writes.
///
/// - `GET /worker.js` is the service worker, which shows each notification
///   and opens its link when it is clicked.
/// - `GET /key` gives `{"key": "..."}`, the public key to subscribe with.
/// - `POST /subscriptions` keeps the JSON of a browser's subscription for
///   the user.
/// - `DELETE /subscriptions` forgets one, given `{"endpoint": "..."}`.
pub fn routes(
  push: WebPush,
  at prefix: String,
  identify identify: fn(Context) -> service.Result(String),
) -> Controller {
  let user = fn(ctx, next) {
    case identify(ctx) {
      Ok(recipient) -> next(recipient)
      Error(error) -> service.error_response(ctx, error)
    }
  }
  controller.new(prefix)
  |> controller.get("/worker.js", fn(ctx) {
    controller.text(ctx, service_worker())
    |> response.set_header("content-type", "text/javascript; charset=utf-8")
    |> response.set_header("cache-control", "no-cache")
  })
  |> controller.get("/key", fn(ctx) {
    controller.json(
      ctx,
      json.object([#("key", json.string(public_key(push.keys)))]),
    )
  })
  |> controller.post("/subscriptions", fn(ctx) {
    use recipient <- user(ctx)
    use subscription <- body.json(ctx, subscription_decoder())
    subscribe(push, recipient, subscription)
    |> service.no_content(ctx)
  })
  |> controller.delete("/subscriptions", fn(ctx) {
    use recipient <- user(ctx)
    use endpoint <- body.json(
      ctx,
      decode.field("endpoint", decode.string, decode.success),
    )
    unsubscribe(push, recipient, endpoint)
    |> service.no_content(ctx)
  })
}

/// The service worker's source. It shows each push as a notification,
/// tagged with the notification's ID, and on a click focuses a tab already
/// at its link or opens one.
pub fn service_worker() -> String {
  "self.addEventListener('push', (event) => {
  let message = {};
  try { message = event.data ? event.data.json() : {}; } catch {}
  const url = new URL(message.link || '/', self.location.origin).href;
  event.waitUntil(self.registration.showNotification(message.title || '', {
    body: message.body || '',
    tag: message.id,
    data: { url },
  }));
});
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = event.notification.data && event.notification.data.url;
  if (!url) return;
  event.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((tabs) => {
    const open = tabs.find((tab) => tab.url === url);
    return open ? open.focus() : self.clients.openWindow(url);
  }));
});
"
}

// -- FFI ---------------------------------------------------------------------

@external(erlang, "howdy_notifications_push_ffi", "generate_keys")
fn generate() -> #(BitArray, BitArray)

@external(erlang, "howdy_notifications_push_ffi", "public_key")
fn derive_public(private: BitArray) -> Result(BitArray, Nil)

@external(erlang, "howdy_notifications_push_ffi", "ecdh")
fn ecdh(public: BitArray, private: BitArray) -> Result(BitArray, Nil)

@external(erlang, "howdy_notifications_push_ffi", "hmac")
fn hmac(key: BitArray, data: BitArray) -> BitArray

@external(erlang, "howdy_notifications_push_ffi", "encrypt")
fn aes_gcm(key: BitArray, nonce: BitArray, plaintext: BitArray) -> BitArray

@external(erlang, "howdy_notifications_push_ffi", "sign")
fn sign(message: BitArray, private: BitArray) -> BitArray

@external(erlang, "howdy_notifications_push_ffi", "random_bytes")
fn random_bytes(size: Int) -> BitArray

@external(erlang, "howdy_notifications_ffi", "now_ms")
fn now_ms() -> Int
