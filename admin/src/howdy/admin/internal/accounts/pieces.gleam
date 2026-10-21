//// What the user and group pages share: paths, a user's status, the
//// members of a group and a choice of group.

import gleam/list
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/format
import howdy/auth/group.{type Group}
import howdy/auth/user.{type User}
import howdy/ui
import howdy/ui/badge
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

pub fn members_table(config: Config, members: List(User)) -> Element(msg) {
  case members {
    [] -> ui.p([ui.muted("No members.")])
    _ ->
      ui.table([], [
        ui.table_header([], [
          ui.table_row([], [
            ui.table_head([], [text("Email")]),
            ui.table_head([], [text("Created")]),
          ]),
        ]),
        ui.table_body(
          [],
          list.map(members, fn(user) {
            ui.table_row([], [
              ui.table_cell([], [
                ui.link(user_path(config, user.id), [text(user.email)]),
              ]),
              ui.table_cell([], [text(format.at(user.created_at))]),
            ])
          }),
        ),
      ])
  }
}

pub fn group_select(
  groups: List(Group),
  selected selected: String,
) -> Element(msg) {
  ui.native_select(
    [attribute.name("group")],
    list.map(groups, fn(group) {
      html.option(
        [attribute.value(group.id), attribute.selected(group.id == selected)],
        group.name <> " (" <> group.id <> ")",
      )
    }),
  )
}

pub fn status(suspended: Bool) -> Element(msg) {
  case suspended {
    True -> ui.badge(badge.Danger, [], [text("suspended")])
    False -> ui.badge(badge.Outline, [], [text("active")])
  }
}

pub fn user_path(config: Config, id: String) -> String {
  config.path(config, "/users/" <> id)
}

pub fn group_path(config: Config, id: String) -> String {
  config.path(config, "/groups/" <> id)
}
