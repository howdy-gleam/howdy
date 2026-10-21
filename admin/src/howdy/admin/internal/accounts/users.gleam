//// The users: the list, one user with their sessions, roles and group,
//// creating, suspending, moving and deleting them, and signing in as one.

import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import howdy/admin/internal/accounts/pieces
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/format
import howdy/admin/internal/layout
import howdy/admin/internal/roles
import howdy/auth.{type Auth}
import howdy/auth/field
import howdy/auth/group.{Single}
import howdy/auth/groups
import howdy/auth/routes
import howdy/auth/user.{type User}
import howdy/auth/users
import howdy/authorization.{type Authorization}
import howdy/content.{type Content}
import howdy/controller.{type Context}
import howdy/form
import howdy/service
import howdy/ui
import howdy/ui/badge
import howdy/ui/button
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

/// Drop the session token the API pages keep for calling as this user,
/// since it is about to stop working. See `howdy/admin/internal/api/calling`.
@external(erlang, "howdy_admin_ffi", "forget_token")
pub fn forget_token(identity: Auth, user_id: String) -> Nil

pub fn user_index(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(Content) {
  let listed = {
    use listed <- result.try(users.list(identity))
    use groups <- result.try(groups.list(identity))
    use listed <- result.try(
      list.try_map(listed, fn(user) {
        use suspended <- result.try(users.suspended(identity, user.id))
        Ok(#(user, suspended))
      }),
    )
    Ok(#(listed, groups))
  }
  case listed {
    Error(error) -> layout.failed(config, ctx, "/users", "Users", error)
    Ok(#(listed, groups)) ->
      layout.page(
        config,
        ctx,
        current: "/users",
        heading: "Users",
        live: False,
        content: [
          ui.card([], [
            ui.card_header([], [ui.card_title([text("New user")])]),
            ui.card_content([], [
              html.form(
                [
                  attribute.method("post"),
                  attribute.action(config.path(config, "/users")),
                ],
                [
                  ui.row([], [
                    ui.input([
                      attribute.name("email"),
                      attribute.type_("email"),
                      attribute.placeholder("email address"),
                      attribute.required(True),
                    ]),
                    case auth.group_mode(identity) {
                      Single -> element.none()
                      _ ->
                        pieces.group_select(groups, selected: group.default_id)
                    },
                    ui.submit_button(button.Primary, [], [text("Create")]),
                  ]),
                ],
              ),
              ui.field_description([], [
                text(
                  "The user is provisioned without a credential. Sign in as them from their page, or let them set a password or passkey.",
                ),
              ]),
            ]),
          ]),
          case listed {
            [] ->
              ui.empty(
                icon: text("☺"),
                title: "No users yet",
                description: "Create one above, or register through your application.",
                actions: [],
              )
            _ ->
              ui.table([], [
                ui.table_header([], [
                  ui.table_row([], [
                    ui.table_head([], [text("Email")]),
                    ui.table_head([], [text("Group")]),
                    ui.table_head([], [text("Created")]),
                    ui.table_head([], [text("Status")]),
                  ]),
                ]),
                ui.table_body(
                  [],
                  list.map(listed, fn(entry) {
                    let #(user, suspended) = entry
                    ui.table_row([], [
                      ui.table_cell([], [
                        ui.link(pieces.user_path(config, user.id), [
                          text(user.email),
                        ]),
                      ]),
                      ui.table_cell([], [
                        ui.link(pieces.group_path(config, user.group_id), [
                          text(user.group_id),
                        ]),
                      ]),
                      ui.table_cell([], [text(format.at(user.created_at))]),
                      ui.table_cell([], [pieces.status(suspended)]),
                    ])
                  }),
                ),
              ])
          },
        ],
      )
  }
}

pub fn user_create(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(Content) {
  use form <- form.read(ctx)
  let email = form.value(form, "email")
  let identity = case form.get(form, "group") {
    Ok(id) if id != "" -> auth.in_group(identity, id)
    _ -> identity
  }
  case auth.provision(identity, email, by: config.actor) {
    Ok(user) -> layout.redirect(pieces.user_path(config, user.id))
    Error(error) -> layout.failed(config, ctx, "/users", "Users", error)
  }
}

pub fn user_show(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(Content) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  let found = {
    use user <- result.try(users.get(identity, id))
    use suspended <- result.try(users.suspended(identity, id))
    use fields <- result.try(users.fields(identity, id))
    use groups <- result.try(groups.list(identity))
    use held <- result.try(case config.authorization {
      Some(access) -> {
        use assignments <- result.try(authorization.assignments(access, id))
        use roles <- result.try(authorization.roles(access))
        Ok(Some(#(assignments, roles)))
      }
      None -> Ok(None)
    })
    use sessions <- result.try(auth.sessions_of(identity, id))
    Ok(#(user, suspended, field.to_list(fields), groups, held, sessions))
  }
  case found {
    Error(error) -> layout.failed(config, ctx, "/users", "User", error)
    Ok(#(user, suspended, fields, groups, held, sessions)) -> {
      let action = fn(name, variant, label) {
        html.form(
          [
            attribute.method("post"),
            attribute.action(pieces.user_path(config, id) <> name),
          ],
          [ui.submit_button(variant, [], [text(label)])],
        )
      }
      layout.page(
        config,
        ctx,
        current: "/users",
        heading: user.email,
        live: False,
        content: [
          ui.p([ui.link(config.path(config, "/users"), [text("All users")])]),
          ui.card([], [
            ui.card_header([], [
              ui.card_title([text("Account")]),
              ui.card_action([], [pieces.status(suspended)]),
            ]),
            ui.card_content([], [
              layout.facts([
                #("Id", user.id),
                #("Email", user.email),
                #("Group", user.group_id),
                #("Created", format.at(user.created_at)),
                #("Updated", format.at(user.updated_at)),
              ]),
            ]),
            ui.card_footer([], [
              ui.row([], [
                case suspended {
                  True -> element.none()
                  False ->
                    action(
                      "/impersonate",
                      button.Primary,
                      "Sign in as this user",
                    )
                },
                case suspended {
                  True -> action("/resume", button.Secondary, "Resume")
                  False -> action("/suspend", button.Danger, "Suspend")
                },
                action("/revoke", button.Outline, "Sign out everywhere"),
              ]),
            ]),
          ]),
          case fields {
            [] -> element.none()
            _ ->
              ui.card([], [
                ui.card_header([], [ui.card_title([text("Fields")])]),
                ui.card_content([], [layout.facts(fields)]),
              ])
          },
          sessions_card(config, id, sessions),
          case held {
            None -> element.none()
            Some(#(assignments, roles)) ->
              roles_card(config, id, assignments, roles)
          },
          case auth.account_deletion_enabled(identity) {
            True -> delete_card(config, user)
            False ->
              ui.p([
                ui.muted(
                  "Account deletion is off: enable it with auth.with_account_deletion, whose callback cleans up your own tables.",
                ),
              ])
          },
          case auth.group_mode(identity) {
            Single -> element.none()
            _ ->
              ui.card([], [
                ui.card_header([], [
                  ui.card_title([text("Move to another group")]),
                ]),
                ui.card_content([], [
                  html.form(
                    [
                      attribute.method("post"),
                      attribute.action(pieces.user_path(config, id) <> "/move"),
                    ],
                    [
                      ui.row([], [
                        pieces.group_select(groups, selected: user.group_id),
                        ui.submit_button(button.Secondary, [], [text("Move")]),
                      ]),
                    ],
                  ),
                ]),
              ])
          },
        ],
      )
    }
  }
}

/// Run something on the user in the path, then go back to their page.
pub fn user_action(
  config: Config,
  ctx: Context,
  run: fn(String) -> service.Result(Nil),
) -> Response(Content) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  case run(id) {
    Ok(Nil) -> layout.redirect(pieces.user_path(config, id))
    Error(error) -> layout.failed(config, ctx, "/users", "User", error)
  }
}

pub fn user_move(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(Content) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  use form <- form.read(ctx)
  case
    groups.move(identity, id, to: form.value(form, "group"), by: config.actor)
  {
    Ok(_) -> layout.redirect(pieces.user_path(config, id))
    Error(error) -> layout.failed(config, ctx, "/users", "User", error)
  }
}

/// Issue a session for the user and make it the browser's, then go to the
/// application's root.
pub fn impersonate(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(Content) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  case auth.impersonate(identity, id, by: config.actor) {
    Ok(session) ->
      routes.signed_in(identity, ctx, layout.redirect("/"), session)
    Error(error) -> layout.failed(config, ctx, "/users", "User", error)
  }
}

/// Deletion behind a confirmation: the email address must be typed back.
fn delete_card(config: Config, user: User) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("Delete account")]),
      ui.card_description([
        text(
          "Removes the account, its credentials and sessions, and whatever your deletion callback cleans up. There is no undo.",
        ),
      ]),
    ]),
    ui.card_content([], [
      html.form(
        [
          attribute.method("post"),
          attribute.action(pieces.user_path(config, user.id) <> "/delete"),
        ],
        [
          ui.row([], [
            ui.input([
              attribute.name("confirm"),
              attribute.type_("email"),
              attribute.placeholder("type " <> user.email <> " to confirm"),
              attribute.required(True),
            ]),
            ui.submit_button(button.Danger, [], [text("Delete account")]),
          ]),
        ],
      ),
    ]),
  ])
}

pub fn user_delete(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(Content) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  use form <- form.read(ctx)
  let deleted = {
    use user <- result.try(users.get(identity, id))
    use _ <- result.try(
      case
        string.lowercase(string.trim(form.value(form, "confirm"))) == user.email
      {
        True -> Ok(Nil)
        False ->
          Error(service.Invalid("type the account's email address to confirm"))
      },
    )
    forget_token(identity, id)
    auth.delete_user(identity, id, by: config.actor)
  }
  case deleted {
    Ok(Nil) -> layout.redirect(config.path(config, "/users"))
    Error(error) -> layout.failed(config, ctx, "/users", "User", error)
  }
}

/// The user's live sessions, newest first, each with a revoke button.
fn sessions_card(
  config: Config,
  id: String,
  sessions: List(auth.SessionInfo),
) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("Sessions")]),
      ui.card_description([
        text(format.describe(list.length(sessions), "live session")),
      ]),
    ]),
    ui.card_content([], [
      case sessions {
        [] -> ui.p([ui.muted("Not signed in anywhere.")])
        _ ->
          ui.table([], [
            ui.table_header([], [
              ui.table_row([], [
                ui.table_head([], [text("Method")]),
                ui.table_head([], [text("Signed in")]),
                ui.table_head([], [text("Last seen")]),
                ui.table_head([], [text("Expires")]),
                ui.table_head([], [text("Client")]),
                ui.table_head([], [text("")]),
              ]),
            ]),
            ui.table_body(
              [],
              list.map(sessions, fn(session) {
                ui.table_row([], [
                  ui.table_cell([], [method_badge(session.method)]),
                  ui.table_cell([], [
                    text(format.at_seconds(session.created_at)),
                  ]),
                  ui.table_cell([], [
                    text(format.at_seconds(session.last_seen_at)),
                  ]),
                  ui.table_cell([], [
                    text(format.at_seconds(session.expires_at)),
                  ]),
                  ui.table_cell([], [
                    case session.client {
                      "" -> ui.muted("unknown")
                      client -> text(client)
                    },
                  ]),
                  ui.table_cell([], [
                    html.form(
                      [
                        attribute.method("post"),
                        attribute.action(
                          pieces.user_path(config, id) <> "/sessions/revoke",
                        ),
                      ],
                      [
                        html.input([
                          attribute.type_("hidden"),
                          attribute.name("session"),
                          attribute.value(session.id),
                        ]),
                        ui.sized_button(
                          button.Ghost,
                          button.Small,
                          [attribute.type_("submit")],
                          [text("Revoke")],
                        ),
                      ],
                    ),
                  ]),
                ])
              }),
            ),
          ])
      },
    ]),
  ])
}

fn method_badge(method: auth.Method) -> Element(msg) {
  case method {
    auth.EmailToken -> ui.badge(badge.Outline, [], [text("email token")])
    auth.Password -> ui.badge(badge.Outline, [], [text("password")])
    auth.Passkey -> ui.badge(badge.Outline, [], [text("passkey")])
    auth.Provider(id) -> ui.badge(badge.Outline, [], [text("provider " <> id)])
    auth.Impersonation -> ui.badge(badge.Primary, [], [text("impersonation")])
  }
}

pub fn session_revoke(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(Content) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  use form <- form.read(ctx)
  // The API pages may be holding this very session's token.
  forget_token(identity, id)
  case
    auth.revoke_session_of(
      identity,
      id,
      form.value(form, "session"),
      by: config.actor,
    )
  {
    Ok(Nil) -> layout.redirect(pieces.user_path(config, id))
    Error(error) -> layout.failed(config, ctx, "/users", "User", error)
  }
}

/// The roles a user holds, each with a revoke button, and a form to assign
/// one they do not.
fn roles_card(
  config: Config,
  id: String,
  assignments: List(#(authorization.Scope, String)),
  roles: List(authorization.Role),
) -> Element(msg) {
  let here = pieces.user_path(config, id) <> "/roles"
  let available =
    list.filter(roles, fn(role) {
      !list.contains(assignments, #(role.scope, role.name))
    })
  ui.card([], [
    ui.card_header([], [ui.card_title([text("Roles")])]),
    ui.card_content([], [
      case assignments {
        [] -> ui.p([ui.muted("No roles.")])
        _ ->
          ui.table([], [
            ui.table_body(
              [],
              list.map(assignments, fn(assignment) {
                let #(scope, role) = assignment
                ui.table_row([], [
                  ui.table_cell([], [
                    ui.link(roles.role_path(config, scope, role), [text(role)]),
                  ]),
                  ui.table_cell([], [roles.scope_badge(scope)]),
                  ui.table_cell([], [
                    html.form(
                      [
                        attribute.method("post"),
                        attribute.action(here <> "/revoke"),
                      ],
                      [
                        html.input([
                          attribute.type_("hidden"),
                          attribute.name("role"),
                          attribute.value(role_value(scope, role)),
                        ]),
                        ui.sized_button(
                          button.Ghost,
                          button.Small,
                          [attribute.type_("submit")],
                          [text("Revoke")],
                        ),
                      ],
                    ),
                  ]),
                ])
              }),
            ),
          ])
      },
      case available {
        [] -> element.none()
        _ ->
          html.form(
            [attribute.method("post"), attribute.action(here <> "/assign")],
            [
              ui.row([], [
                ui.native_select(
                  [attribute.name("role")],
                  list.map(available, fn(role) {
                    html.option(
                      [attribute.value(role_value(role.scope, role.name))],
                      role.name
                        <> " ("
                        <> authorization.scope_to_string(role.scope)
                        <> ")",
                    )
                  }),
                ),
                ui.submit_button(button.Secondary, [], [text("Assign")]),
              ]),
            ],
          )
      },
    ]),
  ])
}

/// A role and its scope in one form value. Names cannot contain a tab.
fn role_value(scope: authorization.Scope, role: String) -> String {
  authorization.scope_to_string(scope) <> "\t" <> role
}

pub fn role_change(
  config: Config,
  ctx: Context,
  run: fn(Authorization, String, authorization.Scope, String) ->
    service.Result(Nil),
) -> Response(Content) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  use form <- form.read(ctx)
  let parsed = {
    use access <- result.try(option.to_result(
      config.authorization,
      service.NotFound("authorization"),
    ))
    use #(scope, role) <- result.try(
      string.split_once(form.value(form, "role"), "\t")
      |> result.replace_error(service.Invalid("choose a role")),
    )
    use scope <- result.try(
      authorization.scope_from_string(scope)
      |> result.replace_error(service.Invalid("unknown scope")),
    )
    run(access, id, scope, role)
  }
  case parsed {
    Ok(Nil) -> layout.redirect(pieces.user_path(config, id))
    Error(error) -> layout.failed(config, ctx, "/users", "User", error)
  }
}

/// For the overview.
pub fn count_users(identity: Auth) -> service.Result(Int) {
  users.list(identity) |> result.map(list.length)
}
