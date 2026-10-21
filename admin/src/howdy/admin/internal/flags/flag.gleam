//// The flags: the index of every flag the code defines or the store
//// remembers, and one flag's kill switch, rules, check and history.

import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/flags/pieces
import howdy/admin/internal/format
import howdy/admin/internal/layout
import howdy/auth/users
import howdy/content.{type Content}
import howdy/controller.{type Context}
import howdy/flags.{type Flags, type Setting}
import howdy/service
import howdy/ui
import howdy/ui/badge
import howdy/ui/button
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

/// A row of the index: a registered flag, or a stored key the code no
/// longer has.
type Entry {
  Entry(key: String, flag: Option(flags.Flag), setting: Option(Setting))
}

fn entries(features: Flags) -> service.Result(List(Entry)) {
  use stored <- result.map(flags.settings(features))
  let defined = flags.defined(features)
  let registered =
    list.map(defined, fn(flag) {
      Entry(
        key: flags.key(flag),
        flag: Some(flag),
        setting: list.key_find(stored, flags.key(flag)) |> option.from_result,
      )
    })
  let orphans =
    list.filter_map(stored, fn(row) {
      case list.any(defined, fn(flag) { flags.key(flag) == row.0 }) {
        True -> Error(Nil)
        False -> Ok(Entry(key: row.0, flag: None, setting: Some(row.1)))
      }
    })
  list.append(registered, orphans)
}

pub fn index(
  config: Config,
  features: Flags,
  ctx: Context,
) -> Response(Content) {
  let found = {
    use entries <- result.try(entries(features))
    use changes <- result.try(flags.history(features, of: None, limit: 20))
    Ok(#(entries, changes))
  }
  case found {
    Error(error) -> pieces.failure(config, ctx, "Flags", error)
    Ok(#(entries, changes)) ->
      layout.page(
        config,
        ctx,
        current: "/flags",
        heading: "Flags",
        live: False,
        content: [
          pieces.read_only_notice(features),
          case entries {
            [] ->
              ui.empty(
                icon: text("🚩"),
                title: "No flags registered",
                description: "Define flags with flags.flag and pass them to flags.register before flags.start.",
                actions: [],
              )
            _ ->
              ui.table([], [
                ui.table_header([], [
                  ui.table_row([], [
                    ui.table_head([], [text("Flag")]),
                    ui.table_head([], [text("State")]),
                    ui.table_head([], [text("Rules")]),
                    ui.table_head([], [text("Description")]),
                  ]),
                ]),
                ui.table_body(
                  [],
                  list.map(entries, fn(entry) {
                    ui.table_row([], [
                      ui.table_cell([], [
                        ui.link(pieces.flag_path(config, entry.key), [
                          html.code([], [text(entry.key)]),
                        ]),
                      ]),
                      ui.table_cell([], state_badges(entry)),
                      ui.table_cell([], [text(rule_count(entry.setting))]),
                      ui.table_cell([], [
                        case entry.flag {
                          Some(flag) -> text(flags.description(flag))
                          None ->
                            ui.muted(
                              "Not in the code any more: reset it to tidy it away.",
                            )
                        },
                      ]),
                    ])
                  }),
                ),
              ])
          },
          ui.card([], [
            ui.card_header([], [ui.card_title([text("Recent changes")])]),
            ui.card_content([], [
              history_table(config, changes, True, flags.writable(features)),
            ]),
          ]),
        ],
      )
  }
}

pub fn show(
  config: Config,
  features: Flags,
  ctx: Context,
) -> Response(Content) {
  use key <- pieces.with_key(config, ctx)
  let found = {
    use entries <- result.try(entries(features))
    use entry <- result.try(
      list.find(entries, fn(entry) { entry.key == key })
      |> result.replace_error(service.NotFound("no flag named " <> key)),
    )
    use changes <- result.try(flags.history(features, of: Some(key), limit: 50))
    Ok(#(entry, changes))
  }
  case found {
    Error(error) -> pieces.failure(config, ctx, key, error)
    Ok(#(entry, changes)) -> {
      let here = pieces.flag_path(config, key)
      let action = fn(name) {
        config.path(config, "/flags/flag/" <> name <> "?")
        <> uri.query_to_string([#("key", key)])
      }
      let current = case entry.flag, entry.setting {
        _, Some(setting) -> setting
        Some(flag), None ->
          flags.Setting(
            killed: False,
            rollout: case flags.default(flag) {
              True -> 10_000
              False -> 0
            },
            bucketing: flags.ByUser,
            allowed: [],
            blocked: [],
            ramp: None,
          )
        None, None ->
          flags.Setting(
            killed: False,
            rollout: 0,
            bucketing: flags.ByUser,
            allowed: [],
            blocked: [],
            ramp: None,
          )
      }
      let writable = flags.writable(features)
      layout.page(
        config,
        ctx,
        current: "/flags",
        heading: key,
        live: False,
        content: [
          ui.p([
            ui.link(config.path(config, "/flags"), [text("All flags")]),
            text(" · "),
            ..state_badges(entry)
          ]),
          case entry.flag {
            Some(flag) ->
              ui.p([
                text(flags.description(flag)),
                ui.muted(
                  " Default "
                  <> case flags.default(flag) {
                    True -> "on"
                    False -> "off"
                  }
                  <> case entry.setting {
                    Some(_) -> ", overridden by what is stored."
                    None -> ", and nothing is stored: that is what applies."
                  }
                  <> " Rollouts and ramps are set from the app or a console with howdy/flags, not here.",
                ),
              ])
            None ->
              ui.p([
                ui.muted(
                  "The code no longer registers this flag. Its settings are unused; reset it to delete them.",
                ),
              ])
          },
          pieces.read_only_notice(features),
          case entry.flag {
            None -> element.none()
            Some(flag) ->
              ui.stack([], [
                case writable {
                  True -> kill_card(action, current)
                  False -> element.none()
                },
                rules_card(config, action, current, writable),
                check_card(config, ctx, features, flag, here),
              ])
          },
          ui.card([], [
            ui.card_header([], [ui.card_title([text("History")])]),
            ui.card_content([], [
              history_table(config, changes, False, flags.writable(features)),
            ]),
            case entry.setting, writable {
              Some(_), True ->
                ui.card_footer([], [
                  html.form(
                    [
                      attribute.method("post"),
                      attribute.action(action("forget")),
                    ],
                    [
                      ui.submit_button(button.Outline, [], [
                        text("Reset to the default"),
                      ]),
                    ],
                  ),
                ])
              _, _ -> element.none()
            },
          ]),
        ],
      )
    }
  }
}

fn kill_card(action: fn(String) -> String, setting: Setting) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("Kill switch")]),
      ui.card_description([
        text(case setting.killed {
          True ->
            "On: the flag is off for everyone, whatever the rules and rollout say."
          False ->
            "Off. Turning it on switches the flag off for everyone at once and pauses any ramp."
        }),
      ]),
    ]),
    ui.card_content([], [
      html.form(
        [
          attribute.method("post"),
          attribute.action(
            action(case setting.killed {
              True -> "revive"
              False -> "kill"
            }),
          ),
        ],
        [
          case setting.killed {
            True ->
              ui.submit_button(button.Primary, [], [text("Revive the flag")])
            False ->
              ui.submit_button(button.Danger, [], [text("Kill the flag")])
          },
        ],
      ),
    ]),
  ])
}

fn rules_card(
  config: Config,
  action: fn(String) -> String,
  setting: Setting,
  writable: Bool,
) -> Element(msg) {
  let rules =
    list.append(
      list.map(setting.blocked, fn(target) { #(target, "blocked") }),
      list.map(setting.allowed, fn(target) { #(target, "allowed") }),
    )
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("Users, organizations and groups")]),
      ui.card_description([
        text(
          "Allowed targets get the flag whatever the rollout; blocked ones never do. Blocks win over allows; the kill switch wins over both.",
        ),
      ]),
    ]),
    ui.card_content([], [
      ui.stack([], [
        case rules {
          [] -> ui.p([ui.muted("No rules.")])
          _ ->
            ui.table([], [
              ui.table_body(
                [],
                list.map(rules, fn(rule) {
                  ui.table_row([], [
                    ui.table_cell([], [pieces.target_view(config, rule.0)]),
                    ui.table_cell([], [
                      ui.badge(
                        case rule.1 {
                          "blocked" -> badge.Danger
                          _ -> badge.Secondary
                        },
                        [],
                        [text(rule.1)],
                      ),
                    ]),
                    ui.table_cell([], [
                      case writable {
                        False -> element.none()
                        True ->
                          html.form(
                            [
                              attribute.method("post"),
                              attribute.action(action("unlist")),
                            ],
                            [
                              html.input([
                                attribute.type_("hidden"),
                                attribute.name("target"),
                                attribute.value(flags.target_to_string(rule.0)),
                              ]),
                              ui.sized_button(
                                button.Ghost,
                                button.Small,
                                [attribute.type_("submit")],
                                [text("Remove")],
                              ),
                            ],
                          )
                      },
                    ]),
                  ])
                }),
              ),
            ])
        },
        case writable {
          False -> element.none()
          True ->
            html.form(
              [attribute.method("post"), attribute.action(action("allow"))],
              [
                ui.row(
                  [],
                  list.append(pieces.target_inputs(config, "rule"), [
                    ui.submit_button(button.Secondary, [], [text("Allow")]),
                    ui.submit_button(
                      button.Outline,
                      [attribute.formaction(action("block"))],
                      [text("Block")],
                    ),
                  ]),
                ),
              ],
            )
        },
      ]),
    ]),
  ])
}

/// Who gets the flag, and why, for any user and organization.
fn check_card(
  config: Config,
  ctx: Context,
  features: Flags,
  flag: flags.Flag,
  here: String,
) -> Element(msg) {
  let query = request.get_query(ctx.request) |> result.unwrap([])
  let asked = fn(name) {
    list.key_find(query, name) |> result.unwrap("") |> string.trim
  }
  let user = asked("user")
  let organization = asked("org")
  let answer = case user, organization {
    "", "" -> element.none()
    _, _ -> {
      let user = case config.identity, string.contains(user, "@") {
        Some(identity), True ->
          users.list(identity)
          |> result.unwrap([])
          |> list.find(fn(found) { found.email == user })
          |> result.map(fn(found) { found.id })
          |> result.unwrap(user)
        _, _ -> user
      }
      let who = case user {
        "" -> flags.anonymous()
        id -> flags.user(id)
      }
      let who = case organization {
        "" -> who
        id -> flags.in_organization(who, id)
      }
      let decision = flags.explain(features, flag, for: who)
      ui.p([
        case flags.is_on(decision) {
          True -> ui.badge(badge.Primary, [], [text("on")])
          False -> ui.badge(badge.Outline, [], [text("off")])
        },
        text(" " <> explanation(decision)),
      ])
    }
  }
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("Check")]),
      ui.card_description([
        text("Whether someone gets the flag, and which rule decides it."),
      ]),
    ]),
    ui.card_content([], [
      ui.stack([], [
        html.form([attribute.method("get"), attribute.action(here)], [
          html.input([
            attribute.type_("hidden"),
            attribute.name("key"),
            attribute.value(flags.key(flag)),
          ]),
          ui.row([], [
            ui.input([
              attribute.name("user"),
              attribute.value(user),
              attribute.placeholder(case config.identity {
                Some(_) -> "user id or email"
                None -> "user id"
              }),
              attribute.attribute("aria-label", "User"),
            ]),
            ui.input([
              attribute.name("org"),
              attribute.value(organization),
              attribute.placeholder("organization id"),
              attribute.attribute("aria-label", "Organization"),
            ]),
            ui.submit_button(button.Secondary, [], [text("Check")]),
          ]),
        ]),
        answer,
      ]),
    ]),
  ])
}

fn explanation(decision: flags.Decision) -> String {
  case decision {
    flags.Default(on:) ->
      "Nothing is stored, so the default applies: "
      <> case on {
        True -> "on."
        False -> "off."
      }
    flags.Killed -> "The kill switch is on."
    flags.Blocked(target) ->
      "Blocked for " <> flags.target_to_string(target) <> "."
    flags.Allowed(target) ->
      "Allowed for " <> flags.target_to_string(target) <> "."
    flags.InRollout(position:, rollout:) ->
      "Their position "
      <> flags.percent_to_string(position)
      <> " is below the rollout of "
      <> flags.percent_to_string(rollout)
      <> "."
    flags.OutsideRollout(position:, rollout:) ->
      "Their position "
      <> flags.percent_to_string(position)
      <> " is outside the rollout of "
      <> flags.percent_to_string(rollout)
      <> "; they get it once the rollout passes it."
    flags.NoPosition(flags.ByUser) ->
      "No user was given and the rollout is by user, so only 100% includes them."
    flags.NoPosition(flags.ByOrganization) ->
      "No organization was given and the rollout is by organization, so only 100% includes them."
  }
}

fn history_table(
  config: Config,
  changes: List(flags.Change),
  with_flag: Bool,
  writable: Bool,
) -> Element(msg) {
  case changes {
    [] -> ui.p([ui.muted("No changes yet.")])
    _ ->
      ui.table([], [
        ui.table_header([], [
          ui.table_row([], [
            ui.table_head([], [text("When")]),
            case with_flag {
              True -> ui.table_head([], [text("Flag")])
              False -> element.none()
            },
            ui.table_head([], [text("Change")]),
            ui.table_head([], [text("By")]),
            ui.table_head([], []),
          ]),
        ]),
        ui.table_body(
          [],
          list.map(changes, fn(change) {
            ui.table_row([], [
              ui.table_cell([], [ui.muted(format.at_seconds(change.at))]),
              case with_flag {
                True ->
                  ui.table_cell([], [
                    case change.flag {
                      Some(key) ->
                        ui.link(pieces.flag_path(config, key), [
                          html.code([], [text(key)]),
                        ])
                      None -> ui.muted("groups")
                    },
                  ])
                False -> element.none()
              },
              ui.table_cell([], [text(change.summary)]),
              ui.table_cell([], [text(change.by)]),
              ui.table_cell([], [
                case change.flag, writable {
                  Some(key), True ->
                    html.form(
                      [
                        attribute.method("post"),
                        attribute.action(
                          config.path(config, "/flags/flag/undo?")
                          <> uri.query_to_string([#("key", key)]),
                        ),
                      ],
                      [
                        html.input([
                          attribute.type_("hidden"),
                          attribute.name("change"),
                          attribute.value(int.to_string(change.id)),
                        ]),
                        ui.sized_button(
                          button.Ghost,
                          button.Small,
                          [
                            attribute.type_("submit"),
                            attribute.title(
                              "Put the flag back as it was before this change",
                            ),
                          ],
                          [text("Undo")],
                        ),
                      ],
                    )
                  _, _ -> element.none()
                },
              ]),
            ])
          }),
        ),
      ])
  }
}

fn state_badges(entry: Entry) -> List(Element(msg)) {
  case entry.setting, entry.flag {
    None, Some(flag) -> [
      ui.badge(badge.Outline, [], [
        text(case flags.default(flag) {
          True -> "default on"
          False -> "default off"
        }),
      ]),
    ]
    None, None -> []
    Some(setting), _ ->
      list.flatten([
        case setting.killed {
          True -> [ui.badge(badge.Danger, [], [text("killed")])]
          False -> []
        },
        [
          ui.badge(
            case setting.rollout {
              0 -> badge.Outline
              10_000 -> badge.Primary
              _ -> badge.Secondary
            },
            [],
            [text(flags.percent_to_string(setting.rollout))],
          ),
        ],
        case setting.ramp {
          Some(flags.Ramp(next: Some(_), ..)) -> [
            ui.badge(badge.Secondary, [], [text("ramping")]),
          ]
          Some(flags.Ramp(next: None, ..)) -> [
            ui.badge(badge.Outline, [], [text("ramp paused")]),
          ]
          None -> []
        },
        case setting.bucketing {
          flags.ByOrganization -> [
            ui.badge(badge.Outline, [], [text("by organization")]),
          ]
          flags.ByUser -> []
        },
      ])
  }
}

fn rule_count(setting: Option(Setting)) -> String {
  case setting {
    None -> ""
    Some(setting) ->
      case list.length(setting.allowed), list.length(setting.blocked) {
        0, 0 -> ""
        allowed, 0 -> int.to_string(allowed) <> " allowed"
        0, blocked -> int.to_string(blocked) <> " blocked"
        allowed, blocked ->
          int.to_string(allowed)
          <> " allowed, "
          <> int.to_string(blocked)
          <> " blocked"
      }
  }
}
