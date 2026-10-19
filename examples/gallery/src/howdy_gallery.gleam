//// A gallery of howdy_ui: a dashboard with charts and a live orders table,
//// a live chat, a page of components, sign-in and sign-up screens, and the
//// howdy_ui reference at `/ui`. Run with `gleam run` from
//// `examples/gallery`; it listens on 127.0.0.1:8791. Open
//// http://localhost:8791.
////
//// The screens use howdy_ui's blocks: the application shell, stat cards,
//// and the sign-in and sign-up cards. `gleam run -m howdy/ui add sign_up`
//// copies one into a project, with the components it uses.

import gleam/erlang/process
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import gleam/uri
import howdy
import howdy/controller.{type Context}
import howdy/cookie
import howdy/form
import howdy/i18n
import howdy/query
import howdy/storage/local
import howdy/ui
import howdy/ui/blocks/app_shell.{Group, Link}
import howdy/ui/blocks/sign_in
import howdy/ui/blocks/sign_up
import howdy/ui/blocks/stat_card
import howdy/ui/button.{Primary}
import howdy/ui/calendar.{type Date, Date}
import howdy/ui/chart
import howdy/ui/command
import howdy/ui/data_table.{Ascending, Descending, Links, Sort}
import howdy/ui/direction
import howdy/ui/gallery
import howdy/ui/live
import howdy/ui/page
import howdy/ui/questionnaire
import howdy/ui/toast
import howdy/ui/words
import howdy/validate
import howdy_gallery/chat
import howdy_gallery/lab
import howdy_gallery/orders
import howdy_gallery/uploads
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

pub fn main() -> Nil {
  // Supervised inside an OTP application: restarted on a crash, drained on
  // SIGTERM. A local demo, so it listens on 127.0.0.1:8791 only.
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(howdy.supervised(
      app() |> howdy.bind(to: "127.0.0.1") |> howdy.listening(on: 8791),
    ))
    |> howdy.start_application(name: "howdy_gallery_server")

  process.sleep_forever()
}

pub fn app() -> howdy.App {
  howdy.new()
  |> howdy.controller(
    controller.new("/")
    |> controller.get("/", dashboard)
    |> controller.get("/components", components)
    |> controller.get("/chat", fn(ctx) {
      use page <- shell(ctx, "Chat", "/chat", [live.mount("/live/chat")])
      page.live(page)
    })
    |> controller.get("/lab", fn(ctx) {
      use page <- shell(ctx, "Lab", "/lab", [live.mount("/live/lab")])
      page.live(page)
    })
    // A questionnaire as a plain form, posted back to itself.
    |> controller.get("/survey", fn(ctx) {
      survey_page(ctx, questionnaire.start(lab.questions()))
    })
    |> controller.post("/survey", fn(ctx) {
      use fields <- form.read(ctx)
      survey_page(
        ctx,
        questionnaire.submit(lab.questions(), form.fields(fields)),
      )
    })
    |> controller.get("/sign-in", fn(ctx) {
      auth_page(
        ctx,
        "Sign in",
        sign_in.sign_in(
          action: "/sign-in",
          email: "",
          error: None,
          sign_up: "/sign-up",
          forgot: "/sign-in",
        ),
      )
    })
    |> controller.post("/sign-in", fn(ctx) {
      use fields <- form.read(ctx)
      see_other(
        ctx,
        "/?welcome=" <> uri.percent_encode(form.value(fields, "email")),
      )
    })
    |> controller.get("/sign-up", fn(ctx) {
      auth_page(
        ctx,
        "Sign up",
        sign_up.sign_up(
          action: "/sign-up",
          form: sign_up.empty(),
          errors: [],
          sign_in: "/sign-in",
        ),
      )
    })
    |> controller.post("/sign-up", sign_up)
    // Where the uploader examples in the reference send files.
    |> controller.post("/uploads/start", uploads.start)
    |> controller.post("/uploads", fn(ctx) {
      use fields <- form.read(ctx)
      use page <- shell(ctx, "Uploads", "/uploads", [
        ui.h2("Received"),
        html.output([attribute.id("uploaded-keys")], [
          text(uploads.check(fields, "document")),
        ]),
      ])
      page
    }),
  )
  |> howdy.controller(local.controller(uploads.config()))
  // The howdy_ui reference, for development.
  |> howdy.controller(gallery.controller(at: "/ui"))
  |> howdy.controller(
    controller.new("/live")
    |> controller.get("/orders", fn(ctx) {
      live.serve(ctx, orders.app(today()), with: Nil)
    })
    |> controller.get("/chat", fn(ctx) {
      live.serve(ctx, chat.app(), with: Nil)
    })
    |> controller.get("/lab", fn(ctx) { live.serve(ctx, lab.app(), with: Nil) }),
  )
}

// -- Pages -------------------------------------------------------------------

fn survey_page(ctx: Context, asked: questionnaire.Questionnaire) {
  let content = case questionnaire.is_complete(asked) {
    True -> [
      ui.h2("Thank you"),
      html.output([attribute.id("survey-answers")], [
        text(
          questionnaire.answers(asked)
          |> list.map(fn(pair) { pair.0 <> "=" <> string.join(pair.1, ",") })
          |> string.join(" "),
        ),
      ]),
    ]
    False -> [
      questionnaire.view(words.english(), asked, [
        attribute.method("post"),
        attribute.action("/survey"),
      ]),
    ]
  }
  use page <- shell(ctx, "Survey", "/survey", content)
  page
}

fn shell(
  ctx: Context,
  title: String,
  active: String,
  content: List(Element(msg)),
  next: fn(page.Page(msg)) -> page.Page(msg),
) {
  use theme <- cookie.string_or(ctx, "theme", default: "system")
  use sidebar <- cookie.string_or(ctx, "sidebar", default: "expanded")
  page.new(title <> " · Howdy gallery")
  |> page.theme(theme)
  |> page.head([html.style([], gallery_css)])
  |> page.body([
    app_shell.app_shell(
      app: "Howdy gallery",
      collapsed: sidebar == "collapsed",
      current: active,
      navigation: [
        Group("App", [
          Link("/", "Dashboard"),
          Link("/chat", "Chat"),
          Link("/components", "Components"),
          Link("/ui", "howdy_ui reference"),
        ]),
        Group("Account", [
          Link("/sign-in", "Sign in"),
          Link("/sign-up", "Sign up"),
        ]),
      ],
      footer: [ui.muted("ada@example.com")],
      heading: title,
      actions: [
        ui.button(
          button.Outline,
          [
            attribute.aria_keyshortcuts("Meta+K Control+K"),
            ..ui.dialog_trigger("search")
          ],
          [text("Search"), html.kbd([], [text("⌘K")])],
        ),
        ui.theme_toggle([text("Theme")], from: "light", to: "dark"),
      ],
      content: list.append(content, [search()]),
    ),
  ])
  |> next
  |> page.respond(ctx)
}

fn dashboard(ctx: Context) {
  use welcome <- query.string_or(ctx, "welcome", default: "")
  let greeting = case welcome {
    "" -> []
    who -> [
      toast.toast(toast.Info, [], [
        toast.title([text("Welcome back")]),
        toast.description([text("Signed in as " <> who <> ".")]),
        toast.close([attribute.aria_label("Dismiss")]),
      ]),
    ]
  }
  let months = ["Apr", "May", "Jun", "Jul", "Aug", "Sep"]
  let content = [
    html.div([attribute.class("gallery-stats")], [
      stat_card.stat_card(
        label: "Revenue",
        value: "$48,210",
        change: "+12% on last month",
      ),
      stat_card.stat_card(
        label: "Orders",
        value: "1,284",
        change: "+4% on last month",
      ),
      stat_card.stat_card(
        label: "Refund rate",
        value: "1.8%",
        change: "−0.3 points on last month",
      ),
    ]),
    html.div([attribute.class("gallery-charts")], [
      ui.card([], [
        ui.card_header([], [
          ui.card_title([html.h2([], [text("Revenue by channel")])]),
          ui.card_description([text("Last six months, in dollars")]),
        ]),
        chart.bar(title: "Revenue by channel", labels: months, series: [
          chart.Series("Online", [
            4200.0,
            5100.0,
            6100.0,
            5800.0,
            7200.0,
            8100.0,
          ]),
          chart.Series("In store", [
            3100.0,
            2900.0,
            3300.0,
            3500.0,
            3200.0,
            3900.0,
          ]),
        ])
          |> chart.view,
      ]),
      ui.card([], [
        ui.card_header([], [
          ui.card_title([html.h2([], [text("Visitors")])]),
          ui.card_description([text("Last six months, in thousands")]),
        ]),
        chart.area(title: "Visitors", labels: months, series: [
          chart.Series("Desktop", [18.2, 21.5, 19.8, 24.1, 26.3, 29.0]),
          chart.Series("Mobile", [9.1, 10.4, 12.8, 13.1, 15.9, 17.2]),
        ])
          |> chart.view,
      ]),
    ]),
    live.mount("/live/orders"),
    ui.toast_region(words.english(), [], greeting),
  ]
  use page <- shell(ctx, "Dashboard", "/", content)
  page.live(page)
}

fn components(ctx: Context) {
  use sort_column <- query.string_or(ctx, "sort", default: "")
  use sort_direction <- query.string_or(ctx, "dir", default: "asc")
  use page_number <- query.int_or(ctx, "page", default: 3)
  use day <- query.string_or(ctx, "day", default: "")
  use lang <- query.string_or(ctx, "lang", default: "en")
  // `?lang=de` shows the components that speak in another language.
  let w = case lang {
    "en" -> words.english()
    _ -> words.translated(i18n.new(lang))
  }
  let now = today()
  let sort = case sort_column {
    "" -> None
    column ->
      Some(
        Sort(column:, direction: case sort_direction {
          "desc" -> Descending
          _ -> Ascending
        }),
      )
  }
  let sort_href = fn(sort: data_table.Sort) {
    "/components?lang="
    <> lang
    <> "&sort="
    <> sort.column
    <> "&dir="
    <> case sort.direction {
      Ascending -> "asc"
      Descending -> "desc"
    }
  }
  let chosen = calendar.from_iso(day)
  let languages =
    list.map(["en", ..list.filter(words.locales(), fn(l) { l != "en" })], fn(l) {
      let name = i18n.language_name(l) |> result.unwrap(l)
      case l == lang {
        True -> html.strong([attribute.lang(l)], [text(name)])
        False ->
          html.a([attribute.href("/components?lang=" <> l), attribute.lang(l)], [
            text(name),
          ])
      }
    })
  let content = [
    ui.direction(direction.of_tag(w.locale), [attribute.lang(w.locale)], [
      ui.stack([attribute.style("gap", "1.5rem")], [
        section("Language", [
          ui.muted(
            "The chart, data table, pagination, calendar and toast below speak the chosen language.",
          ),
          ui.row([attribute.style("flex-wrap", "wrap")], languages),
        ]),
        section("Line chart", [
          chart.line(
            title: "Response time by region, milliseconds",
            labels: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
            series: [
              chart.Series("Europe", [
                120.0,
                132.0,
                101.0,
                134.0,
                90.0,
                230.0,
                210.0,
              ]),
              chart.Series("Americas", [
                220.0,
                182.0,
                191.0,
                234.0,
                290.0,
                330.0,
                310.0,
              ]),
              chart.Series("Asia", [
                150.0,
                232.0,
                201.0,
                154.0,
                190.0,
                330.0,
                410.0,
              ]),
            ],
          )
          |> chart.words(w)
          |> chart.view,
        ]),
        section("Data table, sorted with links", [
          data_table.new(
            [
              data_table.column("name", "Name", fn(row: #(String, Int)) {
                text(row.0)
              })
                |> data_table.sortable(fn(a: #(String, Int), b: #(String, Int)) {
                  string.compare(a.0, b.0)
                }),
              data_table.column("seats", "Seats", fn(row: #(String, Int)) {
                text(int.to_string(row.1))
              })
                |> data_table.sortable(fn(a: #(String, Int), b: #(String, Int)) {
                  int.compare(a.1, b.1)
                })
                |> data_table.numeric,
            ],
            [
              #("Acme", 12),
              #("Globex", 48),
              #("Initech", 7),
              #("Umbrella", 150),
            ],
          )
          |> data_table.sort(sort, by: Links(sort_href))
          |> data_table.caption([text("Customers by seats")])
          |> data_table.words(w)
          |> data_table.view,
        ]),
        section("Pagination", [
          ui.pagination(w, current: page_number, total: 12, href: fn(n) {
            "/components?lang=" <> lang <> "&page=" <> int.to_string(n)
          }),
        ]),
        section("Calendar in a form", [
          html.form([attribute.action("/components")], [
            html.input([
              attribute.type_("hidden"),
              attribute.name("lang"),
              attribute.value(lang),
            ]),
            ui.stack([], [
              calendar.new("day", year: now.year, month: now.month)
                |> calendar.locale(w.calendar)
                |> calendar.today(now)
                |> calendar.selected(option.from_result(chosen))
                |> calendar.name("day")
                |> calendar.view,
              ui.row([], [
                ui.submit_button(Primary, [], [text("Choose")]),
                case chosen {
                  Ok(date) ->
                    ui.muted("You chose " <> calendar.long_date(date) <> ".")
                  Error(Nil) -> ui.muted("Pick a day and choose it.")
                },
              ]),
            ]),
          ]),
        ]),
        section("Command menu", [
          html.div([attribute.class("gallery-command")], [
            ui.command(
              "fruit",
              placeholder: "Search fruit…",
              attributes: [],
              children: [
                ui.command_group("Fruit", [
                  ui.command_item([], [text("Apple")]),
                  ui.command_item([], [text("Banana")]),
                  ui.command_item([attribute.aria_disabled(True)], [
                    text("Blueberry"),
                  ]),
                  ui.command_item([], [text("Cherry")]),
                ]),
                ui.command_group("Vegetables", [
                  ui.command_item([], [text("Carrot")]),
                  ui.command_item([], [text("Leek")]),
                ]),
                ui.command_empty([text("Nothing grows by that name.")]),
              ],
            ),
          ]),
        ]),
      ]),
    ]),
    ui.toast_region(w, [], [
      toast.toast(toast.Info, [toast.persistent()], [
        toast.title([text("This one stays")]),
        toast.description([text("Persistent toasts wait to be closed.")]),
        toast.close([attribute.aria_label("Dismiss")]),
      ]),
    ]),
  ]
  use page <- shell(ctx, "Components", "/components", content)
  page
}

/// The ⌘K command menu: every page, searchable.
fn search() -> Element(msg) {
  ui.command_dialog(
    words.english(),
    "search",
    shortcut: "k",
    attributes: [],
    command: ui.command(
      "search-input",
      placeholder: "Search pages…",
      attributes: [],
      children: [
        ui.command_group("Pages", [
          ui.command_link("/", [], [text("Dashboard")]),
          ui.command_link("/chat", [command.keywords("messages bot")], [
            text("Chat"),
          ]),
          ui.command_link("/components", [command.keywords("calendar table")], [
            text("Components"),
          ]),
          ui.command_link("/ui", [command.keywords("reference docs gallery")], [
            text("howdy_ui reference"),
          ]),
        ]),
        ui.command_group("Account", [
          ui.command_link("/sign-in", [command.keywords("log in login")], [
            text("Sign in"),
          ]),
          ui.command_link("/sign-up", [command.keywords("register")], [
            text("Sign up"),
          ]),
        ]),
        ui.command_empty([text("No pages match.")]),
      ],
    ),
  )
}

fn section(title: String, children: List(Element(msg))) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [ui.card_title([html.h2([], [text(title)])])]),
    ..children
  ])
}

fn auth_page(ctx: Context, title: String, card: Element(msg)) {
  use theme <- cookie.string_or(ctx, "theme", default: "system")
  page.new(title <> " · Howdy gallery")
  |> page.theme(theme)
  |> page.body([sign_in.screen(card)])
  |> page.respond(ctx)
}

// -- Sign-up -----------------------------------------------------------------

fn sign_up(ctx: Context) {
  use fields <- form.read(ctx)
  let checked = {
    use name <- form.string(fields, "name", [
      validate.trim(),
      validate.not_empty(),
    ])
    use _email <- form.string(fields, "email", [
      validate.trim(),
      validate.email(),
    ])
    use _password <- form.string(fields, "password", [validate.min_length(8)])
    use _plan <- form.string(fields, "plan", [
      validate.one_of(["free", "team", "business"], fn(plan) { plan }),
    ])
    validate.ok(name)
  }
  let terms = form.all(fields, "terms") != []
  case checked, terms {
    Ok(name), True -> see_other(ctx, "/?welcome=" <> uri.percent_encode(name))
    result, _ -> {
      let errors = case result {
        Ok(_) -> []
        Error(errors) ->
          list.map(errors, fn(error) { #(error.field, message(error.field)) })
      }
      let errors = case terms {
        True -> errors
        False ->
          list.append(errors, [#("terms", "Accept the terms to continue.")])
      }
      auth_page(
        ctx,
        "Sign up",
        sign_up.sign_up(
          action: "/sign-up",
          form: sign_up.Form(
            name: form.value(fields, "name"),
            email: form.value(fields, "email"),
            plan: form.value(fields, "plan"),
            terms:,
          ),
          errors:,
          sign_in: "/sign-in",
        ),
      )
      |> controller.with_status(422)
    }
  }
}

fn message(field: String) -> String {
  case field {
    "name" -> "Enter your name."
    "email" -> "Enter an email address, like ada@example.com."
    "password" -> "Use at least 8 characters."
    "plan" -> "Choose a plan."
    _ -> "Check this field."
  }
}

fn see_other(ctx: Context, location: String) {
  controller.status(ctx, 303)
  |> response.set_header("location", location)
}

// -- Helpers -----------------------------------------------------------------

@external(erlang, "calendar", "local_time")
fn local_time() -> #(#(Int, Int, Int), #(Int, Int, Int))

fn today() -> Date {
  let #(#(year, month, day), _) = local_time()
  Date(year, month, day)
}

/// Layout for the gallery's own pages, around the components.
const gallery_css = "
.gallery-stats { display: grid; gap: 1rem; grid-template-columns: repeat(auto-fit, minmax(14rem, 1fr)); }
.gallery-charts { display: grid; gap: 1rem; grid-template-columns: repeat(auto-fit, minmax(22rem, 1fr)); }
.gallery-filters { display: grid; gap: 1rem; grid-template-columns: repeat(auto-fit, minmax(12rem, 16rem)); }
.gallery-bulk { padding: 0.5rem 0.75rem; border-radius: var(--howdy-radius-medium); background: var(--howdy-muted); }
.gallery-command { max-width: 24rem; border: 1px solid var(--howdy-border); border-radius: var(--howdy-radius-medium); overflow: hidden; }
.gallery-composer { display: flex; gap: 0.5rem; margin-top: 1rem; }
.gallery-chat { max-width: 48rem; }
kbd { font-size: 0.75rem; color: var(--howdy-text-muted); }
h2 { margin: 0; font-size: inherit; }
"
