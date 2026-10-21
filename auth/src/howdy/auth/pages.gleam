//// Optional accessible starter pages. Omit this controller when bringing your
//// own UI; the JSON routes and headless operations remain available.
////
//// The pages are written in the locale `auth.with_locales` chooses for each
//// request, in English by default, and set `lang` and `dir` to match. Their
//// script's words travel in a JSON block on each page, so the script itself
//// stays one cacheable file. The words live in `auth/locales/pages/*.json`;
//// after editing them, regenerate `howdy/auth/internal/pages_messages` with
//// `cd i18n && gleam run -m howdy/i18n/cli -- gen --locales=../auth/locales/pages --out=../auth/src/howdy/auth/internal/pages_messages.gleam`.

import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import howdy/auth.{type Auth}
import howdy/auth/internal/pages_messages as m
import howdy/auth/internal/token
import howdy/auth/policy
import howdy/controller
import howdy/guard
import howdy/i18n.{type Translator}
import howdy/locale
import howdy/query

pub fn routes(
  identity: Auth,
  at prefix: String,
  api_at api: String,
) -> controller.Controller {
  // Restrict mount paths so they can safely appear in HTML attributes.
  let assert True = safe_path(prefix) && safe_path(api)
    as "auth pages require absolute paths containing letters, numbers, slash, hyphen or underscore"
  let script_path = prefix <> "/client.js"
  controller.new(prefix)
  |> controller.middleware(fn(ctx, next) {
    let answer = next(ctx)
    // Pages carry credentials in their responses; the script is a constant
    // and sets its own validator, so it is the one thing worth storing.
    case ctx.request.path == script_path {
      True -> answer
      False -> response.set_header(answer, "cache-control", "no-store")
    }
    // Provider buttons are forms whose handler redirects to the identity
    // provider, and browsers apply `form-action` to that redirect too, so
    // any HTTPS origin is allowed there: the destinations come from the
    // configured providers, never from the request.
    |> response.set_header(
      "content-security-policy",
      "default-src 'none'; script-src 'self'; connect-src 'self'; form-action 'self' https:; base-uri 'none'; frame-ancestors 'none'",
    )
    |> response.set_header("referrer-policy", "no-referrer")
    |> response.set_header("x-content-type-options", "nosniff")
  })
  |> controller.get("/login", fn(ctx) {
    login_page(ctx, identity, prefix, api, TokenLogin)
  })
  |> controller.get("/register", fn(ctx) {
    case auth.registration_enabled(identity) {
      True -> login_page(ctx, identity, prefix, api, TokenRegister)
      False -> controller.status(ctx, 404)
    }
  })
  |> controller.get("/password/login", fn(ctx) {
    case auth.passwords_enabled(identity) {
      True -> login_page(ctx, identity, prefix, api, PasswordLogin)
      False -> controller.status(ctx, 404)
    }
  })
  |> controller.get("/password/register", fn(ctx) {
    case
      auth.passwords_enabled(identity)
      && auth.registration_enabled(identity)
      && auth.email_tokens_enabled(identity)
    {
      True -> login_page(ctx, identity, prefix, api, PasswordRegister)
      False -> controller.status(ctx, 404)
    }
  })
  |> controller.get("/mfa", fn(ctx) {
    let t = translator(identity, ctx)
    let title = m.page_verify_sign_in(t)
    controller.html(
      ctx,
      document(
        identity,
        t,
        prefix,
        title,
        "<main><h1>" <> escape(title) <> "</h1>",
      )
        <> mfa_login(identity, t, api, False)
        <> "<p id=\"status\" role=\"status\" aria-live=\"polite\"></p><a href=\""
        <> escape(prefix)
        <> "/account\">"
        <> escape(m.page_your_account(t))
        <> "</a></main></body></html>",
    )
  })
  |> controller.get("/account", fn(ctx) {
    use principal <- guard.require(ctx, auth.required(identity))
    let t = translator(identity, ctx)
    controller.html(
      ctx,
      account_page(identity, t, prefix, api, principal.user.locale),
    )
  })
  |> controller.get("/client.js", fn(ctx) {
    // Revalidate rather than expire: an upgraded package must never be served
    // an older script, and a matching validator costs an empty 304.
    let tag = script_tag()
    case request.get_header(ctx.request, "if-none-match") == Ok(tag) {
      True -> controller.status(ctx, 304)
      False ->
        controller.text(ctx, script)
        |> response.set_header("content-type", "text/javascript; charset=utf-8")
    }
    |> response.set_header("cache-control", "no-cache")
    |> response.set_header("etag", tag)
  })
}

fn translator(identity: Auth, ctx: controller.Context) -> Translator {
  i18n.new(locale.to_string(auth.request_locale(identity, ctx)))
}

fn safe_path(path: String) -> Bool {
  string.starts_with(path, "/")
  && !string.ends_with(path, "/")
  && list.all(string.to_graphemes(path), fn(c) {
    string.contains(
      "/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
      c,
    )
  })
}

/// The script is a constant per release, so its digest identifies the version
/// a browser already holds.
fn script_tag() -> String {
  "\"" <> token.digest(script) <> "\""
}

/// Escape a value for an HTML text node or a double-quoted attribute. Every
/// value these pages interpolate is validated, constant or a translation;
/// escaping is what keeps translations and later edits from breaking out.
fn escape(value: String) -> String {
  value
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&#39;")
}

/// The start of every page, up to and including `<body>` and `opening`:
/// the language and direction, the title, the script and its words.
fn document(
  identity: Auth,
  t: Translator,
  prefix: String,
  title: String,
  opening: String,
) -> String {
  let tag = i18n.locale(t)
  let direction = case locale.parse(tag) |> result.map(locale.right_to_left) {
    Ok(True) -> "rtl"
    _ -> "ltr"
  }
  "<!doctype html><html lang=\""
  <> escape(tag)
  <> "\" dir=\""
  <> direction
  <> "\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>"
  <> escape(title)
  <> "</title><script type=\"application/json\" id=\"auth-words\">"
  <> words_json(identity, t)
  <> "</script><script src=\""
  <> escape(prefix)
  <> "/client.js\" defer></script></head><body>"
  <> opening
}

/// The script's words as JSON that is safe inside a `<script>` element: no
/// `<`, `>` or `&` can end the element or start a comment, and the line
/// separators some parsers reject are escaped too.
@internal
pub fn words_json(identity: Auth, t: Translator) -> String {
  json.object(
    list.map(words(identity, t), fn(word) { #(word.0, json.string(word.1)) }),
  )
  |> json.to_string
  |> script_safe
}

/// JSON text made safe to place inside a `<script>` element.
@internal
pub fn script_safe(json: String) -> String {
  json
  |> string.replace("<", "\\u003c")
  |> string.replace(">", "\\u003e")
  |> string.replace("&", "\\u0026")
  |> string.replace("\u{2028}", "\\u2028")
  |> string.replace("\u{2029}", "\\u2029")
}

/// Every word the script uses. Placeholders such as `{date}` are filled in
/// by the script.
fn words(identity: Auth, t: Translator) -> List(#(String, String)) {
  [
    #("retry", m.client_retry(t)),
    #("signed_in", m.client_signed_in(t)),
    #("enter_code_email", m.client_enter_code_email(t)),
    #("press_continue", m.client_press_continue(t)),
    #("this_session", m.client_this_session(t)),
    #("other_session", m.client_other_session(t)),
    #(
      "session_line",
      m.client_session_line(
        t,
        state: "{state}",
        method: "{method}",
        created: "{created}",
        used: "{used}",
      ),
    ),
    #("revoke_session", m.client_revoke_session(t)),
    #("signed_out", m.client_signed_out(t)),
    #("session_revoked", m.client_session_revoked(t)),
    #("unlink", m.client_unlink(t)),
    #("provider_unlinked", m.client_provider_unlinked(t)),
    #("email_changed", m.client_email_changed(t)),
    #("press_approve", m.client_press_approve(t)),
    #("press_confirm", m.client_press_confirm(t)),
    #("account_deleted", m.client_account_deleted(t)),
    #("password_saved", m.client_password_saved(t)),
    #("current_account", m.client_current_account(t, email: "{email}")),
    #("switch", m.client_switch(t)),
    #("verify_mfa", m.client_verify_mfa(t)),
    #("code_sent", m.client_code_sent(t)),
    #("passkey_cancelled", m.client_passkey_cancelled(t)),
    #("no_passkeys", m.client_no_passkeys(t)),
    #(
      "passkey_registration_cancelled",
      m.client_passkey_registration_cancelled(t),
    ),
    #("backed_up", m.client_backed_up(t, name: "{name}")),
    #("passkey_name", m.page_passkey_name_label(t)),
    #("rename", m.client_rename(t)),
    #("remove", m.client_remove(t)),
    #("passkey_removed", m.client_passkey_removed(t)),
    #("passkey_added", m.client_passkey_added(t)),
    #("scan_key", m.client_scan_key(t, key: "{key}")),
    #("enter_key", m.client_enter_key(t, key: "{key}")),
    #("check_contact", m.client_check_contact(t)),
    #("confirm_to_enable", m.client_confirm_to_enable(t)),
    #("qr_label", m.client_qr_label(t)),
    #("mfa_enabled", m.client_mfa_enabled(t)),
    #("recovery_replaced", m.client_recovery_replaced(t)),
    #("enrollment_retry", m.client_enrollment_retry(t, error: "{error}")),
    #("mfa_disabled", m.client_mfa_disabled(t)),
    #("remembered", m.client_remembered(t, date: "{date}")),
    #("forget_device", m.client_forget_device(t)),
    #("device_forgotten", m.client_device_forgotten(t)),
    #("mfa_on", m.client_mfa_on(t, method: "{method}")),
    #("mfa_off", m.client_mfa_off(t)),
    #("error.unauthorized", m.error_unauthorized(t)),
    #("error.forbidden", m.error_forbidden(t)),
    #("error.not_found", m.error_not_found(t)),
    #("error.invalid", m.error_invalid(t)),
    #("error.conflict", m.error_conflict(t)),
    #("error.validation", m.error_validation(t)),
    #("error.too_many_requests", m.error_too_many_requests(t)),
    #("error.unsupported_media_type", m.error_unsupported_media_type(t)),
    #("error.internal", m.error_internal(t)),
    #("error.password_incorrect", m.error_password_incorrect(t)),
    #("error.password_unchanged", m.error_password_unchanged(t)),
    #("error.password_common", m.error_password_common(t)),
    #(
      "error.password_length",
      m.error_password_length(
        t,
        count: auth.policy(identity).password_min_length,
      ),
    ),
    #(
      "error.password_too_long",
      m.error_password_too_long(t, count: policy.password_max_bytes),
    ),
    #("error.email_invalid", m.error_email_invalid(t)),
    #("error.email_unchanged", m.error_email_unchanged(t)),
    #("error.email_mismatch", m.error_email_mismatch(t)),
    #("error.email_taken", m.error_email_taken(t)),
    #("error.mfa_enabled", m.error_mfa_enabled(t)),
    #("error.passkey_limit", m.error_passkey_limit(t)),
    #("error.passkey_registered", m.error_passkey_registered(t)),
    #("error.passkey_name", m.error_passkey_name(t)),
    #("error.provider_linked", m.error_provider_linked(t)),
    #("error.credential_too_large", m.error_credential_too_large(t)),
    #("error.locale_unsupported", m.error_locale_unsupported(t)),
    #("error.group_required", m.error_group_required(t)),
    #("message.token_sent", m.message_token_sent(t)),
    #("message.signup_token_sent", m.message_signup_token_sent(t)),
    #("message.approval_sent", m.message_approval_sent(t)),
    #("message.confirmation_sent", m.message_confirmation_sent(t)),
  ]
}

type Page {
  TokenLogin
  TokenRegister
  PasswordLogin
  PasswordRegister
}

fn login_page(ctx, identity, prefix, api, kind) {
  use group <- query.optional_string(ctx, "group")
  let t = translator(identity, ctx)
  controller.html(ctx, page(identity, t, prefix, api, kind, group))
}

fn provider_forms(
  identity: Auth,
  t: Translator,
  prefix: String,
  action: String,
  group: Option(String),
) -> String {
  list.map(auth.providers(identity), fn(p) {
    let #(id, name) = p
    let query = case group {
      Some(g) -> "?" <> uri.query_to_string([#("group", g)])
      None -> ""
    }
    "<form method=\"post\" action=\""
    <> escape(prefix <> "/providers/" <> id <> "/" <> action <> query)
    <> "\"><button>"
    <> escape(case action {
      "link" -> m.page_link_provider(t, provider: name)
      _ -> m.page_continue_with(t, provider: name)
    })
    <> "</button></form>"
  })
  |> string.join("")
}

fn page(
  identity: Auth,
  t: Translator,
  prefix: String,
  api: String,
  page: Page,
  group: Option(String),
) -> String {
  // Translations are escaped like anything else written into the page.
  let say = fn(text) { escape(text) }
  let raw_prefix = prefix
  // The mount paths are the only values here the application supplies.
  let prefix = escape(prefix)
  let api = escape(api)
  let #(register, password) = case page {
    TokenLogin -> #(False, False)
    TokenRegister -> #(True, False)
    PasswordLogin -> #(False, True)
    PasswordRegister -> #(True, True)
  }
  let title = case register {
    True -> m.page_create_account(t)
    False -> m.page_sign_in(t)
  }
  let action = case page {
    PasswordRegister -> "password/register"
    PasswordLogin -> "password/session"
    TokenRegister -> "register"
    TokenLogin -> "login"
  }
  let password_field = case password {
    False -> ""
    True -> {
      let autocomplete = case register {
        True -> "new-password"
        False -> "current-password"
      }
      "<label>"
      <> say(m.page_password_label(t))
      <> " <input name=\"password\" type=\"password\" autocomplete=\""
      <> autocomplete
      <> "\" required></label>"
    }
  }
  let minutes = auth.policy(identity).challenge_seconds / 60
  let explanation = case password, register {
    True, True ->
      m.page_explain_password_register(
        t,
        count: auth.policy(identity).password_min_length,
      )
    True, False -> m.page_explain_password_login(t)
    False, _ ->
      case auth.email_codes_enabled(identity) {
        True -> m.page_explain_code(t, minutes:)
        False -> m.page_explain_token(t, minutes:)
      }
  }
  let button = case password && !register {
    True -> m.page_sign_in(t)
    False -> m.page_send_token(t)
  }
  let exchange = case password && !register {
    True -> ""
    False ->
      case auth.email_codes_enabled(identity) {
        True ->
          "<form method=\"post\" id=\"exchange\"><label>"
          <> say(m.page_code_or_token_label(t))
          <> " <input name=\"token\" autocomplete=\"one-time-code\" required minlength=\"6\" maxlength=\"43\"></label><button>"
          <> say(m.page_continue(t))
          <> "</button></form>"
        False ->
          "<form method=\"post\" id=\"exchange\"><label>"
          <> say(m.page_token_label(t))
          <> " <input name=\"token\" autocomplete=\"one-time-code\" required minlength=\"43\" maxlength=\"43\"></label><button>"
          <> say(m.page_continue(t))
          <> "</button></form>"
      }
  }
  let alternative = case password, auth.passwords_enabled(identity) {
    True, _ ->
      "<p><a href=\""
      <> prefix
      <> case register {
        True -> "/register"
        False -> "/login"
      }
      <> "\">"
      <> say(m.page_use_email_token(t))
      <> "</a></p>"
    False, True ->
      "<p><a href=\""
      <> prefix
      <> case register {
        True -> "/password/register"
        False -> "/password/login"
      }
      <> "\">"
      <> say(m.page_use_password(t))
      <> "</a></p>"
    False, False -> ""
  }
  let credentials = case auth.email_tokens_enabled(identity) || password {
    True -> {
      "<p>"
      <> say(explanation)
      <> "</p><form method=\"post\" id=\"request\" data-api=\""
      <> api
      <> "\" data-action=\""
      <> action
      <> "\"><label>"
      <> say(m.page_email_label(t))
      <> " <input name=\"email\" type=\"email\" autocomplete=\""
      // `webauthn` lets the browser offer passkeys in this field's autofill.
      <> case auth.passkeys_enabled(identity) && !register {
        True -> "username webauthn"
        False -> "username"
      }
      <> "\" required maxlength=\"254\"></label>"
      <> password_field
      <> "<button>"
      <> say(button)
      <> "</button></form>"
      <> exchange
      <> alternative
    }
    False -> ""
  }
  document(
    identity,
    t,
    raw_prefix,
    title,
    "<main><h1>" <> say(title) <> "</h1>",
  )
  <> provider_forms(identity, t, raw_prefix, "login", group)
  <> credentials
  <> case register, auth.passkeys_enabled(identity) {
    False, True ->
      "<button id=\"passkey-login\" data-api=\""
      <> api
      <> "\">"
      <> say(m.page_passkey_login(t))
      <> "</button>"
    True, _ ->
      case auth.passkey_signup_enabled(identity) && !password {
        True ->
          "<h2>"
          <> say(m.page_passkey_register_heading(t))
          <> "</h2><p>"
          <> say(m.page_passkey_register_explain(t))
          <> "</p><form id=\"passkey-signup\"><label>"
          <> say(m.page_email_label(t))
          <> " <input name=\"email\" type=\"email\" autocomplete=\"username\" required maxlength=\"254\"></label><label>"
          <> say(m.page_passkey_name_label(t))
          <> " <input name=\"name\" required maxlength=\"100\" value=\""
          <> say(m.page_passkey_default_name(t))
          <> "\"></label><button>"
          <> say(m.page_create_passkey(t))
          <> "</button></form>"
        False -> ""
      }
    False, False -> ""
  }
  <> mfa_login(identity, t, api, True)
  <> "<p><a href=\""
  <> prefix
  <> "/account\">"
  <> say(m.page_manage_account(t))
  <> "</a></p>"
  <> "<p id=\"status\" role=\"status\" aria-live=\"polite\"></p><noscript>"
  <> say(m.page_noscript_login(t))
  <> "</noscript></main></body></html>"
}

fn delivered_option(identity: Auth, t: Translator) -> String {
  case auth.mfa_delivery_enabled(identity) {
    True ->
      "<option value=\"otp\">"
      <> escape(m.page_delivered_code(t))
      <> "</option>"
    False -> ""
  }
}

fn delivered_button(identity: Auth, t: Translator) -> String {
  case auth.mfa_delivery_enabled(identity) {
    True ->
      "<button id=\"mfa-send\">"
      <> escape(m.page_send_delivered_code(t))
      <> "</button>"
    False -> ""
  }
}

fn mfa_login(
  identity: Auth,
  t: Translator,
  api: String,
  hidden: Bool,
) -> String {
  "<section id=\"mfa-login\" data-api=\""
  <> escape(api)
  <> "\""
  <> case hidden {
    True -> " hidden"
    False -> ""
  }
  <> "><h2>"
  <> escape(m.page_second_factor(t))
  <> "</h2><form id=\"mfa-verify\"><label>"
  <> escape(m.page_method_label(t))
  <> " <select name=\"method\"><option value=\"totp\">"
  <> escape(m.page_authenticator_app(t))
  <> "</option>"
  <> delivered_option(identity, t)
  <> "<option value=\"recovery\">"
  <> escape(m.page_recovery_code(t))
  <> "</option></select></label><label>"
  <> escape(m.page_code_label(t))
  <> " <input name=\"code\" autocomplete=\"one-time-code\" required maxlength=\"64\"></label><label><input name=\"remember\" type=\"checkbox\">"
  <> escape(m.page_remember_device(
    t,
    period: trust_period(t, auth.mfa_trust_seconds(identity)),
  ))
  <> "</label><button>"
  <> escape(m.page_verify_sign_in(t))
  <> "</button></form>"
  <> delivered_button(identity, t)
  <> "</section>"
}

fn trust_period(t: Translator, seconds: Int) -> String {
  case seconds {
    s if s >= 172_800 -> m.page_period_days(t, count: s / 86_400)
    s if s >= 7200 -> m.page_period_hours(t, count: s / 3600)
    s -> m.page_period_minutes(t, count: s / 60)
  }
}

fn security_settings(identity: Auth, t: Translator) -> String {
  let say = escape
  let passkeys = case auth.passkeys_enabled(identity) {
    False -> ""
    True ->
      "<h2>"
      <> say(m.page_passkeys_heading(t))
      <> "</h2><p>"
      <> say(m.page_passkeys_explain(t))
      <> "</p><form id=\"passkey-add\"><label>"
      <> say(m.page_passkey_name_label(t))
      <> " <input name=\"name\" required maxlength=\"100\"></label><button>"
      <> say(m.page_add_passkey(t))
      <> "</button></form><ul id=\"passkeys\"></ul>"
  }
  let mfa = case auth.mfa_enabled(identity) {
    False -> ""
    True ->
      "<h2>"
      <> say(m.page_mfa_heading(t))
      <> "</h2><p id=\"mfa-state\"></p><p>"
      <> say(m.page_mfa_explain(t))
      <> "</p><form id=\"mfa-enroll\"><label>"
      <> say(m.page_method_label(t))
      <> " <select name=\"method\"><option value=\"totp\">"
      <> say(m.page_authenticator_app(t))
      <> "</option>"
      <> delivered_option(identity, t)
      <> "</select></label><button>"
      <> say(m.page_start_enrollment(t))
      <> "</button></form><div id=\"mfa-setup-qr\"></div><pre id=\"mfa-setup-key\"></pre><form id=\"mfa-enroll-confirm\" hidden><label>"
      <> say(m.page_confirmation_code_label(t))
      <> " <input name=\"code\" autocomplete=\"one-time-code\" required maxlength=\"6\"></label><button>"
      <> say(m.page_enable_mfa(t))
      <> "</button></form><button id=\"mfa-disable\">"
      <> say(m.page_disable_mfa(t))
      <> "</button><button id=\"mfa-recovery\">"
      <> say(m.page_replace_recovery(t))
      <> "</button><p>"
      <> say(m.page_recovery_explain(t))
      <> "</p><pre id=\"recovery-codes\"></pre><h3>"
      <> say(m.page_remembered_devices(t))
      <> "</h3><ul id=\"trusted-devices\"></ul>"
  }
  passkeys <> mfa
}

/// A choice of language for the signed-in user, when there is more than one.
fn language_form(
  identity: Auth,
  t: Translator,
  current: Option(String),
) -> String {
  case locale.supported(auth.locales(identity)) {
    [] | [_] -> ""
    supported ->
      "<h2>"
      <> escape(m.page_language_heading(t))
      <> "</h2><form id=\"locale-form\"><label>"
      <> escape(m.page_language_label(t))
      <> " <select name=\"locale\"><option value=\"\">"
      <> escape(m.page_language_automatic(t))
      <> "</option>"
      <> string.concat(
        list.map(supported, fn(l) {
          let tag = locale.to_string(l)
          "<option value=\""
          <> escape(tag)
          <> "\""
          <> case current == Some(tag) {
            True -> " selected"
            False -> ""
          }
          <> " lang=\""
          <> escape(tag)
          <> "\">"
          <> escape(i18n.language_name(tag) |> result.unwrap(tag))
          <> "</option>"
        }),
      )
      <> "</select></label><button>"
      <> escape(m.page_save_language(t))
      <> "</button></form>"
  }
}

fn account_page(
  identity: Auth,
  t: Translator,
  prefix: String,
  api: String,
  current_locale: Option(String),
) -> String {
  let say = escape
  let raw_prefix = prefix
  let prefix = escape(prefix)
  let api = escape(api)
  let password_form = case
    auth.passwords_enabled(identity) && auth.email_tokens_enabled(identity)
  {
    False -> ""
    True ->
      "<h2>"
      <> say(m.page_set_password_heading(t))
      <> "</h2><p>"
      <> say(m.page_set_password_explain(t))
      <> "</p><form id=\"password-change\"><label>"
      <> say(m.page_new_password_label(t))
      <> " <input name=\"password\" type=\"password\" autocomplete=\"new-password\" required></label><button>"
      <> say(m.page_save_password(t))
      <> "</button></form>"
  }
  let password_form =
    case auth.passwords_enabled(identity) {
      False -> ""
      True ->
        "<h2>"
        <> say(m.page_change_password_heading(t))
        <> "</h2><p>"
        <> say(m.page_change_password_explain(t))
        <> "</p><form id=\"password-current\"><label>"
        <> say(m.page_current_password_label(t))
        <> " <input name=\"current\" type=\"password\" autocomplete=\"current-password\" required></label><label>"
        <> say(m.page_new_password_label(t))
        <> " <input name=\"password\" type=\"password\" autocomplete=\"new-password\" required></label><button>"
        <> say(m.page_change_password_button(t))
        <> "</button></form>"
    }
    <> password_form
  let email_forms = case auth.email_tokens_enabled(identity) {
    False -> ""
    True ->
      "<h2>"
      <> say(m.page_change_email_heading(t))
      <> "</h2><p>"
      <> say(case auth.email_change_approval_enabled(identity) {
        True -> m.page_change_email_explain_approval(t)
        False -> m.page_change_email_explain(t)
      })
      <> "</p><form id=\"email-change\"><label>"
      <> say(m.page_new_email_label(t))
      <> " <input name=\"email\" type=\"email\" required maxlength=\"254\" autocomplete=\"email\"></label><button>"
      <> say(m.page_send_confirmation(t))
      <> "</button></form>"
      <> case auth.email_change_approval_enabled(identity) {
        True ->
          "<form id=\"email-approve\" hidden><label>"
          <> say(m.page_approval_token_label(t))
          <> " <input name=\"token\" required autocomplete=\"one-time-code\"></label><button>"
          <> say(m.page_approve_change(t))
          <> "</button></form>"
        False -> ""
      }
      <> "<form id=\"email-confirm\" hidden><label>"
      <> say(m.page_confirmation_token_label(t))
      <> " <input name=\"token\" required autocomplete=\"one-time-code\"></label><button>"
      <> say(m.page_confirm_new_email(t))
      <> "</button></form>"
  }
  let deletion_form = case auth.account_deletion_enabled(identity) {
    False -> ""
    True ->
      "<h2>"
      <> say(m.page_delete_heading(t))
      <> "</h2><p>"
      <> say(m.page_delete_explain(t))
      <> "</p><form id=\"account-delete\"><label>"
      <> say(m.page_current_email_label(t))
      <> " <input name=\"email\" type=\"email\" required autocomplete=\"email\"></label><button>"
      <> say(m.page_delete_button(t))
      <> "</button></form>"
  }
  let title = m.page_your_account(t)
  document(
    identity,
    t,
    raw_prefix,
    title,
    "<main id=\"account\" data-api=\""
      <> api
      <> "\"><h1>"
      <> say(title)
      <> "</h1>",
  )
  <> "<p><a href=\""
  <> prefix
  <> "/login\">"
  <> say(m.page_sign_in(t))
  <> "</a></p>"
  <> provider_forms(identity, t, raw_prefix, "link", None)
  <> password_form
  <> email_forms
  <> "<h2>"
  <> say(m.page_linked_providers_heading(t))
  <> "</h2><p>"
  <> say(m.page_linked_providers_explain(t))
  <> "</p><ul id=\"linked-providers\"></ul>"
  <> security_settings(identity, t)
  <> language_form(identity, t, current_locale)
  <> deletion_form
  <> case auth.multi_session(identity) {
    Some(_) ->
      "<h2>"
      <> say(m.page_device_accounts_heading(t))
      <> "</h2><ul id=\"device-accounts\"></ul><p><a href=\""
      <> prefix
      <> "/login\">"
      <> say(m.page_add_account(t))
      <> "</a></p><button id=\"logout-all\">"
      <> say(m.page_logout_all(t))
      <> "</button>"
    None -> ""
  }
  <> "<h2>"
  <> say(m.page_sessions_heading(t))
  <> "</h2><ul id=\"sessions\"></ul><button id=\"refresh-sessions\">"
  <> say(m.page_refresh_sessions(t))
  <> "</button><button id=\"logout\">"
  <> say(m.page_logout(t))
  <> "</button><p id=\"status\" role=\"status\" aria-live=\"polite\"></p><noscript>"
  <> say(m.page_noscript_account(t))
  <> "</noscript></main></body></html>"
}

const script = "const requestForm = document.getElementById('request');
const exchangeForm = document.getElementById('exchange');
const account = document.getElementById('account');
const status = document.getElementById('status');
const mfaLogin = document.getElementById('mfa-login');
const api = (requestForm || account || mfaLogin || document.getElementById('passkey-login'))?.dataset.api;
// The page's words, in its language, from the JSON block the server renders.
const words = JSON.parse(document.getElementById('auth-words')?.textContent || '{}');
const lang = document.documentElement?.lang || undefined;
function fill(text, values) {
  for (const [key, value] of Object.entries(values)) text = text.split('{' + key + '}').join(value);
  return text;
}
// What the API said, in the page's words when its code has some.
const said = body => words['message.' + body.code] || body.message;
const when = seconds => new Date(seconds * 1000).toLocaleString(lang);
async function call(endpoint, payload) {
  const response = await fetch(api + '/' + endpoint, {
    method: payload === undefined ? 'GET' : 'POST', credentials: 'same-origin',
    headers: payload === undefined ? {} : {'Content-Type': 'application/json'},
    body: payload === undefined ? undefined : JSON.stringify(payload)
  });
  const body = response.status === 204 ? {} : await response.json();
  if (!response.ok) throw new Error(words['error.' + body.code] || body.error || words.retry);
  return body;
}
async function submit(form, endpoint, payload) {
  const button = form.querySelector('button');
  button.disabled = true;
  try {
    const body = await call(endpoint, payload);
    if (body.mfa_required) { showMfa(); return; }
    const signedIn = endpoint === 'session' || endpoint === 'password/session';
    status.textContent = signedIn ? words.signed_in : said(body);
    if (form.elements.password) form.elements.password.value = '';
    if (signedIn) {
      if (exchangeForm) exchangeForm.reset();
      requestForm.hidden = true;
      if (exchangeForm) exchangeForm.hidden = true;
    } else { exchangeForm?.elements.token.focus(); }
  } catch (error) { status.textContent = error.message; }
  finally { button.disabled = false; }
}
requestForm?.addEventListener('submit', event => {
  event.preventDefault();
  const payload = {email: requestForm.elements.email.value};
  const group = new URLSearchParams(location.search).get('group');
  if (group) payload.group = group;
  if (requestForm.elements.password) payload.password = requestForm.elements.password.value;
  submit(requestForm, requestForm.dataset.action, payload);
});
exchangeForm?.addEventListener('submit', event => {
  event.preventDefault();
  const value = exchangeForm.elements.token.value.trim();
  if (!/^\\d{6}$/.test(value)) return submit(exchangeForm, 'session', {token: value});
  // A code only works with the address it was sent to.
  const email = requestForm?.elements.email.value.trim();
  if (!email) { status.textContent = words.enter_code_email; requestForm?.elements.email.focus(); return; }
  const payload = {email, code: value};
  const group = new URLSearchParams(location.search).get('group');
  if (group) payload.group = group;
  submit(exchangeForm, 'session', payload);
});
// An emailed link carries its token in the fragment, which is never sent to
// a server. Fill it in and wait for a click: a mail scanner that opens the
// link must not spend the token.
const linked = new URLSearchParams(location.hash.slice(1));
if (['token', 'email-approve', 'email-confirm'].some(key => linked.has(key)))
  history.replaceState(null, '', location.pathname + location.search);
function prefill(form, value, message) {
  if (!form || !value) return;
  form.hidden = false; form.elements.token.value = value;
  status.textContent = message; form.querySelector('button').focus();
}
prefill(exchangeForm, linked.get('token'), words.press_continue);
async function refreshSessions() {
  const sessions = await call('sessions');
  const list = document.getElementById('sessions');
  list.replaceChildren();
  for (const session of sessions) {
    const item = document.createElement('li');
    item.textContent = fill(words.session_line, {
      state: session.current ? words.this_session : words.other_session, method: session.method,
      created: when(session.created_at), used: when(session.last_seen_at)}) + ' ';
    const revoke = document.createElement('button');
    revoke.textContent = words.revoke_session;
    revoke.addEventListener('click', async () => {
      revoke.disabled = true;
      try {
        await call('sessions/revoke', {id: session.id});
        item.remove();
        status.textContent = session.current ? words.signed_out : words.session_revoked;
        if (session.current) account.querySelectorAll('button').forEach(b => b.disabled = true);
      } catch (error) { status.textContent = error.message; revoke.disabled = false; }
    });
    item.append(revoke); list.append(item);
  }
}
function signedOut(message) {
  status.textContent = message;
  document.getElementById('sessions').replaceChildren();
  document.getElementById('linked-providers')?.replaceChildren();
  account.querySelectorAll('button').forEach(button => button.disabled = true);
}
async function refreshProviders() {
  const list = document.getElementById('linked-providers');
  if (!list) return;
  const links = await call('providers');
  list.replaceChildren();
  for (const link of links) {
    const item = document.createElement('li');
    item.textContent = link.provider + ' ';
    const button = document.createElement('button');
    button.textContent = words.unlink;
    button.addEventListener('click', async () => {
      button.disabled = true;
      try {
        await call('providers/unlink', {issuer: link.issuer});
        signedOut(words.provider_unlinked);
      } catch (error) { status.textContent = error.message; button.disabled = false; }
    });
    item.append(button); list.append(item);
  }
}
function accountForm(id, endpoint, field, message) {
  document.getElementById(id)?.addEventListener('submit', async event => {
    event.preventDefault();
    const form = event.currentTarget;
    const button = form.querySelector('button');
    button.disabled = true;
    let completed = false;
    try {
      const result = await call(endpoint, {[field]: form.elements[field].value.trim()});
      form.reset();
      if (id === 'email-change' || id === 'email-approve') {
        status.textContent = said(result);
        const approval = id === 'email-change' && document.getElementById('email-approve');
        const next = approval || document.getElementById('email-confirm');
        if (id === 'email-approve') form.hidden = true;
        next.hidden = false; next.elements.token.focus();
      } else {
        completed = true; signedOut(message);
      }
    } catch (error) { status.textContent = error.message; }
    finally { if (!completed) button.disabled = false; }
  });
}
if (account) {
  refreshProviders().catch(error => status.textContent = error.message);
  accountForm('email-change', 'email/change', 'email', '');
  accountForm('email-approve', 'email/approve', 'token', '');
  accountForm('email-confirm', 'email/confirm', 'token', words.email_changed);
  prefill(document.getElementById('email-approve'), linked.get('email-approve'), words.press_approve);
  prefill(document.getElementById('email-confirm'), linked.get('email-confirm'), words.press_confirm);
  accountForm('account-delete', 'account/delete', 'email', words.account_deleted);
  refreshSessions().catch(error => status.textContent = error.message);
  document.getElementById('refresh-sessions').addEventListener('click', () =>
    refreshSessions().catch(error => status.textContent = error.message));
  const passwordForm = (id, endpoint, fields) =>
    document.getElementById(id)?.addEventListener('submit', async event => {
      event.preventDefault();
      const form = event.currentTarget;
      const button = form.querySelector('button'); button.disabled = true;
      try {
        await call(endpoint, Object.fromEntries(fields.map(name => [name, form.elements[name].value])));
        form.reset(); status.textContent = words.password_saved;
        await refreshSessions();
      } catch (error) { status.textContent = error.message; }
      finally { button.disabled = false; }
    });
  passwordForm('password-change', 'password', ['password']);
  passwordForm('password-current', 'password/change', ['current', 'password']);
  // With several accounts in this browser, signing one out lands in another,
  // so the page reloads as that account instead of going quiet.
  const deviceAccounts = document.getElementById('device-accounts');
  const leave = async all => {
    try {
      await call('logout', all ? {all: true} : {});
      if (!all && deviceAccounts && deviceAccounts.children.length > 1) { location.reload(); return; }
      status.textContent = words.signed_out;
      document.getElementById('sessions').replaceChildren();
      deviceAccounts?.replaceChildren();
      account.querySelectorAll('button').forEach(b => b.disabled = true);
    } catch (error) { status.textContent = error.message; }
  };
  document.getElementById('logout').addEventListener('click', () => leave(false));
  document.getElementById('logout-all')?.addEventListener('click', () => leave(true));
  if (deviceAccounts) call('sessions/accounts').then(entries => {
    deviceAccounts.replaceChildren();
    for (const entry of entries) {
      const item = document.createElement('li');
      item.textContent = (entry.current ? fill(words.current_account, {email: entry.user.email}) : entry.user.email) + ' ';
      if (!entry.current) {
        const button = document.createElement('button'); button.textContent = words.switch;
        button.addEventListener('click', async () => {
          button.disabled = true;
          try { await call('sessions/switch', {id: entry.id}); location.reload(); }
          catch (error) { status.textContent = error.message; button.disabled = false; }
        });
        item.append(button);
      }
      deviceAccounts.append(item);
    }
  }).catch(error => status.textContent = error.message);
}
function showMfa() {
  if (mfaLogin) mfaLogin.hidden = false;
  if (requestForm) requestForm.hidden = true;
  if (exchangeForm) exchangeForm.hidden = true;
  status.textContent = words.verify_mfa;
}
function loginResult(body) {
  if (body.mfa_required) { showMfa(); return; }
  if (mfaLogin) mfaLogin.hidden = true;
  status.textContent = words.signed_in;
}
document.getElementById('mfa-verify')?.addEventListener('submit', async event => {
  event.preventDefault(); const form = event.currentTarget; const button = form.querySelector('button'); button.disabled = true;
  try {
    const body = await call('mfa/verify', {method: form.elements.method.value, code: form.elements.code.value.trim(), remember: form.elements.remember.checked});
    form.reset(); loginResult(body);
  } catch (error) { status.textContent = error.message; } finally { button.disabled = false; }
});
document.getElementById('mfa-send')?.addEventListener('click', async event => {
  const button = event.currentTarget; button.disabled = true;
  try { await call('mfa/send', {}); status.textContent = words.code_sent; }
  catch (error) { status.textContent = error.message; } finally { button.disabled = false; }
});
function fromBase64(value) {
  const text = value.replaceAll('-', '+').replaceAll('_', '/');
  return Uint8Array.from(atob(text.padEnd(Math.ceil(text.length / 4) * 4, '=')), c => c.charCodeAt(0));
}
function toBase64(value) {
  return btoa(String.fromCharCode(...new Uint8Array(value))).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}
function credentialOptions(options, register) {
  const parsed = {...options, challenge: fromBase64(options.challenge)};
  if (register) parsed.user = {...options.user, id: fromBase64(options.user.id)};
  for (const field of ['excludeCredentials', 'allowCredentials']) if (options[field]) parsed[field] = options[field].map(c => ({...c, id: fromBase64(c.id)}));
  return parsed;
}
function credentialJSON(credential) {
  const response = credential.response;
  const encoded = {clientDataJSON: toBase64(response.clientDataJSON)};
  if (response.attestationObject) {
    encoded.attestationObject = toBase64(response.attestationObject);
    encoded.transports = response.getTransports?.() || [];
  } else {
    encoded.authenticatorData = toBase64(response.authenticatorData);
    encoded.signature = toBase64(response.signature);
    encoded.userHandle = response.userHandle ? toBase64(response.userHandle) : null;
  }
  return JSON.stringify({id: credential.id, rawId: toBase64(credential.rawId), type: credential.type, response: encoded, clientExtensionResults: credential.getClientExtensionResults?.() || {}});
}
// One WebAuthn request may be pending at a time. The autofill request waits for
// as long as the page is open, so the button cancels it before starting its own.
let autofill = null;
async function passkeyLogin(conditional) {
  autofill?.abort(); autofill = conditional ? new AbortController() : null;
  const group = new URLSearchParams(location.search).get('group');
  const challenge = await call('passkeys/login', group ? {group} : {});
  const request = {publicKey: credentialOptions(challenge.options, false)};
  if (conditional) { request.mediation = 'conditional'; request.signal = autofill.signal; }
  const credential = await navigator.credentials.get(request);
  if (!credential) throw Error(words.passkey_cancelled);
  loginResult(await call('passkeys/session', {challenge: challenge.challenge, credential: credentialJSON(credential)}));
}
// Offer passkeys in the email field's autofill where the browser can. A
// challenge lasts five minutes, so an idle page asks for a fresh one before then.
async function passkeyAutofill() {
  if (!document.getElementById('passkey-login') || !requestForm) return;
  if (!(await globalThis.PublicKeyCredential?.isConditionalMediationAvailable?.())) return;
  const arm = () => passkeyLogin(true).catch(error => {
    if (error.name !== 'AbortError') status.textContent = error.message;
  });
  arm(); setInterval(arm, 240000);
}
passkeyAutofill().catch(() => {});
document.getElementById('passkey-login')?.addEventListener('click', async event => {
  const button = event.currentTarget; button.disabled = true;
  try {
    if (!navigator.credentials) throw Error(words.no_passkeys);
    await passkeyLogin(false);
  } catch (error) { status.textContent = error.message; } finally { button.disabled = false; }
});
document.getElementById('passkey-signup')?.addEventListener('submit', async event => {
  event.preventDefault(); const form = event.currentTarget; const button = form.querySelector('button'); button.disabled = true;
  try {
    if (!navigator.credentials) throw Error(words.no_passkeys);
    const payload = {email: form.elements.email.value, name: form.elements.name.value};
    const group = new URLSearchParams(location.search).get('group');
    if (group) payload.group = group;
    const challenge = await call('passkeys/signup', payload);
    const credential = await navigator.credentials.create({publicKey: credentialOptions(challenge.options, true)});
    if (!credential) throw Error(words.passkey_registration_cancelled);
    const result = await call('passkeys/signup/confirm', {challenge: challenge.challenge, credential: credentialJSON(credential)});
    form.reset(); status.textContent = said(result); exchangeForm?.elements.token.focus();
  } catch (error) { status.textContent = error.message; } finally { button.disabled = false; }
});
async function refreshPasskeys() {
  const list = document.getElementById('passkeys'); if (!list) return;
  const keys = await call('passkeys'); list.replaceChildren();
  for (const key of keys) {
    const item = document.createElement('li'); item.textContent = (key.backed_up ? fill(words.backed_up, {name: key.name}) : key.name) + ' ';
    const name = document.createElement('input'); name.value = key.name; name.maxLength = 100; name.setAttribute('aria-label', words.passkey_name);
    const rename = document.createElement('button'); rename.textContent = words.rename;
    rename.addEventListener('click', async () => {
      rename.disabled = true;
      try { await call('passkeys/rename', {id: key.id, name: name.value}); await refreshPasskeys(); }
      catch (error) { status.textContent = error.message; rename.disabled = false; }
    });
    const remove = document.createElement('button'); remove.textContent = words.remove;
    remove.addEventListener('click', async () => {
      remove.disabled = true;
      try { await call('passkeys/delete', {id: key.id}); signedOut(words.passkey_removed); }
      catch (error) { status.textContent = error.message; remove.disabled = false; }
    });
    item.append(name); item.append(rename); item.append(remove); list.append(item);
  }
}
document.getElementById('passkey-add')?.addEventListener('submit', async event => {
  event.preventDefault(); const form = event.currentTarget; const button = form.querySelector('button'); button.disabled = true;
  try {
    if (!navigator.credentials) throw Error(words.no_passkeys);
    const challenge = await call('passkeys/register', {name: form.elements.name.value});
    const credential = await navigator.credentials.create({publicKey: credentialOptions(challenge.options, true)});
    if (!credential) throw Error(words.passkey_registration_cancelled);
    await call('passkeys/register/confirm', {challenge: challenge.challenge, credential: credentialJSON(credential)});
    form.reset(); await refreshPasskeys(); status.textContent = words.passkey_added;
  } catch (error) { status.textContent = error.message; } finally { button.disabled = false; }
});
let mfaEnrollment = null;
document.getElementById('mfa-enroll')?.addEventListener('submit', async event => {
  event.preventDefault(); const form = event.currentTarget; const button = form.querySelector('button'); button.disabled = true;
  try {
    const setup = await call('mfa/enroll', {method: form.elements.method.value});
    mfaEnrollment = setup.challenge;
    showQr(setup.qr_code);
    document.getElementById('mfa-setup-key').textContent = setup.key ? fill(setup.qr_code ? words.scan_key : words.enter_key, {key: setup.key}) : words.check_contact;
    document.getElementById('mfa-enroll-confirm').hidden = false;
    status.textContent = words.confirm_to_enable;
  } catch (error) { status.textContent = error.message; } finally { button.disabled = false; }
});
// The SVG is generated by the server from the enrollment URI, never from input.
function showQr(svg) {
  const holder = document.getElementById('mfa-setup-qr');
  if (!holder) return;
  holder.innerHTML = svg || '';
  const image = holder.querySelector('svg');
  if (image) { image.setAttribute('width', '200'); image.setAttribute('role', 'img'); image.setAttribute('aria-label', words.qr_label); }
}
function showRecovery(result, message) {
  document.getElementById('recovery-codes').textContent = result.recovery_codes.join('\\n');
  document.getElementById('mfa-setup-key').textContent = ''; showQr('');
  signedOut(message);
}
document.getElementById('mfa-enroll-confirm')?.addEventListener('submit', async event => {
  event.preventDefault(); const form = event.currentTarget; const button = form.querySelector('button'); button.disabled = true;
  try {
    const result = await call('mfa/enroll/confirm', {challenge: mfaEnrollment, code: form.elements.code.value.trim()});
    form.reset(); form.hidden = true; mfaEnrollment = null; showRecovery(result, words.mfa_enabled);
  } catch (error) {
    mfaEnrollment = null; form.hidden = true; document.getElementById('mfa-setup-key').textContent = ''; showQr('');
    status.textContent = fill(words.enrollment_retry, {error: error.message}); button.disabled = false;
  }
});
document.getElementById('mfa-recovery')?.addEventListener('click', async event => {
  const button = event.currentTarget; button.disabled = true;
  try { showRecovery(await call('mfa/recovery', {}), words.recovery_replaced); }
  catch (error) { status.textContent = error.message; button.disabled = false; }
});
document.getElementById('mfa-disable')?.addEventListener('click', async event => {
  const button = event.currentTarget; button.disabled = true;
  try { await call('mfa/disable', {}); signedOut(words.mfa_disabled); }
  catch (error) { status.textContent = error.message; button.disabled = false; }
});
async function refreshDevices() {
  const list = document.getElementById('trusted-devices'); if (!list) return;
  const devices = await call('mfa/devices'); list.replaceChildren();
  for (const device of devices) {
    const item = document.createElement('li'); item.textContent = fill(words.remembered, {date: when(device.created_at)}) + ' ';
    const button = document.createElement('button'); button.textContent = words.forget_device;
    button.addEventListener('click', async () => {
      button.disabled = true;
      try { await call('mfa/devices/revoke', {id: device.id}); await refreshDevices(); status.textContent = words.device_forgotten; }
      catch (error) { status.textContent = error.message; button.disabled = false; }
    });
    item.append(button); list.append(item);
  }
}
if (account) {
  refreshPasskeys().catch(error => status.textContent = error.message);
  refreshDevices().catch(error => status.textContent = error.message);
  if (document.getElementById('mfa-state')) call('security').then(state => {
    document.getElementById('mfa-state').textContent = state.mfa ? fill(words.mfa_on, {method: state.mfa}) : words.mfa_off;
    document.getElementById('mfa-enroll').hidden = !!state.mfa;
    document.getElementById('mfa-disable').hidden = !state.mfa;
    document.getElementById('mfa-recovery').hidden = !state.mfa;
  }).catch(error => status.textContent = error.message);
}
// A new language takes effect on the next page, so reload into it.
document.getElementById('locale-form')?.addEventListener('submit', async event => {
  event.preventDefault(); const form = event.currentTarget; const button = form.querySelector('button'); button.disabled = true;
  try { await call('locale', {locale: form.elements.locale.value || null}); location.reload(); }
  catch (error) { status.textContent = error.message; button.disabled = false; }
});
"
