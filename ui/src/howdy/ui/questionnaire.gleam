//// Questionnaires: questions asked one at a time, with progress, back,
//// skip and next, each answer checked before moving on, and the answers
//// gathered at the end.
////
//// ```gleam
//// let questions = [
////   questionnaire.question("role", "What do you do?", questionnaire.Single([
////     #("dev", "I build software"), #("design", "I design it"), #("other", "Something else"),
////   ]))
////     |> questionnaire.required,
////   questionnaire.question("tools", "Which do you use?", questionnaire.Several([
////     #("gleam", "Gleam"), #("elixir", "Elixir"), #("erlang", "Erlang"),
////   ])),
////   questionnaire.question("score", "How likely are you to recommend us?",
////     questionnaire.Scale(from: 0, to: 10, low: "Not likely", high: "Very likely")),
////   questionnaire.question("more", "Anything else?", questionnaire.Long),
//// ]
////
//// // On a page: show the first question, then handle each post.
//// questionnaire.view(words.english(), questionnaire.start(questions), [attribute.method("post")])
////
//// use fields <- form.read(ctx)
//// let asked = questionnaire.submit(questions, form.fields(fields))
//// case questionnaire.is_complete(asked) {
////   True -> save(questionnaire.answers(asked))
////   False -> render(questionnaire.view(words.english(), asked, [attribute.method("post")]))
//// }
//// ```
////
//// The form carries the answers so far and the current step in hidden
//// fields, so the server keeps nothing between posts. In a live view, pass
//// `event.on_submit(Submitted)` in the attributes and call `submit` with
//// the fields it gives you; the button pressed comes with them.
////
//// Next checks the current answer: a `required` question needs one, a
//// choice must be one of its options and a scale number on the scale, and
//// a `check` can reject it with a message. Past the last question every
//// answer is checked again, since earlier ones came back from the form,
//// and the first that fails is asked again. Back keeps what was typed, and
//// Skip, offered for questions that are not required, clears it.
////
//// `view` takes `words` for its buttons, its progress and the reasons an
//// answer is not accepted; see `howdy/ui/words`. A `check`'s own message
//// is shown as it is.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import howdy/ui/button
import howdy/ui/checkbox
import howdy/ui/field
import howdy/ui/input
import howdy/ui/progress
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import howdy/ui/words.{type Words}
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// How a question is answered.
pub type Kind {
  /// One of these options, as `#(value, label)`.
  Single(options: List(#(String, String)))
  /// Any of these options.
  Several(options: List(#(String, String)))
  /// A line of text.
  Short
  /// A paragraph of text.
  Long
  /// A number on a scale, with words for its ends.
  Scale(from: Int, to: Int, low: String, high: String)
}

pub opaque type Question {
  Question(
    id: String,
    prompt: String,
    help: String,
    kind: Kind,
    required: Bool,
    check: fn(List(String)) -> Result(Nil, String),
  )
}

/// A question, answered in a field named `id`.
pub fn question(id: String, prompt: String, kind: Kind) -> Question {
  Question(id:, prompt:, help: "", kind:, required: False, check: fn(_) {
    Ok(Nil)
  })
}

/// It must be answered; it cannot be skipped.
pub fn required(question: Question) -> Question {
  Question(..question, required: True)
}

/// A line under the question saying more about it.
pub fn help(question: Question, help: String) -> Question {
  Question(..question, help:)
}

/// Check an answer before moving on; an `Error` holds the message to show.
pub fn check(
  question: Question,
  check: fn(List(String)) -> Result(Nil, String),
) -> Question {
  Question(..question, check:)
}

/// Where someone has got to.
pub opaque type Questionnaire {
  Questionnaire(
    questions: List(Question),
    step: Int,
    answers: Dict(String, List(String)),
    error: Option(Trouble),
    complete: Bool,
  )
}

/// Why an answer was not accepted, put into words by `view`.
type Trouble {
  Unanswered
  NotAnOption
  NotFromOptions
  OffScale
  NotOneAnswer
  Rejected(String)
}

/// The first question, with nothing answered.
pub fn start(questions: List(Question)) -> Questionnaire {
  Questionnaire(
    questions:,
    step: 0,
    answers: dict.new(),
    error: None,
    complete: False,
  )
}

const step_field = "questionnaire-step"

const action_field = "questionnaire-action"

const answer_prefix = "questionnaire-answer:"

/// Take a submitted form: restore the answers so far, read the current
/// answer, and go back, skip, or check it and go on, as the button pressed
/// asks.
pub fn submit(
  questions: List(Question),
  fields: List(#(String, String)),
) -> Questionnaire {
  let count = list.length(questions)
  let step =
    list.key_find(fields, step_field)
    |> result.try(int.parse)
    |> result.unwrap(0)
    |> int.clamp(0, int.max(count - 1, 0))
  let current = list.drop(questions, step) |> list.first
  let answers =
    list.fold(fields, dict.new(), fn(answers, pair) {
      case pair.0 {
        "questionnaire-answer:" <> id ->
          dict.upsert(answers, id, fn(values) {
            list.append(option.unwrap(values, []), [pair.1])
          })
        _ -> answers
      }
    })
  let given = case current {
    Ok(question) ->
      fields
      |> list.filter(fn(pair) { pair.0 == question.id })
      |> list.map(fn(pair) { pair.1 })
      |> list.filter(fn(value) { string.trim(value) != "" })
    Error(Nil) -> []
  }
  let answers = case current {
    Ok(question) -> dict.insert(answers, question.id, given)
    Error(Nil) -> answers
  }
  let state =
    Questionnaire(questions:, step:, answers:, error: None, complete: False)
  case list.key_find(fields, action_field), current {
    Ok("back"), _ -> Questionnaire(..state, step: int.max(step - 1, 0))
    Ok("skip"), Ok(question) if !question.required ->
      advance(
        Questionnaire(..state, answers: dict.delete(answers, question.id)),
      )
    _, Ok(question) ->
      case validate(question, given) {
        Ok(Nil) -> advance(state)
        Error(message) -> Questionnaire(..state, error: Some(message))
      }
    _, Error(Nil) -> state
  }
}

/// Whether an answer fits its question: given if required, one of the
/// options or on the scale, and passing the question's own check.
fn validate(question: Question, given: List(String)) -> Result(Nil, Trouble) {
  case question.required, given {
    True, [] -> Error(Unanswered)
    False, [] -> Ok(Nil)
    _, _ -> {
      use _ <- result.try(fits(question.kind, given))
      question.check(given) |> result.map_error(Rejected)
    }
  }
}

fn fits(kind: Kind, given: List(String)) -> Result(Nil, Trouble) {
  let offered = fn(options: List(#(String, String)), value) {
    list.any(options, fn(option) { option.0 == value })
  }
  case kind, given {
    Single(options), [value] ->
      case offered(options, value) {
        True -> Ok(Nil)
        False -> Error(NotAnOption)
      }
    Single(_), _ -> Error(NotAnOption)
    Several(options), values ->
      case list.all(values, offered(options, _)) {
        True -> Ok(Nil)
        False -> Error(NotFromOptions)
      }
    Scale(from:, to:, ..), [value] ->
      case int.parse(value) {
        Ok(n) if n >= from && n <= to -> Ok(Nil)
        _ -> Error(OffScale)
      }
    Scale(..), _ -> Error(OffScale)
    Short, [_] | Long, [_] -> Ok(Nil)
    Short, _ | Long, _ -> Error(NotOneAnswer)
  }
}

/// On past the last question, every answer is checked again, since the
/// earlier ones came back from the form and may have been changed or left
/// out. The first that fails is asked again.
fn advance(state: Questionnaire) -> Questionnaire {
  case state.step + 1 >= list.length(state.questions) {
    False -> Questionnaire(..state, step: state.step + 1)
    True -> {
      let failed =
        state.questions
        |> list.index_map(fn(question, index) {
          let given = dict.get(state.answers, question.id) |> result.unwrap([])
          #(index, validate(question, given))
        })
        |> list.find_map(fn(checked) {
          case checked {
            #(index, Error(message)) -> Ok(#(index, message))
            _ -> Error(Nil)
          }
        })
      case failed {
        Ok(#(step, message)) ->
          Questionnaire(..state, step:, error: Some(message))
        Error(Nil) -> Questionnaire(..state, complete: True)
      }
    }
  }
}

/// Whether the last question has been answered or skipped.
pub fn is_complete(state: Questionnaire) -> Bool {
  state.complete
}

/// Every answer given, in the order the questions were asked. Questions
/// skipped or left empty are left out.
pub fn answers(state: Questionnaire) -> List(#(String, List(String))) {
  list.filter_map(state.questions, fn(question) {
    case dict.get(state.answers, question.id) {
      Ok([_, ..] as values) -> Ok(#(question.id, values))
      _ -> Error(Nil)
    }
  })
}

/// The question being asked, from 1, and how many there are.
pub fn progress(state: Questionnaire) -> #(Int, Int) {
  #(state.step + 1, list.length(state.questions))
}

/// The current question as a form. `attributes` go on the `<form>`: a
/// `method` and `action` on a page, or a submit handler in a live view.
pub fn view(
  words: Words,
  state: Questionnaire,
  attributes: List(Attribute(msg)),
) -> Element(msg) {
  let #(number, count) = progress(state)
  let current = list.drop(state.questions, state.step) |> list.first
  let kept =
    state.answers
    |> dict.to_list
    |> list.filter(fn(pair) {
      case current {
        Ok(question) -> pair.0 != question.id
        Error(Nil) -> True
      }
    })
    |> list.flat_map(fn(pair) {
      list.map(pair.1, fn(value) {
        html.input([
          attribute.type_("hidden"),
          attribute.name(answer_prefix <> pair.0),
          attribute.value(value),
        ])
      })
    })
  html.form([class(form_class()), ..attributes], [
    html.input([
      attribute.type_("hidden"),
      attribute.name(step_field),
      attribute.value(int.to_string(state.step)),
    ]),
    element.fragment(kept),
    html.div([class(progress_class())], [
      html.span([class(count_class())], [
        text(words.question_count(number, count)),
      ]),
      progress.progress(label: words.progress, value: number - 1, max: count),
    ]),
    case current {
      Ok(question) -> ask(words, state, question)
      Error(Nil) -> element.none()
    },
    html.div(
      [class(actions_class())],
      actions(words, state, current, number, count),
    ),
  ])
}

fn actions(
  words: Words,
  state: Questionnaire,
  current: Result(Question, Nil),
  number: Int,
  count: Int,
) -> List(Element(msg)) {
  let act = fn(value) { [attribute.name(action_field), attribute.value(value)] }
  let next_label = case number == count {
    True -> words.finish
    False -> words.next
  }
  // Next comes first, so Enter in a text field presses it; the row is
  // reversed to put Back on the left.
  list.flatten([
    [button.submit(button.Primary, act("next"), [text(next_label)])],
    case current {
      Ok(question) if !question.required -> [
        button.submit(button.Ghost, act("skip"), [text(words.skip)]),
      ]
      _ -> []
    },
    case state.step > 0 {
      True -> [
        button.submit(
          button.Outline,
          [attribute.attribute("formnovalidate", ""), ..act("back")],
          [text(words.back)],
        ),
      ]
      False -> []
    },
  ])
}

fn ask(words: Words, state: Questionnaire, question: Question) -> Element(msg) {
  let given = dict.get(state.answers, question.id) |> result.unwrap([])
  let error_id = question.id <> "-error"
  let help_id = question.id <> "-help"
  let described =
    [
      case question.help {
        "" -> None
        _ -> Some(help_id)
      },
      option.map(state.error, fn(_) { error_id }),
    ]
    |> option.values
  let invalid = case state.error, described {
    Some(_), _ -> [
      attribute.aria_invalid("true"),
      attribute.aria_describedby(string.join(described, " ")),
    ]
    None, [] -> []
    None, _ -> [attribute.aria_describedby(string.join(described, " "))]
  }
  let first = given |> list.first |> result.unwrap("")
  let control = case question.kind {
    Short ->
      input.input([
        attribute.id(question.id),
        attribute.name(question.id),
        attribute.value(first),
        attribute.autofocus(True),
        ..invalid
      ])
    Long ->
      input.textarea(
        [
          attribute.id(question.id),
          attribute.name(question.id),
          attribute.rows(4),
          attribute.autofocus(True),
          ..invalid
        ],
        first,
      )
    Single(options) ->
      checkbox.radio_group(
        invalid,
        list.map(options, fn(option) {
          checkbox.choice(
            checkbox.radio([
              attribute.name(question.id),
              attribute.value(option.0),
              attribute.checked(list.contains(given, option.0)),
            ]),
            [text(option.1)],
          )
        }),
      )
    Several(options) ->
      html.div(
        [class(options_class()), ..invalid],
        list.map(options, fn(option) {
          checkbox.choice(
            checkbox.checkbox([
              attribute.name(question.id),
              attribute.value(option.0),
              attribute.checked(list.contains(given, option.0)),
            ]),
            [text(option.1)],
          )
        }),
      )
    Scale(from:, to:, low:, high:) ->
      html.div([class(scale_class())], [
        html.div(
          [class(scale_steps_class()), attribute.role("radiogroup"), ..invalid],
          list.map(numbers(from, to), fn(number) {
            let value = int.to_string(number)
            html.label([class(scale_step_class())], [
              html.input([
                attribute.type_("radio"),
                attribute.name(question.id),
                attribute.value(value),
                attribute.checked(list.contains(given, value)),
              ]),
              html.span([], [text(words.number(number))]),
            ])
          }),
        ),
        html.div([class(scale_ends_class())], [
          html.span([], [text(low)]),
          html.span([], [text(high)]),
        ]),
      ])
  }
  // One fieldset per question, so its prompt names every option in it.
  field.fieldset(
    [class(question_class())],
    legend: [html.span([class(prompt_class())], [text(question.prompt)])],
    children: [
      case question.help {
        "" -> element.none()
        help -> field.description([attribute.id(help_id)], [text(help)])
      },
      control,
      case state.error {
        Some(trouble) ->
          field.error([attribute.id(error_id), attribute.role("alert")], [
            text(describe(words, trouble)),
          ])
        None -> element.none()
      },
    ],
  )
}

fn describe(words: Words, trouble: Trouble) -> String {
  case trouble {
    Unanswered -> words.answer_required
    NotAnOption -> words.choose_one
    NotFromOptions -> words.choose_from
    OffScale -> words.choose_on_scale
    NotOneAnswer -> words.give_one_answer
    Rejected(message) -> message
  }
}

fn numbers(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..numbers(from + 1, to)]
  }
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    form_class(),
    progress_class(),
    count_class(),
    question_class(),
    prompt_class(),
    options_class(),
    scale_class(),
    scale_steps_class(),
    scale_step_class(),
    scale_ends_class(),
    actions_class(),
  ]
}

pub fn form_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(1.5)),
    css.property("max-width", "36rem"),
  ])
}

pub fn progress_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.5)),
  ])
}

pub fn count_class() -> Class {
  css.class([css.font_size(rem(0.875)), css.color(tokens.text_muted)])
}

pub fn question_class() -> Class {
  css.class([css.gap(rem(1.0))])
}

pub fn prompt_class() -> Class {
  css.class([
    css.font_size(rem(1.25)),
    css.font_weight("600"),
    css.line_height("1.3"),
    css.color(tokens.text),
  ])
}

pub fn options_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.75)),
  ])
}

pub fn scale_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.5)),
  ])
}

pub fn scale_steps_class() -> Class {
  css.class([css.display("flex"), css.flex_wrap("wrap"), css.gap(rem(0.25))])
}

/// A number on the scale: a radio button drawn as a box, filled when
/// chosen.
pub fn scale_step_class() -> Class {
  css.class([
    css.position("relative"),
    css.selector(" > input", [
      css.position("absolute"),
      css.property("opacity", "0"),
      css.property("inset", "0"),
      css.margin(rem(0.0)),
      css.cursor("pointer"),
    ]),
    css.selector(" > span", [
      css.display("inline-flex"),
      css.align_items("center"),
      css.justify_content("center"),
      css.property("min-width", "2.5rem"),
      css.property("height", "2.5rem"),
      style.bordered(),
      style.radius(tokens.radius_medium),
      css.background(tokens.surface),
      css.color(tokens.text),
      css.font_weight("500"),
      css.property("font-variant-numeric", "tabular-nums"),
    ]),
    css.selector(" > input:checked + span", [
      css.background(tokens.primary),
      css.color(tokens.on_primary),
      css.property("border-color", tokens.primary),
    ]),
    css.selector(" > input:focus-visible + span", [
      style.focus_outline(),
      css.property("outline-offset", "2px"),
    ]),
    css.selector(" > input:hover + span", [
      css.property("border-color", tokens.primary),
    ]),
  ])
}

pub fn scale_ends_class() -> Class {
  css.class([
    css.display("flex"),
    css.justify_content("space-between"),
    css.font_size(rem(0.8125)),
    css.color(tokens.text_muted),
  ])
}

pub fn actions_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("row-reverse"),
    css.justify_content("flex-end"),
    css.gap(rem(0.5)),
  ])
}
