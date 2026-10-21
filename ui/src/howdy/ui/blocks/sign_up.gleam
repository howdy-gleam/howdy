//// A sign-up screen: name, email, password, a plan and the terms, with
//// each problem shown beside its field.
////
//// ```gleam
//// sign_up.screen(sign_up.sign_up(
////   action: "/sign-up",
////   form: sign_up.Form(..sign_up.empty(), email: typed_email),
////   errors: [#("email", "Enter an email address.")],
////   sign_in: "/sign-in",
//// ))
//// ```
////
//// The form posts `name`, `email`, `password`, `plan` and, when ticked,
//// `terms` to `action`. Check them on the server, and render the form again
//// with what was typed and a message for each field that needs another
//// look. Each message is tied to its field, so a screen reader reads it
//// with the label.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import howdy/ui/alert
import howdy/ui/button
import howdy/ui/card
import howdy/ui/checkbox
import howdy/ui/field
import howdy/ui/input
import howdy/ui/select
import howdy/ui/style.{class}
import howdy/ui/typography
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

/// What was typed. The password is never sent back.
pub type Form {
  Form(name: String, email: String, plan: String, terms: Bool)
}

pub fn empty() -> Form {
  Form(name: "", email: "", plan: "", terms: False)
}

/// The whole screen, with `card` in the middle.
pub fn screen(card: Element(msg)) -> Element(msg) {
  html.main([class(screen_class())], [card])
}

/// `errors` pairs a field name with its message.
pub fn sign_up(
  action action: String,
  form form: Form,
  errors errors: List(#(String, String)),
  sign_in sign_in: String,
) -> Element(msg) {
  let error = fn(name) { list.key_find(errors, name) |> option.from_result }
  card.card([class(card_class())], [
    card.header([], [
      card.title([html.h1([class(title_class())], [text("Create an account")])]),
      card.description([text("It takes a minute. No card needed.")]),
    ]),
    case errors {
      [] -> element.none()
      _ ->
        alert.alert(alert.Danger, [attribute.role("alert")], [
          alert.title([text("Check the highlighted fields")]),
          alert.description([
            text("Some of what you entered needs another look."),
          ]),
        ])
    },
    html.form(
      [
        class(form_class()),
        attribute.method("post"),
        attribute.action(action),
        attribute.novalidate(True),
      ],
      [
        text_field(
          "name",
          "Name",
          form.name,
          "name",
          "text",
          error("name"),
          None,
        ),
        text_field(
          "email",
          "Email",
          form.email,
          "email",
          "email",
          error("email"),
          Some("We send a link to confirm it."),
        ),
        text_field(
          "password",
          "Password",
          "",
          "new-password",
          "password",
          error("password"),
          Some("At least 8 characters."),
        ),
        field.field([], [
          input.label([attribute.for("plan")], [text("Plan")]),
          select.select(
            id: "plan",
            name: "plan",
            value: form.plan,
            placeholder: "Choose a plan",
            attributes: [],
            items: [
              select.item("free", "Free"),
              select.item("team", "Team"),
              select.item("business", "Business"),
            ],
          ),
          message("plan", error("plan")),
        ]),
        field.field([], [
          checkbox.choice(
            checkbox.checkbox([
              attribute.name("terms"),
              attribute.checked(form.terms),
              ..invalid("terms", error("terms"), [])
            ]),
            [text("I accept the terms")],
          ),
          message("terms", error("terms")),
        ]),
        button.submit(button.Primary, [class(wide_class())], [
          text("Create account"),
        ]),
      ],
    ),
    card.footer([], [
      typography.muted("Already have an account?"),
      typography.link(sign_in, [text("Sign in")]),
    ]),
  ])
}

fn text_field(
  name: String,
  label: String,
  value: String,
  autocomplete: String,
  kind: String,
  error: Option(String),
  hint: Option(String),
) -> Element(msg) {
  let described = case hint {
    Some(_) -> [name <> "-hint"]
    None -> []
  }
  field.field([], [
    input.label([attribute.for(name)], [text(label)]),
    input.input([
      attribute.id(name),
      attribute.name(name),
      attribute.type_(kind),
      attribute.value(value),
      attribute.autocomplete(autocomplete),
      ..invalid(name, error, described)
    ]),
    case hint {
      Some(hint) ->
        field.description([attribute.id(name <> "-hint")], [text(hint)])
      None -> element.none()
    },
    message(name, error),
  ])
}

/// `aria-invalid` and `aria-describedby` for a field, tying it to its hint
/// and its error.
fn invalid(
  name: String,
  error: Option(String),
  described: List(String),
) -> List(Attribute(msg)) {
  let #(flag, described) = case error {
    Some(_) -> #(
      [attribute.aria_invalid("true")],
      list.append(described, [name <> "-error"]),
    )
    None -> #([], described)
  }
  case described {
    [] -> flag
    ids -> [attribute.aria_describedby(string.join(ids, " ")), ..flag]
  }
}

fn message(name: String, error: Option(String)) -> Element(msg) {
  case error {
    Some(message) ->
      field.error([attribute.id(name <> "-error")], [text(message)])
    None -> element.none()
  }
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [screen_class(), card_class(), title_class(), form_class(), wide_class()]
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

pub fn wide_class() -> Class {
  css.class([css.width(percent(100)), css.justify_content("center")])
}
