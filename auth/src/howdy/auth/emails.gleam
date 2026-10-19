//// Ready-made emails for auth, sent with `howdy/mail`: one template for each
//// `auth.Purpose`, and one for MFA codes. Replace any of them with your own.
////
//// ```gleam
//// import howdy/auth
//// import howdy/auth/emails
//// import howdy/auth/mfa
////
//// let auth_emails = emails.new(mailer, app_name: "Acme")
//// let assert Ok(identity) =
////   auth.new(repo:, origin:, deliver: emails.deliver(auth_emails))
//// let mfa_config = mfa.with_delivery(config, emails.deliver_mfa(auth_emails))
//// ```
////
//// Each message goes to the delivery's address and is tagged
//// `auth.<purpose>`, such as `auth.sign_in`, so it is easy to find in the
//// admin outbox. `previews` gives the admin a preview of every template.
////
//// A token, link or code is only revealed into the message body. A failed
//// send is logged without it, and the auth flow reports the failure.
////
//// The default templates are written in the delivery's `locale` (see
//// `auth.with_locales`), in English when there is none or no translation.
//// Their words live in `auth/locales/emails/*.json`; after editing them,
//// regenerate `howdy/auth/internal/emails_messages` with
//// `cd i18n && gleam run -m howdy/i18n/cli -- gen --locales=../auth/locales/emails --out=../auth/src/howdy/auth/internal/emails_messages.gleam`.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import howdy/auth.{type Delivery, type Purpose, Delivery}
import howdy/auth/internal/emails_messages as words
import howdy/auth/secret.{type Secret}
import howdy/auth/user.{type User}
import howdy/i18n.{type Translator}
import howdy/locale
import howdy/mail.{type Mailer, type Message}
import howdy/mail/preview.{type Preview}
import logging
import smail/attribute
import smail/email
import smail/html
import smail/style

pub opaque type Emails {
  Emails(
    mailer: Mailer,
    app_name: String,
    templates: List(#(Purpose, fn(Delivery) -> Message)),
    mfa: Option(fn(String, Secret, Option(String)) -> Message),
  )
}

/// The default templates, naming the app `app_name`, sent with `mailer`.
pub fn new(mailer: Mailer, app_name app_name: String) -> Emails {
  Emails(mailer:, app_name:, templates: [], mfa: None)
}

/// Build the email for one purpose yourself. Set the subject and body;
/// the recipient and the `auth.<purpose>` tag are added for you.
pub fn with_template(
  emails: Emails,
  for purpose: Purpose,
  build build: fn(Delivery) -> Message,
) -> Emails {
  Emails(..emails, templates: [
    #(purpose, build),
    ..list.filter(emails.templates, fn(entry) { entry.0 != purpose })
  ])
}

/// Build the MFA code email yourself, from the address, the code and the
/// recipient's locale, if they have one.
pub fn with_mfa_template(
  emails: Emails,
  build: fn(String, Secret, Option(String)) -> Message,
) -> Emails {
  Emails(..emails, mfa: Some(build))
}

/// The function `auth.new` and `auth.with_email_tokens` take.
pub fn deliver(emails: Emails) -> fn(Delivery) -> Result(Nil, Nil) {
  fn(delivery: Delivery) {
    send(
      emails,
      message(emails, delivery),
      "auth." <> purpose_name(delivery.purpose),
    )
  }
}

/// The function `mfa.with_delivery` takes.
pub fn deliver_mfa(emails: Emails) -> fn(User, Secret) -> Result(Nil, Nil) {
  fn(user: User, code: Secret) {
    send(
      emails,
      mfa_message(emails, user.email, code, user.locale),
      "auth.mfa for user " <> user.id,
    )
  }
}

/// `about` names the message by purpose (and user id when there is one),
/// never by address: a recipient's email must not end up in the log.
fn send(emails: Emails, message: Message, about: String) -> Result(Nil, Nil) {
  case mail.send(emails.mailer, message) {
    Ok(_) -> Ok(Nil)
    Error(error) -> {
      logging.log(
        logging.Error,
        "howdy/auth/emails: "
          <> about
          <> " not sent: "
          <> mail.error_to_string(error),
      )
      Error(Nil)
    }
  }
}

/// The message for a delivery: yours if `with_template` gave one for its
/// purpose, otherwise the default.
pub fn message(emails: Emails, delivery: Delivery) -> Message {
  let build = case list.key_find(emails.templates, delivery.purpose) {
    Ok(build) -> build
    Error(Nil) -> default(emails.app_name, _)
  }
  build(delivery)
  |> mail.to([mail.address(delivery.email)])
  |> mail.tag("auth." <> purpose_name(delivery.purpose))
}

/// The MFA code message, in `locale` if it is given.
pub fn mfa_message(
  emails: Emails,
  email: String,
  code: Secret,
  locale: Option(String),
) -> Message {
  case emails.mfa {
    Some(build) -> build(email, code, locale)
    None -> default_mfa(emails.app_name, code, locale)
  }
  |> mail.to([mail.address(email)])
  |> mail.tag("auth.mfa_code")
}

/// `sign_in`, `registration` and so on.
pub fn purpose_name(purpose: Purpose) -> String {
  case purpose {
    auth.SignIn -> "sign_in"
    auth.Registration -> "registration"
    auth.AlreadyRegistered -> "already_registered"
    auth.EmailChange -> "email_change"
    auth.EmailChangeApproval -> "email_change_approval"
    auth.EmailChanged -> "email_changed"
    auth.PasswordChanged -> "password_changed"
  }
}

const purposes = [
  auth.SignIn,
  auth.Registration,
  auth.AlreadyRegistered,
  auth.EmailChange,
  auth.EmailChangeApproval,
  auth.EmailChanged,
  auth.PasswordChanged,
]

/// A preview of every template, grouped under "Auth", with made-up tokens,
/// links and codes sent to `someone@example.com`.
pub fn previews(emails: Emails) -> List(Preview) {
  previews_for(emails, None, "Auth")
}

/// Previews of every template in each of `locales`, such as `["de", "ja"]`,
/// grouped under "Auth (de)" and so on, to check translations in the admin.
pub fn previews_in(emails: Emails, locales: List(String)) -> List(Preview) {
  list.flat_map(locales, fn(tag) {
    previews_for(emails, Some(tag), "Auth (" <> tag <> ")")
  })
}

fn previews_for(
  emails: Emails,
  locale: Option(String),
  group: String,
) -> List(Preview) {
  let sample = fn(purpose) {
    let notice = purpose == auth.EmailChanged || purpose == auth.PasswordChanged
    let signs_in =
      purpose == auth.SignIn
      || purpose == auth.Registration
      || purpose == auth.AlreadyRegistered
    Delivery(
      email: "someone@example.com",
      token: secret.wrap(case notice {
        True -> ""
        False -> "preview-token-0123456789abcdefghijklmnopqrstuv"
      }),
      purpose:,
      link: case notice {
        True -> None
        False ->
          Some(secret.wrap(
            "https://example.com/auth/login#token=preview-token-0123456789abcdefghijklmnopqrstuv",
          ))
      },
      code: case signs_in {
        True -> Some(secret.wrap("123456"))
        False -> None
      },
      locale:,
    )
  }
  list.append(
    list.map(purposes, fn(purpose) {
      preview.new(title(purpose), fn() { message(emails, sample(purpose)) })
      |> preview.in_group(group)
    }),
    [
      preview.new("MFA code", fn() {
        mfa_message(
          emails,
          "someone@example.com",
          secret.wrap("482913"),
          locale,
        )
      })
      |> preview.in_group(group),
    ],
  )
}

fn title(purpose: Purpose) -> String {
  case purpose {
    auth.SignIn -> "Sign in"
    auth.Registration -> "Registration"
    auth.AlreadyRegistered -> "Already registered"
    auth.EmailChange -> "Email change"
    auth.EmailChangeApproval -> "Email change approval"
    auth.EmailChanged -> "Email changed"
    auth.PasswordChanged -> "Password changed"
  }
}

// -- The default templates -----------------------------------------------------

/// The default message for a delivery, without its recipient, in the
/// delivery's locale.
pub fn default(app_name: String, delivery: Delivery) -> Message {
  let t = translator(delivery.locale)
  let link = option.map(delivery.link, secret.reveal)
  let code = option.map(delivery.code, secret.reveal)
  let token = secret.reveal(delivery.token)
  let app = app_name
  let #(subject, heading, paragraphs, action, closing) = case delivery.purpose {
    auth.SignIn -> #(
      words.sign_in_subject(t, app:),
      words.sign_in_heading(t, app:),
      [words.sign_in_body(t)],
      words.sign_in_action(t),
      words.sign_in_closing(t),
    )
    auth.Registration -> #(
      words.registration_subject(t, app:),
      words.registration_heading(t, app:),
      [words.registration_body(t)],
      words.registration_action(t),
      words.registration_closing(t),
    )
    auth.AlreadyRegistered -> #(
      words.already_registered_subject(t, app:),
      words.already_registered_heading(t),
      [words.already_registered_body(t)],
      words.already_registered_action(t),
      words.already_registered_closing(t),
    )
    auth.EmailChange -> #(
      words.email_change_subject(t),
      words.email_change_heading(t),
      [words.email_change_body(t, app:)],
      words.email_change_action(t),
      words.email_change_closing(t),
    )
    auth.EmailChangeApproval -> #(
      words.email_change_approval_subject(t, app:),
      words.email_change_approval_heading(t),
      [words.email_change_approval_body(t)],
      words.email_change_approval_action(t),
      words.email_change_approval_closing(t),
    )
    auth.EmailChanged -> #(
      words.email_changed_subject(t, app:),
      words.email_changed_heading(t),
      [words.email_changed_body(t)],
      "",
      words.email_changed_closing(t),
    )
    auth.PasswordChanged -> #(
      words.password_changed_subject(t, app:),
      words.password_changed_heading(t),
      [words.password_changed_body(t)],
      "",
      words.password_changed_closing(t),
    )
  }
  let credential = case delivery.purpose {
    auth.EmailChanged | auth.PasswordChanged -> []
    _ ->
      list.flatten([
        case link {
          Some(link) -> [
            email.section([style.margin("24px 0")], [
              email.button(
                [
                  attribute.href(link),
                  style.background_color("#18181b"),
                  style.color("#ffffff"),
                  style.border_radius("6px"),
                  style.padding("12px 20px"),
                  style.font_weight("600"),
                ],
                [html.text(action)],
              ),
            ]),
          ]
          None -> []
        },
        case code {
          Some(code) -> [
            paragraph(words.code_prompt(t)),
            email.paragraph(
              [
                style.font_size("28px"),
                style.font_weight("700"),
                style.letter_spacing("6px"),
                style.margin("8px 0 24px"),
              ],
              [html.text(code)],
            ),
          ]
          None -> []
        },
        case link, code {
          None, None -> [
            paragraph(words.token_prompt(t)),
            monospace(token),
          ]
          _, _ -> []
        },
      ])
  }
  // smail can render plain text too, but runs a paragraph into the URL
  // of a button before it, which would break the link for text readers.
  let plain =
    list.flatten([
      [heading],
      paragraphs,
      case delivery.purpose {
        auth.EmailChanged | auth.PasswordChanged -> []
        _ ->
          list.flatten([
            case link {
              Some(link) -> [action <> ":\n" <> link]
              None -> []
            },
            case code {
              Some(code) -> [words.code_prompt(t) <> " " <> code]
              None -> []
            },
            case link, code {
              None, None -> [words.token_prompt(t) <> "\n" <> token]
              _, _ -> []
            },
          ])
      },
      [closing, "-- \n" <> app_name],
    ])
    |> string.join("\n\n")
  mail.message()
  |> mail.subject(subject)
  |> mail.template(page(
    t,
    app_name,
    preview: heading,
    content: list.flatten([
      [
        email.h1([style.font_size("24px"), style.line_height("32px")], [
          html.text(heading),
        ]),
      ],
      list.map(paragraphs, paragraph),
      credential,
      [small(closing)],
    ]),
  ))
  |> mail.text(plain)
}

/// The default MFA code message, without its recipient, in `locale` if it
/// is given.
pub fn default_mfa(
  app_name: String,
  code: Secret,
  locale: Option(String),
) -> Message {
  let t = translator(locale)
  let heading = words.mfa_heading(t)
  mail.message()
  |> mail.subject(words.mfa_subject(t, app: app_name))
  |> mail.template(
    page(t, app_name, preview: heading, content: [
      email.h1([style.font_size("24px"), style.line_height("32px")], [
        html.text(heading),
      ]),
      paragraph(words.mfa_body(t)),
      email.paragraph(
        [
          style.font_size("28px"),
          style.font_weight("700"),
          style.letter_spacing("6px"),
          style.margin("8px 0 24px"),
        ],
        [html.text(secret.reveal(code))],
      ),
      small(words.mfa_closing(t)),
    ]),
  )
  |> mail.text(
    heading
    <> "\n\n"
    <> words.mfa_body(t)
    <> " "
    <> secret.reveal(code)
    <> "\n\n"
    <> words.mfa_closing(t)
    <> "\n\n-- \n"
    <> app_name,
  )
}

/// A translator for a recipient's locale, English when there is none.
fn translator(locale: Option(String)) -> Translator {
  i18n.new(option.unwrap(locale, "en"))
}

fn page(
  t: Translator,
  app_name: String,
  preview preview: String,
  content content: List(html.Element),
) -> html.Element {
  let tag = i18n.locale(t)
  let direction = case locale.parse(tag) {
    Ok(parsed) ->
      case locale.right_to_left(parsed) {
        True -> "rtl"
        False -> "ltr"
      }
    Error(Nil) -> "ltr"
  }
  email.html([attribute.lang(tag), attribute.dir(direction)], [
    email.head([], []),
    email.body(
      [
        style.background_color("#f4f4f5"),
        style.font_family(
          "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif",
        ),
        style.color("#18181b"),
      ],
      [
        email.preview(preview),
        email.container(
          [
            style.max_width("480px"),
            style.margin("40px auto"),
            style.padding("32px"),
            style.background_color("#ffffff"),
            style.border_radius("8px"),
          ],
          list.append(content, [
            email.hr([style.margin("32px 0 16px")]),
            small(app_name),
          ]),
        ),
      ],
    ),
  ])
}

fn paragraph(text: String) -> html.Element {
  email.paragraph([style.font_size("16px"), style.line_height("24px")], [
    html.text(text),
  ])
}

fn small(text: String) -> html.Element {
  email.paragraph(
    [
      style.font_size("13px"),
      style.line_height("20px"),
      style.color("#71717a"),
    ],
    [html.text(text)],
  )
}

fn monospace(text: String) -> html.Element {
  email.paragraph(
    [
      style.font_family("ui-monospace, Menlo, monospace"),
      style.font_size("14px"),
      style.background_color("#f4f4f5"),
      style.padding("12px"),
      style.border_radius("6px"),
      style.word_break("break-all"),
    ],
    [html.text(text)],
  )
}
