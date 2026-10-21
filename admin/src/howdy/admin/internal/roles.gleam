//// The authorization pages: roles, their permissions, and who holds them.

import gleam/http/request
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/layout
import howdy/auth.{type Auth}
import howdy/auth/user.{type User}
import howdy/auth/users
import howdy/authorization.{type Authorization, type Scope, Global, Organization}
import howdy/content.{type Content}
import howdy/controller.{type Context, type Controller}
import howdy/form.{type Form}
import howdy/service
import howdy/ui
import howdy/ui/badge
import howdy/ui/button
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

const actor = user.SystemFrom("howdy_admin")

pub fn controller(
  config: Config,
  identity: Auth,
  access: Authorization,
) -> Controller {
  controller.new(config.prefix)
  |> controller.get("/roles", fn(ctx) { index(config, access, ctx) })
  |> controller.post("/roles", fn(ctx) { define(config, access, ctx) })
  |> controller.get("/roles/role", fn(ctx) {
    show(config, identity, access, ctx)
  })
  |> controller.post("/roles/role", fn(ctx) { redefine(config, access, ctx) })
  |> controller.post("/roles/role/assign", fn(ctx) {
    change(config, access, ctx, fn(scope, name, user_id) {
      authorization.assign(access, user_id, name, scope, by: actor)
    })
  })
  |> controller.post("/roles/role/revoke", fn(ctx) {
    change(config, access, ctx, fn(scope, name, user_id) {
      authorization.revoke(access, user_id, name, scope, by: actor)
    })
  })
  |> controller.post("/roles/role/delete", fn(ctx) {
    delete(config, access, ctx)
  })
}

// -- Pages -------------------------------------------------------------------

fn index(
  config: Config,
  access: Authorization,
  ctx: Context,
) -> Response(Content) {
  case authorization.roles(access) {
    Error(error) -> failure(config, ctx, "Roles", error)
    Ok(roles) ->
      layout.page(
        config,
        ctx,
        current: "/roles",
        heading: "Roles",
        live: False,
        content: [
          ui.card([], [
            ui.card_header([], [ui.card_title([text("New role")])]),
            ui.card_content([], [
              define_form(config.path(config, "/roles"), None, "Create"),
            ]),
          ]),
          case roles {
            [] ->
              ui.empty(
                icon: text("🔑"),
                title: "No roles yet",
                description: "Define one above. A role is a named set of permissions in one scope.",
                actions: [],
              )
            _ ->
              ui.table([], [
                ui.table_header([], [
                  ui.table_row([], [
                    ui.table_head([], [text("Role")]),
                    ui.table_head([], [text("Scope")]),
                    ui.table_head([], [text("Permissions")]),
                  ]),
                ]),
                ui.table_body(
                  [],
                  list.map(roles, fn(role) {
                    ui.table_row([], [
                      ui.table_cell([], [
                        ui.link(role_path(config, role.scope, role.name), [
                          text(role.name),
                        ]),
                      ]),
                      ui.table_cell([], [scope_badge(role.scope)]),
                      ui.table_cell([], permission_badges(role.permissions)),
                    ])
                  }),
                ),
              ])
          },
        ],
      )
  }
}

fn show(
  config: Config,
  identity: Auth,
  access: Authorization,
  ctx: Context,
) -> Response(Content) {
  use scope, name <- with_role(config, ctx)
  let found = {
    use roles <- result.try(authorization.roles(access))
    use role <- result.try(
      list.find(roles, fn(role) { role.scope == scope && role.name == name })
      |> result.replace_error(service.NotFound("role")),
    )
    use holders <- result.try(authorization.holders(access, scope, name))
    use holders <- result.try(list.try_map(holders, users.get(identity, _)))
    use everyone <- result.try(users.list(identity))
    Ok(#(role, holders, everyone))
  }
  case found {
    Error(error) -> failure(config, ctx, name, error)
    Ok(#(role, holders, everyone)) -> {
      let here = role_path(config, scope, name)
      let candidates =
        list.filter(everyone, fn(user) {
          !list.any(holders, fn(holder) { holder.id == user.id })
        })
      layout.page(
        config,
        ctx,
        current: "/roles",
        heading: name,
        live: False,
        content: [
          ui.p([
            ui.link(config.path(config, "/roles"), [text("All roles")]),
            text(" · "),
            scope_badge(scope),
          ]),
          ui.card([], [
            ui.card_header([], [ui.card_title([text("Permissions")])]),
            ui.card_content([], [define_form(here, Some(role), "Save")]),
            ui.card_footer([], [
              html.form(
                [attribute.method("post"), attribute.action(here <> "/delete")],
                [ui.submit_button(button.Danger, [], [text("Delete role")])],
              ),
            ]),
          ]),
          ui.card([], [
            ui.card_header([], [ui.card_title([text("Holders")])]),
            ui.card_content([], [
              holders_table(config, here, holders),
              case candidates {
                [] -> element.none()
                _ ->
                  html.form(
                    [
                      attribute.method("post"),
                      attribute.action(here <> "/assign"),
                    ],
                    [
                      ui.row([], [
                        ui.native_select(
                          [attribute.name("user")],
                          list.map(candidates, fn(user) {
                            html.option([attribute.value(user.id)], user.email)
                          }),
                        ),
                        ui.submit_button(button.Secondary, [], [text("Assign")]),
                      ]),
                    ],
                  )
              },
            ]),
          ]),
        ],
      )
    }
  }
}

fn define(
  config: Config,
  access: Authorization,
  ctx: Context,
) -> Response(Content) {
  use form <- form.read(ctx)
  let scope = case form.value(form, "organization") {
    "" -> Global
    id -> Organization(id)
  }
  let name = form.value(form, "name")
  case
    authorization.define_role(access, scope, name, permissions(form), by: actor)
  {
    Ok(Nil) -> layout.redirect(role_path(config, scope, name))
    Error(error) -> failure(config, ctx, "Roles", error)
  }
}

fn redefine(
  config: Config,
  access: Authorization,
  ctx: Context,
) -> Response(Content) {
  use scope, name <- with_role(config, ctx)
  use form <- form.read(ctx)
  case
    authorization.define_role(access, scope, name, permissions(form), by: actor)
  {
    Ok(Nil) -> layout.redirect(role_path(config, scope, name))
    Error(error) -> failure(config, ctx, name, error)
  }
}

fn change(
  config: Config,
  access: Authorization,
  ctx: Context,
  run: fn(Scope, String, String) -> service.Result(Nil),
) -> Response(Content) {
  let _ = access
  use scope, name <- with_role(config, ctx)
  use form <- form.read(ctx)
  case run(scope, name, form.value(form, "user")) {
    Ok(Nil) -> layout.redirect(role_path(config, scope, name))
    Error(error) -> failure(config, ctx, name, error)
  }
}

fn delete(
  config: Config,
  access: Authorization,
  ctx: Context,
) -> Response(Content) {
  use scope, name <- with_role(config, ctx)
  case authorization.delete_role(access, scope, name, by: actor) {
    Ok(Nil) -> layout.redirect(config.path(config, "/roles"))
    Error(error) -> failure(config, ctx, name, error)
  }
}

// -- Pieces ------------------------------------------------------------------

/// Name, scope and permissions; scope and name are fixed for an existing
/// role, whose permissions are replaced as a whole.
fn define_form(
  action: String,
  role: option.Option(authorization.Role),
  submit: String,
) -> Element(msg) {
  let existing = role != None
  let #(name, organization, held) = case role {
    Some(role) -> #(
      role.name,
      case role.scope {
        Global -> ""
        Organization(id) -> id
      },
      role.permissions,
    )
    None -> #("", "", [])
  }
  html.form([attribute.method("post"), attribute.action(action)], [
    ui.stack([], [
      case existing {
        True -> element.none()
        False ->
          ui.row([], [
            ui.field([], [
              ui.label([attribute.for("role-name")], [text("Name")]),
              ui.input([
                attribute.id("role-name"),
                attribute.name("name"),
                attribute.value(name),
                attribute.required(True),
              ]),
            ]),
            ui.field([], [
              ui.label([attribute.for("role-organization")], [
                text("Organization"),
              ]),
              ui.input([
                attribute.id("role-organization"),
                attribute.name("organization"),
                attribute.value(organization),
                attribute.placeholder("leave empty for global"),
              ]),
            ]),
          ])
      },
      ui.field([], [
        ui.label([attribute.for("role-permissions")], [text("Permissions")]),
        ui.textarea(
          [
            attribute.id("role-permissions"),
            attribute.name("permissions"),
            attribute.rows(4),
            attribute.placeholder("one per line, such as invoices.read"),
          ],
          string.join(held, "\n"),
        ),
        ui.field_description([], [
          text(
            "Every permission of the role, one per line. Saving replaces the list.",
          ),
        ]),
      ]),
      ui.row([], [ui.submit_button(button.Primary, [], [text(submit)])]),
    ]),
  ])
}

/// Permissions from the textarea, one per line or comma.
fn permissions(form: Form) -> List(String) {
  form.value(form, "permissions")
  |> string.replace(",", "\n")
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(permission) { permission != "" })
}

fn holders_table(
  config: Config,
  here: String,
  holders: List(User),
) -> Element(msg) {
  case holders {
    [] -> ui.p([ui.muted("Nobody holds this role.")])
    _ ->
      ui.table([], [
        ui.table_body(
          [],
          list.map(holders, fn(user) {
            ui.table_row([], [
              ui.table_cell([], [
                ui.link(config.path(config, "/users/" <> user.id), [
                  text(user.email),
                ]),
              ]),
              ui.table_cell([], [
                html.form(
                  [
                    attribute.method("post"),
                    attribute.action(here <> "/revoke"),
                  ],
                  [
                    html.input([
                      attribute.type_("hidden"),
                      attribute.name("user"),
                      attribute.value(user.id),
                    ]),
                    ui.sized_button(
                      button.Ghost,
                      button.Small,
                      [attribute.type_("submit")],
                      [
                        text("Revoke"),
                      ],
                    ),
                  ],
                ),
              ]),
            ])
          }),
        ),
      ])
  }
}

pub fn scope_badge(scope: Scope) -> Element(msg) {
  case scope {
    Global -> ui.badge(badge.Secondary, [], [text("global")])
    Organization(id) -> ui.badge(badge.Outline, [], [text("org " <> id)])
  }
}

pub fn permission_badges(permissions: List(String)) -> List(Element(msg)) {
  case permissions {
    [] -> [ui.muted("none")]
    _ ->
      list.map(permissions, fn(permission) {
        ui.badge(badge.Outline, [], [text(permission)])
      })
  }
}

/// The role a page is about, from its `scope` and `name` query parameters.
fn with_role(
  config: Config,
  ctx: Context,
  next: fn(Scope, String) -> Response(Content),
) -> Response(Content) {
  let query = request.get_query(ctx.request) |> result.unwrap([])
  let scope =
    list.key_find(query, "scope")
    |> result.try(authorization.scope_from_string)
  let name = list.key_find(query, "name")
  case scope, name {
    Ok(scope), Ok(name) if name != "" -> next(scope, name)
    _, _ -> failure(config, ctx, "Roles", service.NotFound("role"))
  }
}

pub fn role_path(config: Config, scope: Scope, name: String) -> String {
  config.path(config, "/roles/role?")
  <> uri.query_to_string([
    #("scope", authorization.scope_to_string(scope)),
    #("name", name),
  ])
}

fn failure(
  config: Config,
  ctx: Context,
  heading: String,
  error: service.Error,
) -> Response(Content) {
  layout.failed(config, ctx, current: "/roles", heading:, error:)
}
