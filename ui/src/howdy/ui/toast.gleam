//// Toasts: short notifications in a corner of the screen that go away on
//// their own.
////
//// ```gleam
//// toast.region(words.english(), [], [
////   toast.toast(toast.Info, [], [
////     toast.title([text("Saved")]),
////     toast.description([text("Your changes are live.")]),
////     toast.close([attribute.aria_label("Dismiss")]),
////   ]),
//// ])
//// ```
////
//// Render the region once, on every page or in the live view, and put
//// toasts in it. It is a live region, so a screen reader reads a toast
//// when it appears. A toast fades out after five seconds, or the time set
//// with `duration`; hovering over it or focusing inside it pauses the
//// countdown. `persistent` keeps it until it is closed.
////
//// The countdown is a CSS animation, so it works the same for a flash
//// message rendered with a page and a toast a live view adds to its model.
//// When a toast fades, its close button is pressed for it, so a live view
//// hears it the same way as a click and can drop the toast from its model;
//// `queue` and `view` do this for you.
////
//// `words` name the region and, in `view`, the close buttons; see
//// `howdy/ui/words`.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import howdy/flash
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import howdy/ui/words.{type Words}
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import lustre/server_component
import sketch/css.{type Class}
import sketch/css/length.{rem}

pub type Variant {
  Info
  /// Something finished well, with a tick.
  Success
  Danger
  /// Something is under way, with a spinner. It stays until it is updated
  /// or closed.
  Loading
}

/// The corner toasts appear in. Keep it in the page even when it is empty,
/// so a screen reader is already listening when a toast arrives.
pub fn region(
  words: Words,
  attributes: List(Attribute(msg)),
  toasts: List(Element(msg)),
) -> Element(msg) {
  style.rule(animation_rule, animation_css)
  html.section(
    [
      class(region_class()),
      attribute.aria_label(words.notifications),
      attribute.aria_live("polite"),
      attribute.data("howdy-toast-region", ""),
      ..attributes
    ],
    toasts,
  )
}

pub fn toast(
  variant: Variant,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  let #(marks, icon) = case variant {
    Success -> #([], [
      html.span(
        [
          class(icon_class()),
          attribute.data("toast-icon", ""),
          attribute.aria_hidden(True),
        ],
        [text("✓")],
      ),
    ])
    Loading -> #([persistent()], [
      html.span(
        [
          class(icon_class()),
          attribute.data("toast-icon", ""),
          attribute.data("howdy-toast-spinner", ""),
          attribute.aria_hidden(True),
        ],
        [],
      ),
    ])
    Info | Danger -> #([], [])
  }
  html.div(
    [
      class(toast_class(variant)),
      attribute.data("howdy-toast", ""),
      ..list.append(marks, attributes)
    ],
    list.append(icon, children),
  )
}

/// A toast for each flash message, to put in a `region`. They fade like
/// any other toast, and each has a close button, labelled with the words'
/// `dismiss`.
///
/// ```gleam
/// use messages <- flash.take(ctx, flash)
/// let w = words.english()
/// page.new("Settings")
/// |> page.body([toast.region(w, [], toast.flashed(w, messages)), ..])
/// ```
pub fn flashed(
  words: Words,
  messages: List(flash.Message),
) -> List(Element(msg)) {
  list.map(messages, fn(message) {
    toast(flash_variant(message.level), [], [
      title([text(message.text)]),
      close([attribute.aria_label(words.dismiss)]),
    ])
  })
}

/// Push each flash message onto a live view's queue, oldest first.
pub fn push_flashed(
  queue: Queue,
  messages: List(flash.Message),
  now: Int,
) -> Queue {
  list.fold(messages, queue, fn(queue, message) {
    push(queue, flash_variant(message.level), message.text, "", now).0
  })
}

fn flash_variant(level: flash.Level) -> Variant {
  case level {
    flash.Info -> Info
    flash.Success -> Success
    flash.Danger -> Danger
  }
}

// -- Queue -------------------------------------------------------------------

/// The toasts a live view is showing, by id, for keeping in its model.
/// Push a toast when something happens; update it when a loading toast
/// finishes, so it turns into a success or an error in place; and expire
/// the queue now and then, so toasts that have faded are dropped.
///
/// ```gleam
/// let #(toasts, id) = toast.push(model.toasts, Loading, "Saving…", "", now)
/// // later, when the save is done:
/// let toasts = toast.update(toasts, id, Success, "Saved", "", now)
/// ```
///
/// The browser decides when a toast has gone, since it pauses the countdown
/// while the toast is hovered or focused: when one fades, its close button
/// is pressed for it, so `on_close` in `view` hears it and the toast can be
/// dismissed. The browser also says when a toast is held open and let go,
/// through `on_hold`; pass that to `hold`, so the queue's clock pauses with
/// the browser's.
///
/// `expire` is a fallback for a fade the browser never reported, such as a
/// message lost in transit. It drops a toast a minute after its countdown
/// should have ended, counting only the time it was not held, so a toast
/// someone is reading is never taken away however long they read it.
///
/// Times are milliseconds from any clock that only moves forward, such as
/// `erlang:monotonic_time(millisecond)`.
pub opaque type Queue {
  Queue(next: Int, items: List(Item))
}

pub type Item {
  Item(
    id: Int,
    variant: Variant,
    title: String,
    description: String,
    shown_at: Int,
    lasts: Option(Int),
    /// How many times it has been updated; each update restarts its
    /// countdown.
    round: Int,
    /// When the reader started holding it open, if they still are.
    held_since: Option(Int),
    /// How long it was held open before that, since it was last shown.
    held_for: Int,
  )
}

pub fn queue() -> Queue {
  Queue(next: 1, items: [])
}

/// Show a toast; returns its id. A loading toast stays until updated; the
/// others fade after five seconds.
pub fn push(
  queue: Queue,
  variant: Variant,
  title: String,
  description: String,
  now: Int,
) -> #(Queue, Int) {
  let item =
    Item(
      id: queue.next,
      variant:,
      title:,
      description:,
      shown_at: now,
      lasts: lasting(variant),
      round: 0,
      held_since: None,
      held_for: 0,
    )
  #(
    Queue(next: queue.next + 1, items: list.append(queue.items, [item])),
    item.id,
  )
}

/// Change a toast in place, such as a loading one that has finished. Its
/// countdown starts again.
pub fn update(
  queue: Queue,
  id: Int,
  variant: Variant,
  title: String,
  description: String,
  now: Int,
) -> Queue {
  Queue(
    ..queue,
    items: list.map(queue.items, fn(item) {
      case item.id == id {
        True ->
          Item(
            ..item,
            variant:,
            title:,
            description:,
            shown_at: now,
            lasts: lasting(variant),
            round: item.round + 1,
            // The countdown starts again, still held if it was.
            held_since: option.map(item.held_since, fn(_) { now }),
            held_for: 0,
          )
        False -> item
      }
    }),
  )
}

/// Take a toast away, such as when its close button is clicked.
pub fn dismiss(queue: Queue, id: Int) -> Queue {
  Queue(..queue, items: list.filter(queue.items, fn(item) { item.id != id }))
}

/// Note that the reader has started (`True`) or stopped (`False`) holding
/// a toast open, as `view`'s `on_hold` reports.
pub fn hold(queue: Queue, id: Int, held: Bool, now: Int) -> Queue {
  Queue(
    ..queue,
    items: list.map(queue.items, fn(item) {
      case item.id == id, held, item.held_since {
        False, _, _ -> item
        True, True, None -> Item(..item, held_since: Some(now))
        True, False, Some(since) ->
          Item(..item, held_since: None, held_for: item.held_for + now - since)
        True, _, _ -> item
      }
    }),
  )
}

/// Drop toasts whose countdown should have ended more than a minute before
/// `now` but were never closed by the browser. Time held open does not
/// count, and a toast being held now is always kept.
pub fn expire(queue: Queue, now: Int) -> Queue {
  Queue(
    ..queue,
    items: list.filter(queue.items, fn(item) {
      case item.lasts, item.held_since {
        _, Some(_) | None, _ -> True
        Some(lasts), None ->
          now - item.shown_at - item.held_for < lasts + expiry_grace
      }
    }),
  )
}

const expiry_grace = 60_000

pub fn items(queue: Queue) -> List(Item) {
  queue.items
}

/// The queue's toasts in a region. `on_close` gives the attributes of each
/// toast's close button, such as a click handler that dismisses it; its
/// `aria-label` is the words' `dismiss`. It is pressed for you when a toast fades.
/// `on_hold` hears a toast's id when the reader starts (`True`) or stops
/// (`False`) holding it open by pointing at it or focusing inside it; pass
/// it on to `hold`. `howdy/ui/behaviour` presses a faded toast's close
/// button and reports holds, so a live view keeping toasts in its model
/// hears both.
pub fn view(
  words: Words,
  queue: Queue,
  on_close on_close: fn(Int) -> List(Attribute(msg)),
  on_hold on_hold: fn(Int, Bool) -> msg,
) -> Element(msg) {
  style.rule(animation_rule, animation_css)
  keyed.element(
    "section",
    [
      class(region_class()),
      attribute.aria_label(words.notifications),
      attribute.aria_live("polite"),
      attribute.data("howdy-toast-queue", ""),
    ],
    list.map(queue.items, fn(item) {
      let lasts = case item.lasts {
        Some(ms) -> [duration(ms)]
        None -> []
      }
      // Alternating the fade's name restarts the countdown in place.
      let lasts = case item.round % 2 {
        0 -> lasts
        _ -> [attribute.data("round", "odd"), ..lasts]
      }
      #(
        int.to_string(item.id),
        toast(item.variant, [held(item.id, on_hold), ..lasts], [
          title([text(item.title)]),
          case item.description {
            "" -> element.none()
            said -> description([text(said)])
          },
          close([attribute.aria_label(words.dismiss), ..on_close(item.id)]),
        ]),
      )
    }),
  )
}

fn held(id: Int, on_hold: fn(Int, Bool) -> msg) -> Attribute(msg) {
  event.on("howdy-toast-hold", {
    use held <- decode.subfield(["detail", "held"], decode.bool)
    decode.success(on_hold(id, held))
  })
  |> server_component.include(["detail.held"])
}

fn lasting(variant: Variant) -> Option(Int) {
  case variant {
    Loading -> None
    _ -> Some(5000)
  }
}

pub fn title(children: List(Element(msg))) -> Element(msg) {
  html.div([class(title_class())], children)
}

pub fn description(children: List(Element(msg))) -> Element(msg) {
  html.div([class(description_class())], children)
}

/// A button in the top corner that hides the toast. Give it an
/// `aria-label`; in a live view, add a click handler to drop the toast
/// from the model too.
pub fn close(attributes: List(Attribute(msg))) -> Element(msg) {
  html.button(
    [
      class(close_class()),
      attribute.type_("button"),
      attribute.data("howdy-toast-close", ""),
      ..attributes
    ],
    [html.span([attribute.aria_hidden(True)], [text("×")])],
  )
}

/// How long the toast stays before fading, in milliseconds.
pub fn duration(milliseconds: Int) -> Attribute(msg) {
  attribute.style("--howdy-toast-duration", int.to_string(milliseconds) <> "ms")
}

/// Keep the toast until it is closed.
pub fn persistent() -> Attribute(msg) {
  attribute.data("persistent", "")
}

/// Every class this module uses, for `howdy/ui/export`.
/// The CSS this module registers with `style.rule`, for `howdy/ui/export`.
pub fn rules() -> List(#(String, String)) {
  [#(animation_rule, animation_css)]
}

pub fn classes() -> List(Class) {
  [
    region_class(),
    toast_class(Info),
    toast_class(Success),
    toast_class(Danger),
    toast_class(Loading),
    icon_class(),
    title_class(),
    description_class(),
    close_class(),
  ]
}

pub fn region_class() -> Class {
  css.class([
    css.position("fixed"),
    css.property("inset-inline-end", tokens.space_4),
    css.property("bottom", tokens.space_4),
    css.z_index(50),
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.5)),
    css.property("width", "min(24rem, calc(100vw - 2rem))"),
    css.property("pointer-events", "none"),
  ])
}

pub fn toast_class(variant: Variant) -> Class {
  let colour = case variant {
    Info | Success | Loading -> tokens.text
    Danger -> tokens.danger
  }
  css.class([
    css.position("relative"),
    css.display("grid"),
    css.gap(rem(0.25)),
    css.padding(rem(1.0)),
    css.property("padding-inline-end", "2.5rem"),
    css.background(tokens.surface),
    css.color(colour),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.box_shadow("0 10px 30px -10px rgb(0 0 0 / 0.3)"),
    css.font_size(rem(0.875)),
    css.property("pointer-events", "auto"),
    css.selector("[hidden]", [css.display("none")]),
    css.selector(":has(> [data-toast-icon])", [
      css.property("padding-inline-start", "2.75rem"),
    ]),
  ])
}

pub fn icon_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("top", tokens.space_4),
    css.property("inset-inline-start", tokens.space_4),
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.property("width", "1.125rem"),
    css.property("height", "1.125rem"),
    style.pill(),
    css.font_size(rem(0.75)),
    css.font_weight("700"),
    css.color(tokens.primary),
    css.selector("[data-howdy-toast-spinner]", [
      css.property("border", "2px solid " <> tokens.border),
      css.property("border-top-color", tokens.primary),
    ]),
  ])
}

pub fn title_class() -> Class {
  css.class([css.font_weight("600")])
}

pub fn description_class() -> Class {
  css.class([css.color(tokens.text_muted)])
}

pub fn close_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("top", tokens.space_2),
    css.property("inset-inline-end", tokens.space_2),
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.property("width", "1.5rem"),
    css.property("height", "1.5rem"),
    css.padding(rem(0.0)),
    css.border("0"),
    style.radius(tokens.radius_small),
    css.background("transparent"),
    css.color(tokens.text_muted),
    css.font_size(rem(1.125)),
    css.line_height("1"),
    css.cursor("pointer"),
    css.hover([css.color(tokens.text), css.background(tokens.muted)]),
    style.focus_ring(),
  ])
}

// Sketch classes cannot carry `@keyframes`, so they are registered as a
// rule when a region is drawn, emitted once per document.
// Fading out ends with `display: none`, so a faded toast gives up its space.
const animation_rule = "howdy-toast"

const animation_css = "@keyframes howdy-toast-in{from{opacity:0;transform:translateY(.5rem)}}@keyframes howdy-toast-out{to{opacity:0;visibility:hidden;display:none}}@keyframes howdy-toast-out-again{to{opacity:0;visibility:hidden;display:none}}[data-howdy-toast]{animation:howdy-toast-in .2s ease-out,howdy-toast-out .2s ease-in var(--howdy-toast-duration,5s) forwards}[data-howdy-toast][data-round=odd]{animation-name:howdy-toast-in,howdy-toast-out-again}[data-howdy-toast][data-persistent]{animation:howdy-toast-in .2s ease-out}[data-howdy-toast]:hover,[data-howdy-toast]:focus-within{animation-play-state:paused}@keyframes howdy-toast-spin{to{transform:rotate(360deg)}}[data-howdy-toast-spinner]{animation:howdy-toast-spin .8s linear infinite}@media (prefers-reduced-motion:reduce){[data-howdy-toast-spinner]{animation-duration:2.4s}[data-howdy-toast]{animation-name:none,howdy-toast-out}[data-howdy-toast][data-round=odd]{animation-name:none,howdy-toast-out-again}[data-howdy-toast][data-persistent]{animation:none}}"
