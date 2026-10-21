import gleam/list
import gleam/option.{None, Some}
import gleam/string
import howdy/ui/calendar.{Date}
import howdy/ui/carousel
import howdy/ui/chart
import howdy/ui/command
import howdy/ui/direction
import howdy/ui/drawer
import howdy/ui/menu
import howdy/ui/questionnaire
import howdy/ui/resizable
import howdy/ui/slider
import howdy/ui/toast
import howdy/ui/words
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

fn render(element: Element(msg)) -> String {
  element.to_string(element)
}

// -- Questionnaire -------------------------------------------------------------

fn questions() -> List(questionnaire.Question) {
  [
    questionnaire.question(
      "role",
      "What do you do?",
      questionnaire.Single([#("dev", "Build"), #("design", "Design")]),
    )
      |> questionnaire.required,
    questionnaire.question(
      "tools",
      "Which do you use?",
      questionnaire.Several([#("gleam", "Gleam"), #("erlang", "Erlang")]),
    ),
    questionnaire.question("age", "How old are you?", questionnaire.Short)
      |> questionnaire.check(fn(values) {
        case values {
          ["1" <> _] -> Ok(Nil)
          _ -> Error("Enter a number from 10 to 19.")
        }
      }),
  ]
}

pub fn questionnaire_starts_at_the_first_question_test() {
  let state = questionnaire.start(questions())
  assert questionnaire.progress(state) == #(1, 3)
  assert !questionnaire.is_complete(state)
  let html = render(questionnaire.view(words.english(), state, []))
  assert string.contains(html, "What do you do?")
  assert string.contains(html, "value=\"next\"")
  // The first question is required and first: no skip, no back.
  assert !string.contains(html, "value=\"skip\"")
  assert !string.contains(html, "value=\"back\"")
}

pub fn a_required_question_must_be_answered_test() {
  let state =
    questionnaire.submit(questions(), [
      #("questionnaire-step", "0"),
      #("questionnaire-action", "next"),
    ])
  assert questionnaire.progress(state) == #(1, 3)
  let html = render(questionnaire.view(words.english(), state, []))
  assert string.contains(html, "Answer this to go on.")
  assert string.contains(html, "aria-invalid=\"true\"")
}

pub fn answers_are_carried_through_the_form_test() {
  let second =
    questionnaire.submit(questions(), [
      #("questionnaire-step", "0"),
      #("role", "dev"),
      #("questionnaire-action", "next"),
    ])
  assert questionnaire.progress(second) == #(2, 3)
  let html = render(questionnaire.view(words.english(), second, []))
  assert string.contains(html, "name=\"questionnaire-answer:role\"")
  assert string.contains(html, "value=\"skip\"")

  let third =
    questionnaire.submit(questions(), [
      #("questionnaire-step", "1"),
      #("questionnaire-answer:role", "dev"),
      #("tools", "gleam"),
      #("tools", "erlang"),
      #("questionnaire-action", "next"),
    ])
  assert questionnaire.progress(third) == #(3, 3)
  assert string.contains(
    render(questionnaire.view(words.english(), third, [])),
    "Finish",
  )

  let done =
    questionnaire.submit(questions(), [
      #("questionnaire-step", "2"),
      #("questionnaire-answer:role", "dev"),
      #("questionnaire-answer:tools", "gleam"),
      #("questionnaire-answer:tools", "erlang"),
      #("age", "15"),
      #("questionnaire-action", "next"),
    ])
  assert questionnaire.is_complete(done)
  assert questionnaire.answers(done)
    == [
      #("role", ["dev"]),
      #("tools", ["gleam", "erlang"]),
      #("age", ["15"]),
    ]
}

pub fn checks_reject_answers_test() {
  let state =
    questionnaire.submit(questions(), [
      #("questionnaire-step", "2"),
      #("questionnaire-answer:role", "dev"),
      #("age", "40"),
      #("questionnaire-action", "next"),
    ])
  assert !questionnaire.is_complete(state)
  assert string.contains(
    render(questionnaire.view(words.english(), state, [])),
    "Enter a number from 10 to 19.",
  )
}

pub fn skip_clears_and_back_keeps_test() {
  let skipped =
    questionnaire.submit(questions(), [
      #("questionnaire-step", "1"),
      #("questionnaire-answer:role", "dev"),
      #("tools", "gleam"),
      #("questionnaire-action", "skip"),
    ])
  assert questionnaire.progress(skipped) == #(3, 3)
  assert questionnaire.answers(skipped) == [#("role", ["dev"])]

  let back =
    questionnaire.submit(questions(), [
      #("questionnaire-step", "1"),
      #("questionnaire-answer:role", "dev"),
      #("tools", "gleam"),
      #("questionnaire-action", "back"),
    ])
  assert questionnaire.progress(back) == #(1, 3)
  assert questionnaire.answers(back)
    == [#("role", ["dev"]), #("tools", ["gleam"])]
}

pub fn finishing_rechecks_every_answer_test() {
  // The last step posted with a good answer, but the required first
  // question's answer left out of the carried fields.
  let state =
    questionnaire.submit(questions(), [
      #("questionnaire-step", "2"),
      #("age", "15"),
      #("questionnaire-action", "next"),
    ])
  assert !questionnaire.is_complete(state)
  assert questionnaire.progress(state) == #(1, 3)
  assert string.contains(
    render(questionnaire.view(words.english(), state, [])),
    "Answer this to go on.",
  )
}

pub fn answers_must_be_among_the_options_test() {
  let state =
    questionnaire.submit(questions(), [
      #("questionnaire-step", "0"),
      #("role", "astronaut"),
      #("questionnaire-action", "next"),
    ])
  assert questionnaire.progress(state) == #(1, 3)
  // A changed carried answer is caught at the end too.
  let state =
    questionnaire.submit(questions(), [
      #("questionnaire-step", "2"),
      #("questionnaire-answer:role", "dev"),
      #("questionnaire-answer:tools", "cobol"),
      #("age", "15"),
      #("questionnaire-action", "next"),
    ])
  assert !questionnaire.is_complete(state)
  assert questionnaire.progress(state) == #(2, 3)
  let scale = [
    questionnaire.question(
      "score",
      "Score?",
      questionnaire.Scale(from: 0, to: 5, low: "", high: ""),
    ),
  ]
  let out_of_range =
    questionnaire.submit(scale, [
      #("questionnaire-step", "0"),
      #("score", "9"),
      #("questionnaire-action", "next"),
    ])
  assert !questionnaire.is_complete(out_of_range)
  let in_range =
    questionnaire.submit(scale, [
      #("questionnaire-step", "0"),
      #("score", "5"),
      #("questionnaire-action", "next"),
    ])
  assert questionnaire.is_complete(in_range)
}

pub fn required_questions_cannot_be_skipped_test() {
  let state =
    questionnaire.submit(questions(), [
      #("questionnaire-step", "0"),
      #("questionnaire-action", "skip"),
    ])
  assert questionnaire.progress(state) == #(1, 3)
}

// -- Toast queue ---------------------------------------------------------------

pub fn toast_queue_updates_and_expires_test() {
  let #(queue, saving) =
    toast.push(toast.queue(), toast.Loading, "Saving…", "", 0)
  let #(queue, other) = toast.push(queue, toast.Info, "Hello", "", 0)
  assert saving != other
  // The browser closes a faded toast; expire only sweeps up a minute later.
  assert list.length(toast.items(toast.expire(queue, 60_000))) == 2
  let later = toast.expire(queue, 65_001)
  assert list.map(toast.items(later), fn(item) { item.id }) == [saving]

  let queue = toast.update(later, saving, toast.Success, "Saved", "", 70_000)
  let assert [item] = toast.items(queue)
  assert item.variant == toast.Success
  assert item.title == "Saved"
  assert item.round == 1
  assert toast.items(toast.expire(queue, 71_000)) != []
  assert toast.items(toast.expire(queue, 140_000)) == []
  assert toast.items(toast.dismiss(queue, saving)) == []
}

pub fn toasts_held_open_are_not_expired_test() {
  let #(queue, id) = toast.push(toast.queue(), toast.Info, "Read me", "", 0)
  // Held from 1s to 101s: 100 seconds that do not count.
  let queue = toast.hold(queue, id, True, 1000)
  assert toast.items(toast.expire(queue, 90_000)) != []
  let queue = toast.hold(queue, id, False, 101_000)
  let assert [item] = toast.items(queue)
  assert item.held_for == 100_000
  // 5s countdown and a minute's grace, from 101s less the time held.
  assert toast.items(toast.expire(queue, 164_999)) != []
  assert toast.items(toast.expire(queue, 165_000)) == []
  // Holding twice, or letting go of one not held, changes nothing.
  assert toast.hold(queue, id, False, 200_000) == queue
  let held = toast.hold(queue, id, True, 110_000)
  assert toast.hold(held, id, True, 120_000) == held
}

pub fn updating_a_held_toast_keeps_it_held_test() {
  let #(queue, id) = toast.push(toast.queue(), toast.Info, "One", "", 0)
  let queue = toast.hold(queue, id, True, 1000)
  let queue = toast.update(queue, id, toast.Success, "Two", "", 50_000)
  assert toast.items(toast.expire(queue, 1_000_000)) != []
  let queue = toast.hold(queue, id, False, 60_000)
  // Held from the update at 50s until 60s; counts from there.
  assert toast.items(toast.expire(queue, 124_999)) != []
  assert toast.items(toast.expire(queue, 125_000)) == []
}

pub fn updating_a_toast_restarts_its_countdown_test() {
  let #(queue, id) = toast.push(toast.queue(), toast.Success, "One", "", 0)
  let first =
    render(
      toast.view(
        words.english(),
        queue,
        on_close: fn(_) { [] },
        on_hold: fn(_, _) { Nil },
      ),
    )
  assert !string.contains(first, "data-round=\"odd\"")
  // Faded toasts close themselves through their close button, and hover
  // or focus holds them: both are wired by the behaviour script off the
  // queue's marker rather than inline handlers.
  assert string.contains(first, "data-howdy-toast-queue")
  assert !string.contains(first, "onanimationend")
  assert !string.contains(first, "onfocusin")
  let queue = toast.update(queue, id, toast.Success, "Two", "", 10)
  let second =
    render(
      toast.view(
        words.english(),
        queue,
        on_close: fn(_) { [] },
        on_hold: fn(_, _) { Nil },
      ),
    )
  assert string.contains(second, "data-round=\"odd\"")
}

// -- Calendar values -----------------------------------------------------------

pub fn calendar_values_round_trip_test() {
  assert calendar.selection_to_value(calendar.Single(Some(Date(2026, 9, 4))))
    == "2026-09-04"
  assert calendar.selection_to_value(calendar.Range(
      from: Some(Date(2026, 9, 4)),
      to: Some(Date(2026, 9, 10)),
    ))
    == "2026-09-04/2026-09-10"
  assert calendar.range_from_value("2026-09-04/2026-09-10")
    == Ok(#(Date(2026, 9, 4), Some(Date(2026, 9, 10))))
  assert calendar.range_from_value("2026-09-04/")
    == Ok(#(Date(2026, 9, 4), None))
  assert calendar.range_from_value("nonsense") == Error(Nil)
  assert calendar.dates_from_value("2026-09-04,2026-09-06,bad")
    == [Date(2026, 9, 4), Date(2026, 9, 6)]
}

pub fn a_range_calendar_marks_the_days_between_test() {
  let html =
    calendar.new("stay", year: 2026, month: 9)
    |> calendar.range(
      from: Some(Date(2026, 9, 21)),
      to: Some(Date(2026, 10, 2)),
    )
    |> calendar.months(2)
    |> calendar.name("stay")
    |> calendar.view
    |> render
  assert string.contains(html, "data-mode=\"range\"")
  assert string.contains(html, "data-in-range")
  assert string.contains(html, "2026-09-21/2026-10-02")
}

// -- Smaller pieces ------------------------------------------------------------

pub fn resizable_sizes_come_back_from_the_cookie_test() {
  assert resizable.sizes_from_cookie("30_70", default: [50, 50]) == [30, 70]
  assert resizable.sizes_from_cookie("30", default: [50, 50]) == [50, 50]
  assert resizable.sizes_from_cookie("", default: [50, 50]) == [50, 50]
}

pub fn polar_charts_draw_test() {
  let donut =
    chart.donut(title: "Traffic", labels: ["A", "B"], values: [3.0, 1.0])
    |> chart.view
    |> render
  assert string.contains(donut, "75%")
  let radar =
    chart.radar(title: "Skills", axes: ["A", "B", "C"], series: [
      chart.Series("Now", [1.0, 2.0, 3.0]),
    ])
    |> chart.view
    |> render
  assert string.contains(radar, "<polygon")
}

pub fn direction_sets_dir_test() {
  assert string.contains(
    render(direction.provider(direction.Rtl, [], [text("مرحبا")])),
    "dir=\"rtl\"",
  )
}

pub fn drawers_are_modal_dialogs_with_a_handle_test() {
  let html =
    render(
      drawer.drawer(
        words.english(),
        "filters",
        [drawer.snap_points([40, 90])],
        [],
      ),
    )
  assert string.contains(html, "<dialog")
  assert string.contains(html, "data-snaps=\"40,90\"")
  assert string.contains(html, "data-howdy-drawer-handle")
}

pub fn menus_have_radio_items_and_submenus_test() {
  let html =
    render(
      html.div([], [
        menu.radio_group("Sort", [menu.radio_item(True, [], [text("New")])]),
        menu.submenu("share", label: [text("Share")], items: [
          menu.item([], [text("Copy")]),
        ]),
      ]),
    )
  assert string.contains(html, "role=\"menuitemradio\"")
  assert string.contains(html, "aria-checked=\"true\"")
  assert string.contains(html, "popovertarget=\"share\"")
}

pub fn range_sliders_submit_two_values_test() {
  let html =
    render(
      slider.range(
        words: words.english(),
        label: "Price",
        min: 0,
        max: 100,
        low: 20,
        high: 80,
        low_name: "min",
        high_name: "max",
        attributes: [attribute.id("price")],
      ),
    )
  assert string.contains(html, "name=\"min\"")
  assert string.contains(html, "name=\"max\"")
}

// -- Multiple combobox, sliders, carousels -----------------------------------------

pub fn multiple_combobox_sends_a_field_per_value_test() {
  let html =
    render(
      command.multiple_combobox(
        words: words.english(),
        id: "tags",
        name: "tags",
        values: ["a, b"],
        placeholder: "Add tags",
        search: "Search",
        attributes: [],
        options: [#("a, b", "A and B"), #("c", "C")],
      ),
    )
  // The chosen value, commas and all, in an enabled field; the other
  // disabled, so a form leaves it out.
  assert string.contains(
    html,
    "data-howdy-choice name=\"tags\" type=\"hidden\" value=\"a, b\"",
  )
  assert string.contains(
    html,
    "data-howdy-choice disabled name=\"tags\" type=\"hidden\" value=\"c\"",
  )
  assert string.contains(html, "aria-label=\"Remove A and B\"")
  assert string.contains(html, "data-name=\"tags\"")
}

pub fn slider_thumbs_stay_in_order_test() {
  let html =
    render(
      slider.thumbs(
        words: words.english(),
        label: "Day",
        min: 0,
        max: 24,
        orientation: slider.Vertical,
        values: [#("a", 10), #("b", 5), #("c", 30)],
        attributes: [],
      ),
    )
  assert string.contains(html, "aria-label=\"Day, 2 of 3\"")
  assert string.contains(html, "name=\"b\" type=\"range\" value=\"10\"")
  assert string.contains(html, "name=\"c\" type=\"range\" value=\"24\"")
  assert string.contains(html, "aria-orientation=\"vertical\"")
}

pub fn carousels_can_play_by_themselves_test() {
  let html =
    render(
      carousel.carousel(
        words.english(),
        "tour",
        label: "Tour",
        attributes: [carousel.autoplay(200)],
        slides: [carousel.slide([text("One")])],
      ),
    )
  // Never faster than a second.
  assert string.contains(html, "data-autoplay=\"1000\"")
  assert string.contains(html, "aria-label=\"Pause slides\"")
}
