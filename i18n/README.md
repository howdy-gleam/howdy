# howdy_i18n

Translations for [howdy](https://github.com/howdy-gleam/howdy/blob/v1.0.0/README.md)
apps: ICU MessageFormat catalogues turned into typed Gleam functions, CLDR
plural rules, and numbers, money, dates, relative times and lists written
the way each locale writes them.

```sh
gleam add howdy_i18n@1
```

It depends on nothing else from Howdy, and runs on Erlang and JavaScript.

## Messages

Write a catalogue per locale, `locales/en.json`:

```json
{
  "greeting": "Hello, {name}!",
  "cart.items": "{count, plural, =0 {Your cart is empty} one {# item} other {# items}}"
}
```

and `locales/de.json`:

```json
{
  "greeting": "Hallo, {name}!",
  "cart.items": "{count, plural, =0 {Ihr Warenkorb ist leer} one {# Artikel} other {# Artikel}}"
}
```

Generate a module with a function for each message:

```sh
gleam run -m howdy/i18n/cli -- gen
```

```gleam
import howdy/i18n
import my_app/messages

let t = i18n.new("de")
messages.greeting(t, name: "Ada")    // "Hallo, Ada!"
messages.cart_items(t, count: 3)     // "3 Artikel"
```

A misspelt message, or a missing or wrongly typed argument, does not
compile. `gleam run -m howdy/i18n/cli -- check` reports missing
translations, plural forms a language needs but a message lacks, and
invalid syntax, for CI.

## Formatting

```gleam
import howdy/i18n/format

format.integer(t, 1_234_567)                      // "1.234.567"
format.currency(t, minor: 123_456, code: "EUR")   // "1.234,56 €"
format.date(t, date, format.Long)                 // "19. Oktober 2026"
format.relative(t, -1, format.Day)                // "gestern"
format.list(t, ["Anna", "Ben", "Cem"])            // "Anna, Ben und Cem"
```

The data comes from CLDR 48 and covers 46 locales. `scripts/cldr.mjs`
regenerates it from the pinned release.

## Choosing the locale

Core's `howdy/locale` negotiates a request's locale from the URL, a cookie,
a saved preference or `accept-language`. Pass its tag to `i18n.new`:

```gleam
let t = i18n.new(locale.to_string(locale.detect(ctx, locales)))
```

See the [internationalisation docs](https://github.com/howdy-gleam/howdy/blob/v1.0.0/docs/i18n/overview.djot)
for the whole story, including Howdy's own translated validation messages,
UI components and auth pages.
