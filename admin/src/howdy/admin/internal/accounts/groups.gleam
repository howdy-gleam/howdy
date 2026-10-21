//// The groups: the list, one group with its members, and creating,
//// renaming and deleting them.

import gleam/http/response.{type Response}
import gleam/list
import gleam/result
import howdy/admin/internal/accounts/pieces
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/format
import howdy/admin/internal/layout
import howdy/auth.{type Auth}
import howdy/auth/group.{Single}
import howdy/auth/groups
import howdy/content.{type Content}
import howdy/controller.{type Context}
import howdy/form
import howdy/service
import howdy/ui
import howdy/ui/button
import lustre/attribute
import lustre/element.{text}
import lustre/element/html

pub fn group_index(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(Content) {
  case groups.list(identity) {
    Error(error) -> layout.failed(config, ctx, "/groups", "Groups", error)
    Ok(listed) ->
      layout.page(
        config,
        ctx,
        current: "/groups",
        heading: "Groups",
        live: False,
        content: [
          ui.p([
            ui.muted(
              "Group mode: " <> group.mode_name(auth.group_mode(identity)),
            ),
          ]),
          case auth.group_mode(identity) {
            Single ->
              ui.p([
                text(
                  "Every user is in the default group. Choose another mode with auth.with_groups to create more.",
                ),
              ])
            _ ->
              ui.card([], [
                ui.card_header([], [ui.card_title([text("New group")])]),
                ui.card_content([], [
                  html.form(
                    [
                      attribute.method("post"),
                      attribute.action(config.path(config, "/groups")),
                    ],
                    [
                      ui.row([], [
                        ui.input([
                          attribute.name("name"),
                          attribute.placeholder("name"),
                          attribute.required(True),
                        ]),
                        ui.input([
                          attribute.name("id"),
                          attribute.placeholder("id (optional)"),
                        ]),
                        ui.submit_button(button.Primary, [], [text("Create")]),
                      ]),
                    ],
                  ),
                ]),
              ])
          },
          ui.table([], [
            ui.table_header([], [
              ui.table_row([], [
                ui.table_head([], [text("Name")]),
                ui.table_head([], [text("Id")]),
                ui.table_head([], [text("Created")]),
              ]),
            ]),
            ui.table_body(
              [],
              list.map(listed, fn(group) {
                ui.table_row([], [
                  ui.table_cell([], [
                    ui.link(pieces.group_path(config, group.id), [
                      text(group.name),
                    ]),
                  ]),
                  ui.table_cell([], [text(group.id)]),
                  ui.table_cell([], [text(format.at(group.created_at))]),
                ])
              }),
            ),
          ]),
        ],
      )
  }
}

pub fn group_create(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(Content) {
  use form <- form.read(ctx)
  let name = form.value(form, "name")
  let created = case form.value(form, "id") {
    "" -> groups.create(identity, name:, by: config.actor)
    id -> groups.create_with_id(identity, id:, name:, by: config.actor)
  }
  case created {
    Ok(group) -> layout.redirect(pieces.group_path(config, group.id))
    Error(error) -> layout.failed(config, ctx, "/groups", "Groups", error)
  }
}

pub fn group_show(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(Content) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  let found = {
    use group <- result.try(groups.get(identity, id))
    use members <- result.try(groups.members(identity, id))
    Ok(#(group, members))
  }
  case found {
    Error(error) -> layout.failed(config, ctx, "/groups", "Group", error)
    Ok(#(group, members)) ->
      layout.page(
        config,
        ctx,
        current: "/groups",
        heading: group.name,
        live: False,
        content: [
          ui.p([ui.link(config.path(config, "/groups"), [text("All groups")])]),
          ui.card([], [
            ui.card_header([], [ui.card_title([text("Group")])]),
            ui.card_content([], [
              layout.facts([
                #("Id", group.id),
                #("Created", format.at(group.created_at)),
                #("Updated", format.at(group.updated_at)),
              ]),
              html.form(
                [
                  attribute.method("post"),
                  attribute.action(pieces.group_path(config, id) <> "/rename"),
                ],
                [
                  ui.row([], [
                    ui.input([
                      attribute.name("name"),
                      attribute.value(group.name),
                      attribute.required(True),
                    ]),
                    ui.submit_button(button.Secondary, [], [text("Rename")]),
                  ]),
                ],
              ),
            ]),
            ui.card_footer([], [
              html.form(
                [
                  attribute.method("post"),
                  attribute.action(pieces.group_path(config, id) <> "/delete"),
                ],
                [ui.submit_button(button.Danger, [], [text("Delete group")])],
              ),
            ]),
          ]),
          ui.h2("Members"),
          pieces.members_table(config, members),
        ],
      )
  }
}

pub fn group_rename(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(Content) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  use form <- form.read(ctx)
  case
    groups.rename(identity, id, to: form.value(form, "name"), by: config.actor)
  {
    Ok(_) -> layout.redirect(pieces.group_path(config, id))
    Error(error) -> layout.failed(config, ctx, "/groups", "Group", error)
  }
}

pub fn group_delete(
  config: Config,
  identity: Auth,
  ctx: Context,
) -> Response(Content) {
  let id = result.unwrap(controller.param(ctx, "id"), "")
  case groups.delete(identity, id, by: config.actor) {
    Ok(Nil) -> layout.redirect(config.path(config, "/groups"))
    Error(error) -> layout.failed(config, ctx, "/groups", "Group", error)
  }
}

pub fn count_groups(identity: Auth) -> service.Result(Int) {
  groups.list(identity) |> result.map(list.length)
}
