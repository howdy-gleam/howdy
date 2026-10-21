//// The values components use in place of colours, fonts and radii. Each is
//// a `var()` reference to a property every theme defines, so a class built
//// from tokens looks right under any theme without being re-rendered.
////
//// ```gleam
//// import howdy/ui/theme/tokens
//// import sketch/css
////
//// fn badge() -> css.Class {
////   css.class([
////     css.background(tokens.primary),
////     css.color(tokens.on_primary),
////     css.property("border-radius", tokens.radius_small),
////   ])
//// }
//// ```
////
//// Spacing is not themed. It is a fixed scale in rem so layouts stay stable
//// when the theme changes.

pub const background = "var(--howdy-background)"

pub const surface = "var(--howdy-surface)"

pub const muted = "var(--howdy-muted)"

pub const border = "var(--howdy-border)"

pub const text = "var(--howdy-text)"

pub const text_muted = "var(--howdy-text-muted)"

pub const primary = "var(--howdy-primary)"

pub const primary_hover = "var(--howdy-primary-hover)"

pub const on_primary = "var(--howdy-on-primary)"

pub const danger = "var(--howdy-danger)"

pub const on_danger = "var(--howdy-on-danger)"

pub const focus = "var(--howdy-focus)"

pub const chart_1 = "var(--howdy-chart-1)"

pub const chart_2 = "var(--howdy-chart-2)"

pub const chart_3 = "var(--howdy-chart-3)"

pub const chart_4 = "var(--howdy-chart-4)"

pub const chart_5 = "var(--howdy-chart-5)"

/// The chart series colours in order.
pub const chart = [chart_1, chart_2, chart_3, chart_4, chart_5]

pub const font_body = "var(--howdy-font-body)"

pub const font_heading = "var(--howdy-font-heading)"

pub const font_mono = "var(--howdy-font-mono)"

pub const radius_small = "var(--howdy-radius-small)"

pub const radius_medium = "var(--howdy-radius-medium)"

pub const radius_large = "var(--howdy-radius-large)"

/// Every token, paired with the property it reads. Used by tests to check
/// each token is defined by `theme.variables`.
pub fn all() -> List(#(String, String)) {
  [
    #("--howdy-background", background),
    #("--howdy-surface", surface),
    #("--howdy-muted", muted),
    #("--howdy-border", border),
    #("--howdy-text", text),
    #("--howdy-text-muted", text_muted),
    #("--howdy-primary", primary),
    #("--howdy-primary-hover", primary_hover),
    #("--howdy-on-primary", on_primary),
    #("--howdy-danger", danger),
    #("--howdy-on-danger", on_danger),
    #("--howdy-focus", focus),
    #("--howdy-chart-1", chart_1),
    #("--howdy-chart-2", chart_2),
    #("--howdy-chart-3", chart_3),
    #("--howdy-chart-4", chart_4),
    #("--howdy-chart-5", chart_5),
    #("--howdy-font-body", font_body),
    #("--howdy-font-heading", font_heading),
    #("--howdy-font-mono", font_mono),
    #("--howdy-radius-small", radius_small),
    #("--howdy-radius-medium", radius_medium),
    #("--howdy-radius-large", radius_large),
  ]
}

// -- Spacing -----------------------------------------------------------------

pub const space_1 = "0.25rem"

pub const space_2 = "0.5rem"

pub const space_3 = "0.75rem"

pub const space_4 = "1rem"

pub const space_6 = "1.5rem"

pub const space_8 = "2rem"
