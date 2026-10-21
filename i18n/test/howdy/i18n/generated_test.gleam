// Calls the module generated from test/fixtures/locales. Regenerate it with
// gleam run -m howdy/i18n/cli -- gen --locales=test/fixtures/locales
//   --out=test/howdy/i18n/fixture_messages.gleam

import gleam/time/calendar
import howdy/i18n
import howdy/i18n/fixture_messages as messages

pub fn picks_the_catalogue_test() {
  assert messages.greeting(i18n.new("en"), name: "Ann") == "Hello, Ann!"
  assert messages.greeting(i18n.new("de-AT"), name: "Ann") == "Hallo, Ann!"
  // Polish has no greeting, so the source is used.
  assert messages.greeting(i18n.new("pl"), name: "Ann") == "Hello, Ann!"
  assert messages.sign_in(i18n.new("de")) == "Sign in"
  assert messages.locales == ["de", "en", "en-GB", "pl"]
  assert messages.source == "en"
}

pub fn the_source_beats_a_sibling_test() {
  assert messages.greeting(i18n.new("en-GB"), name: "Ann") == "Hiya, Ann!"
  // American English is closer to the source, en, than to en-GB.
  assert messages.greeting(i18n.new("en-US"), name: "Ann") == "Hello, Ann!"
}

pub fn plurals_test() {
  let en = i18n.new("en")
  assert messages.cart_items(en, count: 0) == "Your cart is empty"
  assert messages.cart_items(en, count: 1) == "1 item"
  assert messages.cart_items(en, count: 1200) == "1,200 items"
  let pl = i18n.new("pl")
  assert messages.cart_items(pl, count: 1) == "1 produkt"
  assert messages.cart_items(pl, count: 3) == "3 produkty"
  assert messages.cart_items(pl, count: 5) == "5 produktów"
  assert messages.cart_items(pl, count: 22) == "22 produkty"
  assert messages.cart_items(i18n.new("de"), count: 1200) == "1.200 Artikel"
}

pub fn offsets_test() {
  let en = i18n.new("en")
  let invite = fn(guests) {
    messages.invite(en, host: "Ann", guests:, guest: "Ben")
  }
  assert invite(0) == "Ann invited nobody"
  assert invite(1) == "Ann invited Ben"
  assert invite(2) == "Ann invited Ben and one other"
  assert invite(5) == "Ann invited Ben and 4 others"
}

pub fn selects_and_ordinals_test() {
  assert messages.reply(i18n.new("en"), gender: "female") == "She replied"
  assert messages.reply(i18n.new("en"), gender: "x") == "They replied"
  assert messages.reply(i18n.new("de"), gender: "male") == "Er hat geantwortet"
  assert messages.place(i18n.new("en"), place: 22) == "You came 22nd"
  assert messages.place(i18n.new("en"), place: 13) == "You came 13th"
  assert messages.place(i18n.new("de"), place: 3) == "Du bist 3. geworden"
}

pub fn formatted_arguments_test() {
  let date = calendar.Date(2026, calendar.October, 19)
  let at = calendar.TimeOfDay(9, 30, 0, 0)
  assert messages.saved(i18n.new("de"), when: date, at:)
    == "Gespeichert am 19. Oktober 2026 um 09:30"
  assert messages.progress(i18n.new("en"), ratio: 0.5) == "50% done"
}

pub fn quotes_test() {
  assert messages.quote(i18n.new("en")) == "It's {literal}"
}
