//// A sign-in screen: email, password, "keep me signed in", and a link to
//// create an account.
////
//// ```gleam
//// sign_in.screen(sign_in.sign_in(
////   action: "/sign-in",
////   email: submitted_email,
////   error: Some("That email and password do not match."),
////   sign_up: "/sign-up",
////   forgot: "/forgot-password",
//// ))
//// ```
////
//// The form posts `email`, `password` and, when ticked, `remember` to
//// `action`. Pass back what was typed, and a message when signing in fails.

import gleam/option.{type Option, None, Some}
import howdy/ui/alert
import howdy/ui/button
import howdy/ui/card
import howdy/ui/checkbox
import howdy/ui/field
import howdy/ui/input
import howdy/ui/style.{class}
import howdy/ui/typography
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

/// The whole screen, with `card` in the middle.
pub fn screen(card: Element(msg)) -> Element(msg) {
  html.main([class(screen_class())], [card])
}

pub fn sign_in(
  action action: String,
  email email: String,
  error error: Option(String),
  sign_up sign_up: String,
  forgot forgot: String,
) -> Element(msg) {
  card.card([class(card_class())], [
    card.header([], [
      card.title([html.h1([class(title_class())], [text("Sign in")])]),
      card.description([text("Welcome back. Enter your email to continue.")]),
    ]),
    case error {
      Some(message) ->
        alert.alert(alert.Danger, [attribute.role("alert")], [
          alert.description([text(message)]),
        ])
      None -> element.none()
    },
    html.form(
      [class(form_class()), attribute.method("post"), attribute.action(action)],
      [
        field.field([], [
          input.label([attribute.for("email")], [text("Email")]),
          input.input([
            attribute.id("email"),
            attribute.type_("email"),
            attribute.name("email"),
            attribute.value(email),
            attribute.autocomplete("email"),
            attribute.required(True),
          ]),
        ]),
        field.field([], [
          html.div([class(split_class())], [
            input.label([attribute.for("password")], [text("Password")]),
            typography.link(forgot, [text("Forgot password?")]),
          ]),
          input.input([
            attribute.id("password"),
            attribute.type_("password"),
            attribute.name("password"),
            attribute.autocomplete("current-password"),
            attribute.required(True),
          ]),
        ]),
        field.field([], [
          checkbox.choice(checkbox.checkbox([attribute.name("remember")]), [
            text("Keep me signed in"),
          ]),
        ]),
        button.submit(button.Primary, [class(wide_class())], [text("Sign in")]),
      ],
    ),
    card.footer([], [
      typography.muted("No account yet?"),
      typography.link(sign_up, [text("Create one")]),
    ]),
  ])
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    screen_class(),
    card_class(),
    title_class(),
    form_class(),
    split_class(),
    wide_class(),
  ]
}

pub fn screen_class() -> Class {
  css.class([
    css.display("grid"),
    css.property("place-items", "center"),
    css.property("min-height", "100vh"),
    css.padding(rem(1.5)),
  ])
}

pub fn card_class() -> Class {
  css.class([css.width(percent(100)), css.property("max-width", "26rem")])
}

pub fn title_class() -> Class {
  css.class([css.margin(rem(0.0)), css.font_size_("inherit")])
}

pub fn form_class() -> Class {
  css.class([css.margin_("1rem 0 0")])
}

pub fn split_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("baseline"),
    css.justify_content("space-between"),
    css.gap(rem(1.0)),
  ])
}

pub fn wide_class() -> Class {
  css.class([
    css.width(percent(100)),
    css.justify_content("center"),
  ])
}
