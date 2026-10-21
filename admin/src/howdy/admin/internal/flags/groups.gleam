//// The groups rules can name: the list, and one group with its members.

import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/result
import gleam/uri
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/flags/pieces
import howdy/admin/internal/layout
import howdy/content.{type Content}
import howdy/controller.{type Context}
import howdy/flags.{type Flags}
import howdy/service
import howdy/ui
import howdy/ui/button
import lustre/attribute
import lustre/element.{text}
import lustre/element/html

pub fn index(
  config: Config,
  features: Flags,
  ctx: Context,
) -> Response(Content) {
  case flags.groups(features) {
    Error(error) -> pieces.groups_failure(config, ctx, error)
    Ok(found) ->
      layout.page(
        config,
        ctx,
        current: "/flags/groups",
        heading: "Flag groups",
        live: False,
        content: [
          pieces.read_only_notice(features),
          pieces.only(
            flags.writable(features),
            ui.card([], [
              ui.card_header([], [
                ui.card_title([text("New group")]),
                ui.card_description([
                  text(
                    "A named set of users and organizations, such as staff or beta testers, that flags can allow or block together.",
                  ),
                ]),
              ]),
              ui.card_content([], [
                html.form(
                  [
                    attribute.method("post"),
                    attribute.action(config.path(config, "/flags/groups")),
                  ],
                  [
                    ui.row([], [
                      ui.input([
                        attribute.name("name"),
                        attribute.placeholder("name, such as beta"),
                        attribute.required(True),
                        attribute.attribute("aria-label", "Name"),
                      ]),
                      ui.input([
                        attribute.name("description"),
                        attribute.placeholder("what it is for"),
                        attribute.attribute("aria-label", "Description"),
                      ]),
                      ui.submit_button(button.Primary, [], [text("Create")]),
                    ]),
                  ],
                ),
              ]),
            ]),
          ),
          case found {
            [] ->
              ui.empty(
                icon: text("👥"),
                title: "No groups yet",
                description: "Create one above, then add users and organizations to it.",
                actions: [],
              )
            _ ->
              ui.table([], [
                ui.table_header([], [
                  ui.table_row([], [
                    ui.table_head([], [text("Group")]),
                    ui.table_head([], [text("Members")]),
                    ui.table_head([], [text("Description")]),
                  ]),
                ]),
                ui.table_body(
                  [],
                  list.map(found, fn(group) {
                    ui.table_row([], [
                      ui.table_cell([], [
                        ui.link(pieces.group_path(config, group.name), [
                          text(group.name),
                        ]),
                      ]),
                      ui.table_cell([], [
                        text(int.to_string(list.length(group.members))),
                      ]),
                      ui.table_cell([], [text(group.description)]),
                    ])
                  }),
                ),
              ])
          },
        ],
      )
  }
}

pub fn show(
  config: Config,
  features: Flags,
  ctx: Context,
) -> Response(Content) {
  use name <- pieces.with_group(config, ctx)
  let writable = flags.writable(features)
  let found = {
    use all <- result.try(flags.groups(features))
    list.find(all, fn(group) { group.name == name })
    |> result.replace_error(service.NotFound("no group named " <> name))
  }
  case found {
    Error(error) -> pieces.groups_failure(config, ctx, error)
    Ok(found) -> {
      let action = fn(rest) {
        config.path(config, "/flags/groups/group/" <> rest <> "?")
        <> uri.query_to_string([#("name", name)])
      }
      layout.page(
        config,
        ctx,
        current: "/flags/groups",
        heading: name,
        live: False,
        content: [
          ui.p([
            ui.link(config.path(config, "/flags/groups"), [text("All groups")]),
            text(" · " <> found.description),
          ]),
          ui.card([], [
            ui.card_header([], [ui.card_title([text("Members")])]),
            ui.card_content([], [
              ui.stack([], [
                case found.members {
                  [] -> ui.p([ui.muted("Nobody is in this group.")])
                  members ->
                    ui.table([], [
                      ui.table_body(
                        [],
                        list.map(members, fn(member) {
                          ui.table_row([], [
                            ui.table_cell([], [
                              pieces.target_view(config, member),
                            ]),
                            ui.table_cell([], [
                              pieces.only(
                                writable,
                                html.form(
                                  [
                                    attribute.method("post"),
                                    attribute.action(action("remove")),
                                  ],
                                  [
                                    html.input([
                                      attribute.type_("hidden"),
                                      attribute.name("member"),
                                      attribute.value(flags.target_to_string(
                                        member,
                                      )),
                                    ]),
                                    ui.sized_button(
                                      button.Ghost,
                                      button.Small,
                                      [attribute.type_("submit")],
                                      [text("Remove")],
                                    ),
                                  ],
                                ),
                              ),
                            ]),
                          ])
                        }),
                      ),
                    ])
                },
                pieces.only(
                  writable,
                  html.form(
                    [attribute.method("post"), attribute.action(action("add"))],
                    [
                      ui.row(
                        [],
                        list.append(pieces.target_inputs(config, "member"), [
                          ui.submit_button(button.Secondary, [], [text("Add")]),
                        ]),
                      ),
                    ],
                  ),
                ),
              ]),
            ]),
            pieces.only(
              writable,
              ui.card_footer([], [
                html.form(
                  [attribute.method("post"), attribute.action(action("delete"))],
                  [ui.submit_button(button.Danger, [], [text("Delete group")])],
                ),
              ]),
            ),
          ]),
        ],
      )
    }
  }
}
