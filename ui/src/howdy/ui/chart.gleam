//// Charts: bar, line and area charts drawn as SVG on the server, in the
//// theme's chart colours.
////
//// ```gleam
//// chart.bar(
////   title: "Revenue by month",
////   labels: ["Jan", "Feb", "Mar"],
////   series: [
////     chart.Series("Online", [4200.0, 5100.0, 6100.0]),
////     chart.Series("In store", [3100.0, 2900.0, 3300.0]),
////   ],
//// )
//// |> chart.view
//// ```
////
//// Every series is one entry per label. Series take the theme's chart
//// colours in order, so a series keeps its colour as long as it keeps its
//// place: when a filter removes some, pass the survivors in the same order
//// with `colours` rather than letting them shift. There are five colours;
//// past five series, fold the rest into an "Other" series or draw several
//// charts. A sixth and later series is drawn in the muted text colour.
////
//// Hovering over or focusing a label's column shows every series' value
//// there; with Tab a keyboard reaches each column, and a screen reader
//// reads the same values. Under the chart, "Show data" opens the numbers as
//// a table. None of it needs a script.
////
//// The value axis always includes zero, so bars grow from a baseline and a
//// line's height is honest. Two measures on different scales belong in two
//// charts, never on two axes of one.

import gleam/float
import gleam/int
import gleam/list
import gleam/string
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/element/svg
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

/// A named list of values, one per label.
pub type Series {
  Series(name: String, values: List(Float))
}

pub type Kind {
  Bar
  Line
  Area
  /// Parts of a whole, as slices; `hole` is the inner radius as a share of
  /// the outer, so `0.0` is a pie and about `0.6` a donut.
  Pie(hole: Float)
  /// Values out of `max`, as concentric rings.
  Radial(max: Float)
  /// Several measures around a circle, one polygon per series.
  Radar
}

pub opaque type Chart {
  Chart(
    kind: Kind,
    title: String,
    labels: List(String),
    series: List(Series),
    colours: List(Int),
    format: fn(Float) -> String,
  )
}

/// Parts of a whole as slices, with each part's value and share in the
/// legend. Use it for a few parts, six at most; to compare values, a bar
/// chart reads better.
pub fn pie(
  title title: String,
  labels labels: List(String),
  values values: List(Float),
) -> Chart {
  Chart(
    ..new(Pie(0.0), title, labels, [Series(title, values)]),
    colours: list.index_map(labels, fn(_, index) { index + 1 }),
  )
}

/// A pie with a hole, showing the total in the middle.
pub fn donut(
  title title: String,
  labels labels: List(String),
  values values: List(Float),
) -> Chart {
  Chart(..pie(title:, labels:, values:), kind: Pie(0.62))
}

/// Each value out of `max` as a ring, such as goals reached.
pub fn radial(
  title title: String,
  labels labels: List(String),
  values values: List(Float),
  max max: Float,
) -> Chart {
  Chart(
    ..new(Radial(max), title, labels, [Series(title, values)]),
    colours: list.index_map(labels, fn(_, index) { index + 1 }),
  )
}

/// Several measures, one per axis around the circle, for comparing the
/// shape of a few series. `axes` name the measures; each series has one
/// value per axis.
pub fn radar(
  title title: String,
  axes axes: List(String),
  series series: List(Series),
) -> Chart {
  new(Radar, title, axes, series)
}

/// Columns, grouped by label when there are several series.
pub fn bar(
  title title: String,
  labels labels: List(String),
  series series: List(Series),
) -> Chart {
  new(Bar, title, labels, series)
}

/// Lines, for change over an ordered range such as time.
pub fn line(
  title title: String,
  labels labels: List(String),
  series series: List(Series),
) -> Chart {
  new(Line, title, labels, series)
}

/// Lines with a light wash beneath, for volumes over time.
pub fn area(
  title title: String,
  labels labels: List(String),
  series series: List(Series),
) -> Chart {
  new(Area, title, labels, series)
}

fn new(kind: Kind, title: String, labels: List(String), series: List(Series)) {
  Chart(
    kind:,
    title:,
    labels:,
    series:,
    colours: list.index_map(series, fn(_, index) { index + 1 }),
    format: format_number,
  )
}

/// How values are written on the axis, in readouts and in the table. The
/// default writes whole numbers with thousands separators and at most two
/// decimal places.
pub fn format(chart: Chart, format: fn(Float) -> String) -> Chart {
  Chart(..chart, format:)
}

/// Which chart colour, from 1 to 5, each series takes. Use it to keep a
/// series' colour when others are filtered out.
pub fn colours(chart: Chart, colours: List(Int)) -> Chart {
  Chart(..chart, colours:)
}

// -- Geometry ----------------------------------------------------------------
//
// Text, dots, bars and hover columns are HTML placed over the plot, so they
// keep their size at any width. Lines, washes and gridlines are an SVG
// stretched across the plot: x runs from 0 to 100 as a percentage of its
// width, y is in pixels, and strokes do not scale.

const plot_height = 200.0

const top = 12.0

const bottom_band = 28.0

/// An estimate of the width of text in the chart's 12px type.
fn text_width(content: String) -> Float {
  int.to_float(string.length(content)) *. 6.8
}

type Scale {
  Scale(low: Float, high: Float, ticks: List(Float))
}

fn scale(values: List(Float)) -> Scale {
  let low = list.fold(values, 0.0, float.min)
  let high = list.fold(values, 0.0, float.max)
  let high = case high == low {
    True -> low +. 1.0
    False -> high
  }
  let step = nice_step({ high -. low } /. 5.0)
  // A very large `low` absorbs the `+. 1.0` above, leaving no range.
  let high = case high == low {
    True -> low +. step
    False -> high
  }
  let low = float.floor(low /. step) *. step
  let high = float.ceiling(high /. step) *. step
  let count = float.round({ high -. low } /. step)
  let ticks =
    list.repeat(Nil, count + 1)
    |> list.index_map(fn(_, index) { low +. int.to_float(index) *. step })
  Scale(low:, high:, ticks:)
}

/// 1, 2 or 5 times a power of ten. A range that is zero, negative or
/// otherwise has no logarithm gets a step of 1.
fn nice_step(raw: Float) -> Float {
  let assert Ok(ln10) = float.logarithm(10.0)
  let magnitude = case float.logarithm(raw) {
    Ok(ln) -> float.power(10.0, float.floor(ln /. ln10))
    Error(Nil) -> Error(Nil)
  }
  case magnitude {
    Ok(magnitude) if magnitude >. 0.0 -> {
      let factor = case raw /. magnitude {
        n if n <=. 1.0 -> 1.0
        n if n <=. 2.0 -> 2.0
        n if n <=. 5.0 -> 5.0
        _ -> 10.0
      }
      factor *. magnitude
    }
    _ -> 1.0
  }
}

/// Pixels from the top of the plot.
fn y_of(scale: Scale, value: Float) -> Float {
  plot_height
  -. { value -. scale.low }
  /. { scale.high -. scale.low }
  *. plot_height
}

/// The centre of a label's column, as a percentage of the plot's width.
fn x_of(count: Int, index: Int) -> Float {
  { int.to_float(index) +. 0.5 } /. int.to_float(int.max(count, 1)) *. 100.0
}

fn n(value: Float) -> String {
  float.to_string(float.to_precision(value, 2))
}

fn px(value: Float) -> String {
  n(value) <> "px"
}

fn pct(value: Float) -> String {
  n(value) <> "%"
}

// -- View --------------------------------------------------------------------

pub fn view(chart: Chart) -> Element(msg) {
  case chart.kind {
    Pie(_) | Radial(_) | Radar -> polar_view(chart)
    Bar | Line | Area -> cartesian_view(chart)
  }
}

fn cartesian_view(chart: Chart) -> Element(msg) {
  let values = list.flat_map(chart.series, fn(series) { series.values })
  let scale = scale(values)
  let count = list.length(chart.labels)
  let tick_labels = list.map(scale.ticks, chart.format)
  let gutter =
    list.fold(tick_labels, 0.0, fn(widest, label) {
      float.max(widest, text_width(label))
    })
    +. 12.0
  let direct = direct_labels(chart, scale)
  let end_gutter = case direct {
    True ->
      list.fold(chart.series, 0.0, fn(widest, series) {
        float.max(widest, text_width(series.name))
      })
      +. 20.0
    False -> 8.0
  }

  html.figure([class(figure_class())], [
    legend(chart),
    html.div(
      [
        class(chart_class()),
        attribute.style("height", px(top +. plot_height +. bottom_band)),
        attribute.role("group"),
        attribute.aria_label(chart.title),
      ],
      [
        html.div(
          [
            class(gutter_class()),
            attribute.style("width", px(gutter)),
            attribute.aria_hidden(True),
          ],
          list.map2(scale.ticks, tick_labels, fn(tick, label) {
            html.span(
              [
                class(tick_class()),
                attribute.style("top", px(top +. y_of(scale, tick))),
              ],
              [text(label)],
            )
          }),
        ),
        html.div(
          [
            class(plot_class()),
            attribute.style("left", px(gutter)),
            attribute.style("right", px(end_gutter)),
            attribute.style("top", px(top)),
            attribute.style("height", px(plot_height)),
          ],
          list.flatten([
            [
              html.div([attribute.aria_hidden(True)], [
                drawing(chart, scale, count),
                bars(chart, scale, count),
                end_dots(chart, scale, count),
                case direct {
                  True -> end_labels(chart, scale, count)
                  False -> element.none()
                },
                x_labels(chart, count),
              ]),
            ],
            list.index_map(chart.labels, fn(label, index) {
              column_view(chart, scale, count, label, index)
            }),
          ]),
        ),
      ],
    ),
    data_view(chart),
  ])
}

fn colour(chart: Chart, index: Int) -> String {
  let slot = case list.drop(chart.colours, index) {
    [slot, ..] -> slot
    [] -> index + 1
  }
  case list.drop(tokens.chart, slot - 1) {
    [colour, ..] if slot >= 1 -> colour
    _ -> tokens.text_muted
  }
}

fn legend(chart: Chart) -> Element(msg) {
  case chart.series {
    [_, _, ..] ->
      html.ul(
        [class(legend_class())],
        list.index_map(chart.series, fn(series, index) {
          let shape = case chart.kind {
            Line | Radar -> key_line_class()
            Bar | Area | Pie(_) | Radial(_) -> key_box_class()
          }
          html.li([], [
            html.span(
              [
                class(shape),
                attribute.style("background", colour(chart, index)),
              ],
              [],
            ),
            text(series.name),
          ])
        }),
      )
    _ -> element.none()
  }
}

/// Gridlines, lines and washes.
fn drawing(chart: Chart, scale: Scale, count: Int) -> Element(msg) {
  let zero = y_of(scale, 0.0)
  let rules =
    list.map(scale.ticks, fn(tick) {
      let y = y_of(scale, tick)
      svg.line([
        class(case tick == 0.0 {
          True -> baseline_class()
          False -> grid_class()
        }),
        attribute.attribute("x1", "0"),
        attribute.attribute("x2", "100"),
        attribute.attribute("y1", n(y)),
        attribute.attribute("y2", n(y)),
      ])
    })
  let lines = case chart.kind {
    Bar | Pie(_) | Radial(_) | Radar -> []
    Line | Area ->
      list.flatten(
        list.index_map(chart.series, fn(series, s) {
          let points =
            list.index_map(series.values, fn(value, index) {
              n(x_of(count, index)) <> "," <> n(y_of(scale, value))
            })
          let path = string.join(points, " L ")
          let wash = case chart.kind, points {
            Area, [_, ..] -> [
              svg.path([
                attribute.attribute(
                  "d",
                  "M "
                    <> n(x_of(count, 0))
                    <> ","
                    <> n(zero)
                    <> " L "
                    <> path
                    <> " L "
                    <> n(x_of(count, list.length(points) - 1))
                    <> ","
                    <> n(zero)
                    <> " Z",
                ),
                attribute.style("fill", colour(chart, s)),
                attribute.attribute("fill-opacity", "0.1"),
              ]),
            ]
            _, _ -> []
          }
          list.append(wash, [
            svg.path([
              class(line_class()),
              attribute.attribute("d", "M " <> path),
              attribute.style("stroke", colour(chart, s)),
            ]),
          ])
        }),
      )
  }
  html.svg(
    [
      class(svg_class()),
      attribute.attribute("viewBox", "0 0 100 " <> n(plot_height)),
      attribute.attribute("preserveAspectRatio", "none"),
    ],
    list.append(rules, lines),
  )
}

/// Columns grow from the baseline, up to 24px wide, rounded at the data
/// end only.
fn bars(chart: Chart, scale: Scale, count: Int) -> Element(msg) {
  case chart.kind {
    Line | Area | Pie(_) | Radial(_) | Radar -> element.none()
    Bar -> {
      let zero = y_of(scale, 0.0)
      html.div(
        [],
        list.index_map(chart.labels, fn(_, index) {
          html.div(
            [
              class(bar_group_class()),
              attribute.style(
                "left",
                pct(x_of(count, index) -. 40.0 /. int.to_float(count)),
              ),
              attribute.style("width", pct(80.0 /. int.to_float(count))),
            ],
            list.index_map(chart.series, fn(series, s) {
              let value = case list.drop(series.values, index) {
                [value, ..] -> value
                [] -> 0.0
              }
              let y = y_of(scale, value)
              let #(top, height, shape) = case value >=. 0.0 {
                True -> #(y, zero -. y, bar_up_class())
                False -> #(zero, y -. zero, bar_down_class())
              }
              html.div([class(bar_slot_class())], [
                html.div(
                  [
                    class(shape),
                    attribute.style("top", px(top)),
                    attribute.style("height", px(height)),
                    attribute.style("background", colour(chart, s)),
                  ],
                  [],
                ),
              ])
            }),
          )
        }),
      )
    }
  }
}

fn dot(x: Float, y: Float, colour: String) -> Element(msg) {
  html.span(
    [
      class(dot_class()),
      attribute.style("left", pct(x)),
      attribute.style("top", px(y)),
      attribute.style("background", colour),
    ],
    [],
  )
}

fn end_dots(chart: Chart, scale: Scale, count: Int) -> Element(msg) {
  case chart.kind {
    Bar | Pie(_) | Radial(_) | Radar -> element.none()
    Line | Area ->
      html.div(
        [],
        list.index_map(chart.series, fn(series, s) {
          case list.last(series.values) {
            Ok(value) ->
              dot(
                x_of(count, list.length(series.values) - 1),
                y_of(scale, value),
                colour(chart, s),
              )
            Error(Nil) -> element.none()
          }
        }),
      )
  }
}

/// Lines and areas with two to four series name each at its end, unless
/// two ends are too close to label apart; then the legend does it alone.
fn direct_labels(chart: Chart, scale: Scale) -> Bool {
  let count = list.length(chart.series)
  case chart.kind, count >= 2 && count <= 4 {
    Line, True | Area, True -> {
      let ends =
        chart.series
        |> list.filter_map(fn(series) { list.last(series.values) })
        |> list.map(y_of(scale, _))
        |> list.sort(float.compare)
      let #(_, apart) =
        list.fold(ends, #(-100.0, True), fn(acc, y) {
          #(y, acc.1 && y -. acc.0 >=. 14.0)
        })
      apart
    }
    _, _ -> False
  }
}

/// Each name level with its line's last point, just past the end of the
/// plot.
fn end_labels(chart: Chart, scale: Scale, count: Int) -> Element(msg) {
  html.div(
    [],
    list.map(chart.series, fn(series) {
      case list.last(series.values) {
        Ok(value) ->
          html.span(
            [
              class(end_label_class()),
              attribute.style(
                "left",
                "calc("
                  <> pct(x_of(count, list.length(series.values) - 1))
                  <> " + 10px)",
              ),
              attribute.style("top", px(y_of(scale, value))),
            ],
            [text(series.name)],
          )
        Error(Nil) -> element.none()
      }
    }),
  )
}

/// Every label that fits, assuming a plot about 480px wide; when they
/// would collide, every second, third and so on.
fn x_labels(chart: Chart, count: Int) -> Element(msg) {
  let widest =
    list.fold(chart.labels, 0.0, fn(widest, label) {
      float.max(widest, text_width(label))
    })
    +. 8.0
  let room = 480.0 /. int.to_float(int.max(count, 1))
  let every = int.max(1, float.round(float.ceiling(widest /. room)))
  html.div(
    [],
    list.index_map(chart.labels, fn(label, index) {
      case index % every == 0 {
        True ->
          html.span(
            [
              class(x_label_class()),
              attribute.style("left", pct(x_of(count, index))),
              attribute.style("top", px(plot_height +. 8.0)),
            ],
            [text(label)],
          )
        False -> element.none()
      }
    }),
  )
}

/// One label's column: the hit area, and the readout shown on hover or
/// focus.
fn column_view(
  chart: Chart,
  scale: Scale,
  count: Int,
  label: String,
  index: Int,
) -> Element(msg) {
  let width = 100.0 /. int.to_float(count)
  let readings =
    list.index_map(chart.series, fn(series, s) {
      case list.drop(series.values, index) {
        [value, ..] -> Ok(#(series.name, value, colour(chart, s)))
        [] -> Error(Nil)
      }
    })
    |> list.filter_map(fn(reading) { reading })
  let spoken =
    label
    <> ": "
    <> string.join(
      list.map(readings, fn(reading) {
        reading.0 <> " " <> chart.format(reading.1)
      }),
      ", ",
    )
  let marker = case chart.kind {
    Bar | Pie(_) | Radial(_) | Radar ->
      html.span([class(highlight_class())], [])
    Line | Area ->
      html.span([], [
        html.span([class(crosshair_class())], []),
        ..list.map(readings, fn(reading) {
          dot(50.0, y_of(scale, reading.1), reading.2)
        })
      ])
  }
  // Readouts sit to the right of their column, or to the left towards the
  // end of the plot.
  let side = case x_of(count, index) >. 60.0 {
    True -> tip_left_class()
    False -> tip_right_class()
  }
  html.div(
    [
      class(column_class()),
      attribute.style("left", pct(int.to_float(index) *. width)),
      attribute.style("width", pct(width)),
      attribute.tabindex(0),
      attribute.role("img"),
      attribute.aria_label(spoken),
    ],
    [
      html.span([attribute.data("reveal", ""), attribute.aria_hidden(True)], [
        marker,
        html.span([class(tip_class()), class(side)], [
          html.span([class(tip_label_class())], [text(label)]),
          ..list.map(readings, fn(reading) {
            html.span([class(tip_row_class())], [
              html.span(
                [
                  class(key_line_class()),
                  attribute.style("background", reading.2),
                ],
                [],
              ),
              html.strong([], [text(chart.format(reading.1))]),
              html.span([class(tip_name_class())], [text(reading.0)]),
            ])
          })
        ]),
      ]),
    ],
  )
}

// -- Polar charts --------------------------------------------------------------
//
// Pies, rings and radars are drawn at a fixed size, so their text never
// scales; they shrink only on screens too narrow for them.

const polar_size = 240.0

fn polar_view(chart: Chart) -> Element(msg) {
  let values = case chart.series {
    [series, ..] -> series.values
    [] -> []
  }
  let drawing = case chart.kind {
    Pie(hole) -> pie_drawing(chart, values, hole)
    Radial(max) -> radial_drawing(chart, values, max)
    _ -> radar_drawing(chart)
  }
  let legend = case chart.kind {
    Radar -> legend(chart)
    _ -> part_legend(chart, values)
  }
  html.figure([class(figure_class())], [
    html.div([class(polar_class())], [
      html.svg(
        [
          class(polar_svg_class()),
          attribute.attribute("viewBox", case chart.kind {
            // Room around a radar for its axis names.
            Radar -> "-60 -24 360 288"
            _ -> "0 0 240 240"
          }),
          attribute.role("group"),
          attribute.aria_label(chart.title),
        ],
        drawing,
      ),
      legend,
    ]),
    data_view(chart),
  ])
}

/// A legend of the parts, each with its value and, for a pie, its share.
fn part_legend(chart: Chart, values: List(Float)) -> Element(msg) {
  let total = list.fold(values, 0.0, float.add)
  html.ul(
    [class(part_legend_class())],
    list.index_map(list.zip(chart.labels, values), fn(pair, index) {
      let #(label, value) = pair
      let share = case chart.kind, total >. 0.0 {
        Pie(_), True ->
          " · " <> int.to_string(float.round(value /. total *. 100.0)) <> "%"
        Radial(max), _ -> " of " <> chart.format(max)
        _, _ -> ""
      }
      html.li([], [
        html.span(
          [
            class(key_box_class()),
            attribute.style("background", colour(chart, index)),
          ],
          [],
        ),
        html.span([class(part_name_class())], [text(label)]),
        html.strong([], [text(chart.format(value))]),
        html.span([class(part_name_class())], [text(share)]),
      ])
    }),
  )
}

const pi = 3.141592653589793

fn polar(angle: Float, radius: Float) -> #(Float, Float) {
  // 0 is straight up, turning clockwise.
  let radians = { angle -. 90.0 } *. pi /. 180.0
  #(
    polar_size /. 2.0 +. radius *. cosine(radians),
    polar_size /. 2.0 +. radius *. sine(radians),
  )
}

@external(erlang, "math", "cos")
@external(javascript, "./chart.ffi.mjs", "cos")
fn cosine(radians: Float) -> Float

@external(erlang, "math", "sin")
@external(javascript, "./chart.ffi.mjs", "sin")
fn sine(radians: Float) -> Float

fn point(at: #(Float, Float)) -> String {
  n(at.0) <> "," <> n(at.1)
}

/// A slice from `from` to `to` degrees, between radii `inner` and `outer`.
fn slice(from: Float, to: Float, inner: Float, outer: Float) -> String {
  let large = case to -. from >. 180.0 {
    True -> "1"
    False -> "0"
  }
  let outer_arc =
    "M "
    <> point(polar(from, outer))
    <> " A "
    <> n(outer)
    <> " "
    <> n(outer)
    <> " 0 "
    <> large
    <> " 1 "
    <> point(polar(to, outer))
  case inner >. 0.0 {
    True ->
      outer_arc
      <> " L "
      <> point(polar(to, inner))
      <> " A "
      <> n(inner)
      <> " "
      <> n(inner)
      <> " 0 "
      <> large
      <> " 0 "
      <> point(polar(from, inner))
      <> " Z"
    False ->
      outer_arc
      <> " L "
      <> point(#(polar_size /. 2.0, polar_size /. 2.0))
      <> " Z"
  }
}

fn pie_drawing(
  chart: Chart,
  values: List(Float),
  hole: Float,
) -> List(Element(msg)) {
  let total = list.fold(values, 0.0, float.add)
  let outer = polar_size /. 2.0 -. 4.0
  let inner = outer *. hole
  let #(slices, _) =
    list.index_map(list.zip(chart.labels, values), fn(pair, index) {
      #(pair, index)
    })
    |> list.fold(#([], 0.0), fn(acc, item) {
      let #(slices, at) = acc
      let #(#(label, value), index) = item
      let sweep = case total >. 0.0 {
        True -> value /. total *. 360.0
        False -> 0.0
      }
      // A whole circle is two halves; an arc cannot end where it starts.
      let d = case sweep >=. 359.99 {
        True ->
          slice(0.0, 180.0, inner, outer)
          <> " "
          <> slice(180.0, 360.0, inner, outer)
        False -> slice(at, at +. sweep, inner, outer)
      }
      let share = case total >. 0.0 {
        True -> int.to_string(float.round(value /. total *. 100.0)) <> "%"
        False -> "0%"
      }
      let part =
        svg.g(
          [
            class(part_class()),
            attribute.tabindex(0),
            attribute.role("img"),
            attribute.aria_label(
              label <> ": " <> chart.format(value) <> ", " <> share,
            ),
          ],
          [
            svg.path([
              attribute.attribute("d", d),
              attribute.style("fill", colour(chart, index)),
            ]),
          ],
        )
      #([part, ..slices], at +. sweep)
    })
  let centre = case hole >. 0.0 {
    True -> [
      svg.text(
        [
          class(centre_value_class()),
          attribute.attribute("x", "120"),
          attribute.attribute("y", "118"),
          attribute.attribute("text-anchor", "middle"),
        ],
        chart.format(total),
      ),
      svg.text(
        [
          class(centre_label_class()),
          attribute.attribute("x", "120"),
          attribute.attribute("y", "138"),
          attribute.attribute("text-anchor", "middle"),
        ],
        "Total",
      ),
    ]
    False -> []
  }
  list.append(list.reverse(slices), centre)
}

fn radial_drawing(
  chart: Chart,
  values: List(Float),
  max: Float,
) -> List(Element(msg)) {
  let count = list.length(values)
  let width = float.min(18.0, 90.0 /. int.to_float(int.max(count, 1)) -. 4.0)
  list.index_map(list.zip(chart.labels, values), fn(pair, index) {
    let #(label, value) = pair
    let radius =
      110.0 -. width /. 2.0 -. int.to_float(index) *. { width +. 4.0 }
    let share = float.clamp(value /. float.max(max, 1.0e-9), 0.0, 1.0)
    let circumference = 2.0 *. pi *. radius
    let ring = fn(extra) {
      svg.circle([
        attribute.attribute("cx", "120"),
        attribute.attribute("cy", "120"),
        attribute.attribute("r", n(radius)),
        attribute.attribute("fill", "none"),
        attribute.attribute("stroke-width", n(width)),
        ..extra
      ])
    }
    svg.g(
      [
        class(part_class()),
        attribute.tabindex(0),
        attribute.role("img"),
        attribute.aria_label(
          label <> ": " <> chart.format(value) <> " of " <> chart.format(max),
        ),
      ],
      [
        ring([class(ring_track_class())]),
        ring([
          attribute.style("stroke", colour(chart, index)),
          attribute.attribute("stroke-linecap", "round"),
          attribute.attribute(
            "stroke-dasharray",
            n(share *. circumference) <> " " <> n(circumference),
          ),
          attribute.attribute("transform", "rotate(-90 120 120)"),
        ]),
      ],
    )
  })
}

fn radar_drawing(chart: Chart) -> List(Element(msg)) {
  let count = int.max(list.length(chart.labels), 3)
  let values = list.flat_map(chart.series, fn(series) { series.values })
  let top = scale(values).high
  let radius = 100.0
  let angle = fn(index) { 360.0 /. int.to_float(count) *. int.to_float(index) }
  let ring = fn(share) {
    list.repeat(Nil, count)
    |> list.index_map(fn(_, index) {
      point(polar(angle(index), radius *. share))
    })
    |> string.join(" ")
  }
  let grid =
    list.map([0.25, 0.5, 0.75, 1.0], fn(share) {
      svg.polygon([
        class(radar_grid_class()),
        attribute.attribute("points", ring(share)),
      ])
    })
  let spokes =
    list.index_map(chart.labels, fn(label, index) {
      let end = polar(angle(index), radius)
      let at = polar(angle(index), radius +. 14.0)
      let anchor = case at.0 {
        x if x <. 110.0 -> "end"
        x if x >. 130.0 -> "start"
        _ -> "middle"
      }
      svg.g([], [
        svg.line([
          class(radar_grid_class()),
          attribute.attribute("x1", "120"),
          attribute.attribute("y1", "120"),
          attribute.attribute("x2", n(end.0)),
          attribute.attribute("y2", n(end.1)),
        ]),
        svg.text(
          [
            class(radar_label_class()),
            attribute.attribute("x", n(at.0)),
            attribute.attribute("y", n(at.1)),
            attribute.attribute("text-anchor", anchor),
            attribute.attribute("dominant-baseline", "middle"),
          ],
          label,
        ),
      ])
    })
  let shapes =
    list.index_map(chart.series, fn(series, s) {
      let points =
        list.index_map(series.values, fn(value, index) {
          point(polar(angle(index), radius *. value /. float.max(top, 1.0e-9)))
        })
        |> string.join(" ")
      let spoken =
        series.name
        <> ": "
        <> string.join(
          list.map2(chart.labels, series.values, fn(label, value) {
            label <> " " <> chart.format(value)
          }),
          ", ",
        )
      svg.g(
        [
          class(part_class()),
          attribute.tabindex(0),
          attribute.role("img"),
          attribute.aria_label(spoken),
        ],
        [
          svg.polygon([
            class(radar_shape_class()),
            attribute.attribute("points", points),
            attribute.style("stroke", colour(chart, s)),
            attribute.style("fill", colour(chart, s)),
          ]),
        ],
      )
    })
  list.flatten([grid, [svg.g([attribute.aria_hidden(True)], spokes)], shapes])
}

/// The numbers as a table, behind "Show data".
fn data_view(chart: Chart) -> Element(msg) {
  html.details([class(details_class())], [
    html.summary([class(summary_class())], [text("Show data")]),
    html.div([class(table_scroll_class())], [
      html.table([class(table_class())], [
        html.caption([class(caption_class())], [text(chart.title)]),
        html.thead([], [
          html.tr([], [
            html.th([attribute.attribute("scope", "col")], []),
            ..list.map(chart.series, fn(series) {
              html.th([attribute.attribute("scope", "col")], [text(series.name)])
            })
          ]),
        ]),
        html.tbody(
          [],
          list.index_map(chart.labels, fn(label, index) {
            html.tr([], [
              html.th([attribute.attribute("scope", "row")], [text(label)]),
              ..list.map(chart.series, fn(series) {
                html.td([], [
                  text(case list.drop(series.values, index) {
                    [value, ..] -> chart.format(value)
                    [] -> ""
                  }),
                ])
              })
            ])
          }),
        ),
      ]),
    ]),
  ])
}

// -- Numbers -----------------------------------------------------------------

/// Thousands separators and at most two decimal places: 12,500 or 3.25.
pub fn format_number(value: Float) -> String {
  let sign = case value <. 0.0 {
    True -> "-"
    False -> ""
  }
  let hundredths = float.round(float.absolute_value(value) *. 100.0)
  let whole = hundredths / 100
  let fraction = hundredths % 100
  let decimals = case fraction {
    0 -> ""
    f if f % 10 == 0 -> "." <> int.to_string(f / 10)
    f -> "." <> string.pad_start(int.to_string(f), 2, "0")
  }
  sign <> group_thousands(int.to_string(whole)) <> decimals
}

fn group_thousands(digits: String) -> String {
  case string.length(digits) > 3 {
    True ->
      group_thousands(string.drop_end(digits, 3))
      <> ","
      <> string.slice(digits, string.length(digits) - 3, 3)
    False -> digits
  }
}

// -- Styles ------------------------------------------------------------------

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    polar_class(),
    polar_svg_class(),
    part_legend_class(),
    part_name_class(),
    part_class(),
    centre_value_class(),
    centre_label_class(),
    ring_track_class(),
    radar_grid_class(),
    radar_label_class(),
    radar_shape_class(),
    figure_class(),
    chart_class(),
    gutter_class(),
    plot_class(),
    svg_class(),
    legend_class(),
    key_box_class(),
    key_line_class(),
    grid_class(),
    baseline_class(),
    tick_class(),
    x_label_class(),
    line_class(),
    bar_group_class(),
    bar_slot_class(),
    bar_up_class(),
    bar_down_class(),
    dot_class(),
    end_label_class(),
    column_class(),
    highlight_class(),
    crosshair_class(),
    tip_class(),
    tip_right_class(),
    tip_left_class(),
    tip_label_class(),
    tip_row_class(),
    tip_name_class(),
    details_class(),
    summary_class(),
    table_scroll_class(),
    table_class(),
    caption_class(),
  ]
}

pub fn figure_class() -> Class {
  css.class([css.margin(rem(0.0)), css.color(tokens.text)])
}

pub fn chart_class() -> Class {
  css.class([
    // Axes run left to right, as charts usually do in right-to-left text.
    css.property("direction", "ltr"),
    css.position("relative"),
    css.font_family(tokens.font_body),
    css.font_size_("12px"),
    css.line_height("1"),
  ])
}

pub fn gutter_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("left", "0"),
    css.property("top", "0"),
    css.property("bottom", "0"),
  ])
}

pub fn plot_class() -> Class {
  // Its own stacking context, so a column's highlight sits behind the bars
  // but in front of the card.
  css.class([css.position("absolute"), css.property("isolation", "isolate")])
}

pub fn svg_class() -> Class {
  css.class([
    css.position("absolute"),
    css.inset("0"),
    css.width(percent(100)),
    css.height(percent(100)),
    css.overflow("visible"),
  ])
}

pub fn legend_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.gap(rem(1.0)),
    css.margin_("0 0 " <> tokens.space_2),
    css.padding(rem(0.0)),
    css.list_style("none"),
    css.font_size(rem(0.8125)),
    css.color(tokens.text_muted),
    css.selector(" > li", [
      css.display("inline-flex"),
      css.align_items("center"),
      css.gap(rem(0.375)),
    ]),
  ])
}

pub fn key_box_class() -> Class {
  css.class([
    css.display("inline-block"),
    css.property("width", "10px"),
    css.property("height", "10px"),
    css.property("border-radius", "2px"),
  ])
}

pub fn key_line_class() -> Class {
  css.class([
    css.display("inline-block"),
    css.flex_shrink(0.0),
    css.property("width", "12px"),
    css.property("height", "2px"),
    css.property("border-radius", "1px"),
  ])
}

fn rule() -> List(css.Style) {
  [
    css.property("stroke-width", "1"),
    css.property("vector-effect", "non-scaling-stroke"),
    css.property("shape-rendering", "crispEdges"),
  ]
}

pub fn grid_class() -> Class {
  css.class([css.property("stroke", tokens.border), ..rule()])
}

pub fn baseline_class() -> Class {
  css.class([
    css.property("stroke", tokens.text_muted),
    css.property("stroke-opacity", "0.6"),
    ..rule()
  ])
}

pub fn tick_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("right", "8px"),
    css.transform_("translateY(-50%)"),
    css.color(tokens.text_muted),
    css.white_space("nowrap"),
    css.property("font-variant-numeric", "tabular-nums"),
  ])
}

pub fn x_label_class() -> Class {
  css.class([
    css.position("absolute"),
    css.transform_("translateX(-50%)"),
    css.color(tokens.text_muted),
    css.white_space("nowrap"),
  ])
}

pub fn line_class() -> Class {
  css.class([
    css.property("fill", "none"),
    css.property("stroke-width", "2"),
    css.property("stroke-linejoin", "round"),
    css.property("stroke-linecap", "round"),
    css.property("vector-effect", "non-scaling-stroke"),
  ])
}

pub fn bar_group_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("top", "0"),
    css.property("bottom", "0"),
    css.display("flex"),
    css.justify_content("center"),
    css.gap_("2px"),
  ])
}

pub fn bar_slot_class() -> Class {
  css.class([
    css.position("relative"),
    css.property("flex", "1 1 0"),
    css.property("max-width", "24px"),
  ])
}

pub fn bar_up_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("left", "0"),
    css.property("right", "0"),
    css.property("border-radius", "4px 4px 0 0"),
  ])
}

pub fn bar_down_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("left", "0"),
    css.property("right", "0"),
    css.property("border-radius", "0 0 4px 4px"),
  ])
}

pub fn dot_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("width", "8px"),
    css.property("height", "8px"),
    css.property("border-radius", "50%"),
    css.box_shadow("0 0 0 2px " <> tokens.surface),
    css.transform_("translate(-50%, -50%)"),
  ])
}

pub fn end_label_class() -> Class {
  css.class([
    css.position("absolute"),
    css.transform_("translateY(-50%)"),
    css.color(tokens.text),
    css.white_space("nowrap"),
  ])
}

pub fn column_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("top", "0"),
    css.property("bottom", "-" <> n(bottom_band) <> "px"),
    css.outline("none"),
    css.selector(" [data-reveal]", [css.display("none")]),
    css.selector(":hover [data-reveal]", [css.display("block")]),
    css.selector(":focus-visible [data-reveal]", [css.display("block")]),
    css.selector(":focus-visible", [
      css.property("box-shadow", "inset 0 0 0 2px " <> tokens.focus),
      css.property("border-radius", tokens.radius_small),
    ]),
  ])
}

pub fn highlight_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("inset", "0 0 " <> n(bottom_band) <> "px"),
    css.background(tokens.muted),
    css.property("opacity", "0.5"),
    css.z_index(-1),
  ])
}

pub fn crosshair_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("left", "50%"),
    css.property("top", "0"),
    css.property("height", n(plot_height) <> "px"),
    css.property("border-left", "1px solid " <> tokens.text_muted),
  ])
}

pub fn tip_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("top", "0"),
    css.z_index(1),
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.25)),
    css.padding_("0.375rem 0.5rem"),
    css.background(tokens.surface),
    css.color(tokens.text),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", tokens.radius_small),
    css.box_shadow("0 4px 12px -4px rgb(0 0 0 / 0.25)"),
    css.line_height("1.3"),
    css.white_space("nowrap"),
    css.property("pointer-events", "none"),
  ])
}

pub fn tip_right_class() -> Class {
  css.class([css.property("left", "calc(50% + 14px)")])
}

pub fn tip_left_class() -> Class {
  css.class([css.property("right", "calc(50% + 14px)")])
}

pub fn tip_label_class() -> Class {
  css.class([css.color(tokens.text_muted)])
}

pub fn tip_row_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.gap(rem(0.375)),
  ])
}

pub fn tip_name_class() -> Class {
  css.class([css.color(tokens.text_muted)])
}

pub fn details_class() -> Class {
  css.class([css.margin_(tokens.space_2 <> " 0 0"), css.font_size(rem(0.8125))])
}

pub fn summary_class() -> Class {
  css.class([
    css.color(tokens.text_muted),
    css.cursor("pointer"),
    css.property("width", "fit-content"),
    css.focus_visible([
      css.outline("2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
  ])
}

pub fn table_scroll_class() -> Class {
  css.class([css.overflow_x("auto"), css.margin_(tokens.space_2 <> " 0 0")])
}

pub fn table_class() -> Class {
  css.class([
    css.border_collapse("collapse"),
    css.property("font-variant-numeric", "tabular-nums"),
    css.selector(" th", cell_styles()),
    css.selector(" td", cell_styles()),
    css.selector(" th[scope=\"row\"]", [css.text_align("start")]),
  ])
}

fn cell_styles() -> List(css.Style) {
  [
    css.padding_(tokens.space_1 <> " " <> tokens.space_3),
    css.property("border-bottom", "1px solid " <> tokens.border),
    css.text_align("end"),
  ]
}

pub fn caption_class() -> Class {
  css.class([
    css.text_align("start"),
    css.padding_("0 0 " <> tokens.space_1),
    css.color(tokens.text_muted),
  ])
}

pub fn polar_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.align_items("center"),
    css.gap(rem(1.5)),
  ])
}

pub fn polar_svg_class() -> Class {
  css.class([
    css.display("block"),
    css.property("width", "min(100%, 15rem)"),
    css.height_("auto"),
    css.font_family(tokens.font_body),
    css.overflow("visible"),
    // Pointing at one part fades the others.
    css.selector(":has(g[tabindex]:hover) g[tabindex]:not(:hover)", [
      css.property("opacity", "0.35"),
    ]),
    css.selector(
      ":has(g[tabindex]:focus-visible) g[tabindex]:not(:focus-visible)",
      [
        css.property("opacity", "0.35"),
      ],
    ),
  ])
}

pub fn part_legend_class() -> Class {
  css.class([
    css.display("grid"),
    css.grid_template_columns("auto 1fr auto auto"),
    css.align_items("center"),
    css.column_gap(rem(0.5)),
    css.row_gap(rem(0.375)),
    css.margin(rem(0.0)),
    css.padding(rem(0.0)),
    css.list_style("none"),
    css.font_size(rem(0.875)),
    css.property("font-variant-numeric", "tabular-nums"),
    css.selector(" > li", [css.display("contents")]),
  ])
}

pub fn part_name_class() -> Class {
  css.class([css.color(tokens.text_muted)])
}

pub fn part_class() -> Class {
  css.class([
    css.outline("none"),
    css.transition("opacity 120ms"),
    css.selector(" path", [
      css.property("stroke", tokens.surface),
      css.property("stroke-width", "2"),
    ]),
    css.selector(":focus-visible", [
      css.property("filter", "drop-shadow(0 0 2px " <> tokens.focus <> ")"),
    ]),
  ])
}

pub fn centre_value_class() -> Class {
  css.class([
    css.property("fill", tokens.text),
    css.font_size_("22px"),
    css.font_weight("600"),
  ])
}

pub fn centre_label_class() -> Class {
  css.class([css.property("fill", tokens.text_muted), css.font_size_("11px")])
}

pub fn ring_track_class() -> Class {
  css.class([css.property("stroke", tokens.muted)])
}

pub fn radar_grid_class() -> Class {
  css.class([
    css.property("fill", "none"),
    css.property("stroke", tokens.border),
    css.property("stroke-width", "1"),
  ])
}

pub fn radar_label_class() -> Class {
  css.class([css.property("fill", tokens.text_muted), css.font_size_("11px")])
}

pub fn radar_shape_class() -> Class {
  css.class([
    css.property("fill-opacity", "0.1"),
    css.property("stroke-width", "2"),
    css.property("stroke-linejoin", "round"),
  ])
}
