//// What the flag and group pages share: targets as forms name and show
//// them, the read-only notice, paths, and failure pages.

import gleam/http/request
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/layout
import howdy/auth/users
import howdy/content.{type Content}
import howdy/controller.{type Context}
import howdy/flags.{type Flags, type Target}
import howdy/form.{type Form}
import howdy/service
import howdy/ui
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

/// Where read-only flags are managed, when they are.
pub fn read_only_notice(features: Flags) -> Element(msg) {
  case flags.writable(features) {
    True -> element.none()
    False ->
      ui.p([
        ui.muted(
          "These flags are kept in "
          <> flags.store_name(features)
          <> ", which is read-only here: change them where they are managed.",
        ),
      ])
  }
}

/// `element` when `shown`, nothing otherwise.
pub fn only(shown: Bool, element: Element(msg)) -> Element(msg) {
  case shown {
    True -> element
    False -> element.none()
  }
}

/// A kind and an id. Group members cannot be groups; `add_member` refuses
/// them, so the choice is offered everywhere and explained there.
pub fn target_inputs(config: Config, id: String) -> List(Element(msg)) {
  [
    ui.native_select(
      [attribute.name("kind"), attribute.attribute("aria-label", "Kind")],
      [
        html.option([attribute.value("user")], "User"),
        html.option([attribute.value("org")], "Organization"),
        ..case id {
          "member" -> []
          _ -> [html.option([attribute.value("group")], "Group")]
        }
      ],
    ),
    ui.input([
      attribute.id(id <> "-target"),
      attribute.name("id"),
      attribute.required(True),
      attribute.placeholder(case config.identity {
        Some(_) -> "id, user email, or group name"
        None -> "id or group name"
      }),
      attribute.attribute("aria-label", "Id"),
    ]),
  ]
}

/// The target a form names. With auth registered, a user can be given by
/// email.
pub fn read_target(config: Config, form: Form) -> service.Result(Target) {
  let id = string.trim(form.value(form, "id"))
  case form.value(form, "kind"), config.identity {
    "user", Some(identity) ->
      case string.contains(id, "@") {
        False -> Ok(flags.User(id))
        True -> {
          use everyone <- result.try(users.list(identity))
          list.find(everyone, fn(user) { user.email == id })
          |> result.map(fn(user) { flags.User(user.id) })
          |> result.replace_error(service.NotFound("no user with email " <> id))
        }
      }
    "user", None -> Ok(flags.User(id))
    "org", _ -> Ok(flags.Organization(id))
    "group", _ -> Ok(flags.Group(id))
    _, _ -> Error(service.Invalid("choose a user, organization or group"))
  }
}

/// A target, with the user's email when auth can say.
pub fn target_view(config: Config, target: Target) -> Element(msg) {
  let label = flags.target_to_string(target)
  case target, config.identity {
    flags.User(id), Some(identity) ->
      case users.get(identity, id) {
        Ok(user) ->
          html.span([], [
            ui.link(config.path(config, "/users/" <> id), [text(user.email)]),
            ui.muted(" " <> label),
          ])
        Error(_) -> html.code([], [text(label)])
      }
    flags.Group(name), _ ->
      ui.link(group_path(config, name), [html.code([], [text(label)])])
    _, _ -> html.code([], [text(label)])
  }
}

pub fn with_key(
  config: Config,
  ctx: Context,
  next: fn(String) -> Response(Content),
) -> Response(Content) {
  case
    request.get_query(ctx.request)
    |> result.unwrap([])
    |> list.key_find("key")
  {
    Ok(key) if key != "" -> next(key)
    _ -> failure(config, ctx, "Flags", service.NotFound("flag"))
  }
}

pub fn with_group(
  config: Config,
  ctx: Context,
  next: fn(String) -> Response(Content),
) -> Response(Content) {
  case
    request.get_query(ctx.request)
    |> result.unwrap([])
    |> list.key_find("name")
  {
    Ok(name) if name != "" -> next(name)
    _ -> groups_failure(config, ctx, service.NotFound("group"))
  }
}

pub fn flag_path(config: Config, key: String) -> String {
  config.path(config, "/flags/flag?") <> uri.query_to_string([#("key", key)])
}

pub fn group_path(config: Config, name: String) -> String {
  config.path(config, "/flags/groups/group?")
  <> uri.query_to_string([#("name", name)])
}

pub fn failure(
  config: Config,
  ctx: Context,
  heading: String,
  error: service.Error,
) -> Response(Content) {
  layout.failed(config, ctx, current: "/flags", heading:, error:)
}

pub fn groups_failure(
  config: Config,
  ctx: Context,
  error: service.Error,
) -> Response(Content) {
  layout.failed(
    config,
    ctx,
    current: "/flags/groups",
    heading: "Flag groups",
    error:,
  )
}
