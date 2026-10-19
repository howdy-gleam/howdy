# howdy_i18n_example

A small app in English, German, French and Arabic:

- `locale.negotiator` picks the language from the path (`/de/`), the
  visitor's choice (a cookie set by the language switcher), or the
  browser's `accept-language`.
- Messages live in `locales/*.json`, written in ICU MessageFormat, and
  `gleam run -m howdy/i18n/cli -- gen` turns them into
  `src/howdy_i18n_example/messages.gleam`.
- `howdy/i18n/format` writes the price, the date, a relative time and a
  list for each locale.
- The sign-up form's validation messages come from `howdy/problem`, in the
  page's language.
- Arabic pages run right to left.

```sh
gleam run      # http://127.0.0.1:8793
gleam test
```
