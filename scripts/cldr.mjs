#!/usr/bin/env node
// Generates howdy_i18n's locale data from the Unicode CLDR.
//
//   node scripts/cldr.mjs
//
// Downloads the pinned CLDR JSON release (cached under the system temp
// directory) and writes, under i18n/src/howdy/i18n/:
//
// - plural.gleam: cardinal and ordinal plural rules for every language
// - internal/plural_source.gleam: the same rules as Gleam source, for
//   catalogues generated with --standalone
// - internal/cldr.gleam: the locale table, parents and currency digits
// - internal/cldr/<locale>.gleam: numbers, dates, relative times, lists
//   and currency symbols for each locale in LOCALES
//
// Plural rules are compiled for whole numbers only: the operands for
// visible fraction digits are zero.

import { mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const VERSION = '48.0.0';
const BASE = `https://raw.githubusercontent.com/unicode-org/cldr-json/${VERSION}/cldr-json`;
const CACHE = join(tmpdir(), `howdy-cldr-${VERSION}`);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(ROOT, 'i18n', 'src', 'howdy', 'i18n');

// The locales with formatting data. Others fall back along their parents,
// and finally to English.
const LOCALES = [
  'ar', 'bg', 'bn', 'cs', 'da', 'de', 'de-AT', 'de-CH', 'el', 'en', 'en-AU',
  'en-CA', 'en-GB', 'en-IN', 'es', 'es-419', 'es-MX', 'fa', 'fi', 'fr',
  'fr-CA', 'fr-CH', 'he', 'hi', 'hr', 'hu', 'id', 'it', 'ja', 'ko', 'ms',
  'nb', 'nl', 'pl', 'pt', 'pt-PT', 'ro', 'ru', 'sk', 'sv', 'th', 'tr', 'uk',
  'vi', 'zh', 'zh-Hant',
];

// Currencies with symbols in each locale's data. Any other code is shown
// as the code itself.
const CURRENCIES = [
  'AED', 'ARS', 'AUD', 'BGN', 'BRL', 'CAD', 'CHF', 'CLP', 'CNY', 'COP',
  'CZK', 'DKK', 'EGP', 'EUR', 'GBP', 'HKD', 'HUF', 'IDR', 'ILS', 'INR',
  'JPY', 'KRW', 'MXN', 'MYR', 'NGN', 'NOK', 'NZD', 'PHP', 'PKR', 'PLN',
  'RON', 'RUB', 'SAR', 'SEK', 'SGD', 'THB', 'TRY', 'TWD', 'UAH', 'USD',
  'VND', 'ZAR',
];

const UNITS = ['year', 'quarter', 'month', 'week', 'day', 'hour', 'minute', 'second'];

async function fetchJson(path) {
  const file = join(CACHE, path);
  if (!existsSync(file)) {
    const response = await fetch(`${BASE}/${path}`);
    if (!response.ok) throw new Error(`${response.status} for ${path}`);
    await mkdir(dirname(file), { recursive: true });
    await writeFile(file, await response.text());
  }
  return JSON.parse(await readFile(file, 'utf8'));
}

// -- Gleam helpers -----------------------------------------------------------

function str(text) {
  return '"' + text
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/\n/g, '\\n') + '"';
}

function strList(items, indent = '    ') {
  return '[\n' + items.map((item) => `${indent}  ${str(item)},`).join('\n') + `\n${indent}]`;
}

function moduleName(tag) {
  return tag.toLowerCase().replace(/-/g, '_');
}

// -- Plural rules ------------------------------------------------------------

// A rule is `condition @integer samples @decimal samples`. Only the
// condition matters. Compiled with the operands for an integer `n`: i = n,
// and v, w, f, t, c and e are all zero.
function compileCondition(source) {
  const condition = source.split('@')[0].trim();
  if (condition === '') return 'True';
  const ors = condition.split(/\s+or\s+/).map((and) => {
    const parts = and.split(/\s+and\s+/).map(compileRelation);
    if (parts.includes('False')) return { code: 'False' };
    const kept = parts.filter((p) => p !== 'True');
    if (kept.length === 0) return { code: 'True' };
    return { code: kept.join(' && '), compound: kept.length > 1 };
  });
  if (ors.some((p) => p.code === 'True')) return 'True';
  const kept = ors.filter((p) => p.code !== 'False');
  if (kept.length === 0) return 'False';
  if (kept.length === 1) return kept[0].code;
  return kept.map((p) => (p.compound ? `{ ${p.code} }` : p.code)).join(' || ');
}

function compileRelation(relation) {
  const match = relation.trim().match(/^([niftvwce])\s*(?:%\s*(\d+))?\s*(!=|=)\s*(.+)$/);
  if (!match) throw new Error(`unsupported plural relation: ${relation}`);
  const [, operand, modulus, op, ranges] = match;
  if (!['n', 'i'].includes(operand)) {
    // The operand is zero for integers.
    const value = 0;
    const inside = ranges.split(',').some((range) => {
      const [low, high] = range.split('..').map(Number);
      return high === undefined ? value === low : value >= low && value <= high;
    });
    return (op === '=') === inside ? 'True' : 'False';
  }
  const expr = modulus ? `n % ${modulus}` : 'n';
  const tests = ranges.split(',').map((range) => {
    const [low, high] = range.trim().split('..');
    return high === undefined ? `${expr} == ${low}` : `{ ${expr} >= ${low} && ${expr} <= ${high} }`;
  });
  if (op === '=') return tests.length === 1 ? tests[0] : `{ ${tests.join(' || ')} }`;
  if (tests.length === 1 && !tests[0].startsWith('{')) return tests[0].replace(' == ', ' != ');
  return `!${tests.length === 1 ? tests[0] : `{ ${tests.join(' || ')} }`}`;
}

const CATEGORY_ORDER = ['zero', 'one', 'two', 'few', 'many', 'other'];

// Gleam source for a rule set: a nested case returning `wrap(category)`.
function ruleBody(rules, wrap, indent) {
  const cases = CATEGORY_ORDER
    .filter((category) => category !== 'other' && rules[`pluralRule-count-${category}`])
    .map((category) => [category, compileCondition(rules[`pluralRule-count-${category}`])])
    .filter(([, condition]) => condition !== 'False');
  let body = wrap('other');
  for (const [category, condition] of cases.reverse()) {
    body = condition === 'True'
      ? wrap(category)
      : `case ${condition} {\n${indent}  True -> ${wrap(category)}\n${indent}  False -> ${body.replace(/\n/g, '\n  ')}\n${indent}}`;
  }
  return body;
}

function categoriesOf(rules) {
  return CATEGORY_ORDER.filter((category) => rules[`pluralRule-count-${category}`]);
}

async function plurals() {
  const cardinal = (await fetchJson('cldr-core/supplemental/plurals.json')).supplemental['plurals-type-cardinal'];
  const ordinal = (await fetchJson('cldr-core/supplemental/ordinals.json')).supplemental['plurals-type-ordinal'];

  const titleCase = (category) => category[0].toUpperCase() + category.slice(1);
  const group = (table, kind) => {
    const bodies = new Map();
    for (const [tag, rules] of Object.entries(table).sort()) {
      if (tag === 'root') continue;
      const body = ruleBody(rules, titleCase, '  ');
      const source = ruleBody(rules, (c) => `"${c}"`, '  ');
      const key = body;
      if (!bodies.has(key)) bodies.set(key, { name: `${kind}_${bodies.size}`, body, source, tags: [], categories: categoriesOf(rules) });
      bodies.get(key).tags.push(tag);
    }
    return [...bodies.values()];
  };
  const cardinals = group(cardinal, 'cardinal');
  const ordinals = group(ordinal, 'ordinal');

  const usesN = (body) => /\bn\b/.test(body);
  const functions = (groups) => groups.map((g) =>
    `fn ${g.name}(${usesN(g.body) ? 'n' : '_n'}: Int) -> Category {\n  ${g.body}\n}`).join('\n\n');
  const lookup = (name, groups) => {
    const arms = groups.map((g) => `    ${g.tags.map(str).join(' | ')} -> Ok(${g.name})`).join('\n');
    return `fn ${name}(tag: String) -> Result(fn(Int) -> Category, Nil) {\n  case tag {\n${arms}\n    _ -> Error(Nil)\n  }\n}`;
  };
  const categoryLookup = (name, groups) => {
    const arms = groups.map((g) => `    ${g.tags.map(str).join(' | ')} -> Ok([${g.categories.map(titleCase).join(', ')}])`).join('\n');
    return `fn ${name}(tag: String) -> Result(List(Category), Nil) {\n  case tag {\n${arms}\n    _ -> Error(Nil)\n  }\n}`;
  };

  const pluralModule = `//// Plural categories: which form of a word a number takes.
////
//// English has two cardinal forms, "1 day" and "2 days"; Polish has four,
//// Arabic six. \`cardinal\` picks the category for a count, and \`ordinal\`
//// the one for a position, as in "1st" and "2nd".
////
//// Rules come from CLDR ${VERSION} and cover whole numbers. A tag that has
//// no rules of its own uses its language's; a language with no rules at all
//// uses \`Other\` for everything.

// Generated by scripts/cldr.mjs. Do not edit.

import gleam/int
import gleam/result
import gleam/string

pub type Category {
  Zero
  One
  Two
  Few
  Many
  Other
}

/// The category for a count, such as \`One\` for 1 in English.
pub fn cardinal(locale: String, count: Int) -> Category {
  case resolve(locale, cardinal_rule) {
    Ok(rule) -> rule(int.absolute_value(count))
    Error(Nil) -> Other
  }
}

/// The category for a position, such as \`Two\` for 2 ("2nd") in English.
pub fn ordinal(locale: String, position: Int) -> Category {
  case resolve(locale, ordinal_rule) {
    Ok(rule) -> rule(int.absolute_value(position))
    Error(Nil) -> Other
  }
}

/// The cardinal categories a locale uses, in the order Zero to Other.
pub fn cardinal_categories(locale: String) -> List(Category) {
  resolve(locale, cardinal_category_list) |> result.unwrap([Other])
}

/// The ordinal categories a locale uses, in the order Zero to Other.
pub fn ordinal_categories(locale: String) -> List(Category) {
  resolve(locale, ordinal_category_list) |> result.unwrap([Other])
}

/// The category's name in ICU messages: \`one\`, \`few\` and so on.
pub fn to_string(category: Category) -> String {
  case category {
    Zero -> "zero"
    One -> "one"
    Two -> "two"
    Few -> "few"
    Many -> "many"
    Other -> "other"
  }
}

pub fn from_string(name: String) -> Result(Category, Nil) {
  case name {
    "zero" -> Ok(Zero)
    "one" -> Ok(One)
    "two" -> Ok(Two)
    "few" -> Ok(Few)
    "many" -> Ok(Many)
    "other" -> Ok(Other)
    _ -> Error(Nil)
  }
}

fn resolve(
  locale: String,
  find: fn(String) -> Result(a, Nil),
) -> Result(a, Nil) {
  let locale = string.replace(locale, "_", "-")
  use <- result.lazy_or(find(locale))
  case string.split_once(locale, "-") {
    Ok(#(language, _)) -> find(string.lowercase(language))
    Error(Nil) -> find(string.lowercase(locale))
  }
}

${lookup('cardinal_rule', cardinals)}

${lookup('ordinal_rule', ordinals)}

${categoryLookup('cardinal_category_list', cardinals)}

${categoryLookup('ordinal_category_list', ordinals)}

${functions(cardinals)}

${functions(ordinals)}
`;

  const sourceArms = (groups) => groups.map((g) => `    ${g.tags.map(str).join(' | ')} ->\n      Ok(${str(g.source)})`).join('\n');
  const sourceModule = `//// Plural rules as Gleam source, for catalogues generated with
//// \`--standalone\`, which inline them rather than depend on this package.
//// Each is the body of a function of \`n: Int\` returning the category name.

// Generated by scripts/cldr.mjs. Do not edit.

import gleam/result
import gleam/string

@internal
pub fn cardinal(locale: String) -> Result(String, Nil) {
  let locale = string.replace(locale, "_", "-")
  use <- result.lazy_or(cardinal_source(locale))
  case string.split_once(locale, "-") {
    Ok(#(language, _)) -> cardinal_source(string.lowercase(language))
    Error(Nil) -> Error(Nil)
  }
}

fn cardinal_source(tag: String) -> Result(String, Nil) {
  case tag {
${sourceArms(cardinals)}
    _ -> Error(Nil)
  }
}
`;
  await writeFile(join(OUT, 'plural.gleam'), pluralModule);
  await writeFile(join(OUT, 'internal', 'plural_source.gleam'), sourceModule);
}

// -- Locale data -------------------------------------------------------------

const WEEKDAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

// Time zones are not supported yet, so zone fields are dropped from time
// patterns, with the spacing around them.
function stripZone(pattern) {
  return pattern
    .replace(/\s*\(?\b(z{1,4}|Z{1,5}|v{1,4}|V{1,4}|O{1,4}|X{1,5}|x{1,5})\b\)?\s*/g, ' ')
    .trim();
}

function digitsFor(numbers, system) {
  // Numbering systems with decimal digits we substitute.
  const systems = {
    latn: '',
    arab: '٠١٢٣٤٥٦٧٨٩',
    arabext: '۰۱۲۳۴۵۶۷۸۹',
    beng: '০১২৩৪৫৬৭৮৯',
    deva: '०१२३४५६७८९',
  };
  if (!(system in systems)) throw new Error(`unsupported numbering system ${system}`);
  return systems[system];
}

async function localeData(tag, supplemental) {
  const numbersFile = (await fetchJson(`cldr-numbers-full/main/${tag}/numbers.json`)).main[tag].numbers;
  const currenciesFile = (await fetchJson(`cldr-numbers-full/main/${tag}/currencies.json`)).main[tag].numbers.currencies;
  const gregorian = (await fetchJson(`cldr-dates-full/main/${tag}/ca-gregorian.json`)).main[tag].dates.calendars.gregorian;
  const fields = (await fetchJson(`cldr-dates-full/main/${tag}/dateFields.json`)).main[tag].dates.fields;
  const lists = (await fetchJson(`cldr-misc-full/main/${tag}/listPatterns.json`)).main[tag].listPatterns;
  const languages = (await fetchJson(`cldr-localenames-full/main/${tag}/languages.json`)).main[tag].localeDisplayNames.languages;
  const territories = (await fetchJson(`cldr-localenames-full/main/${tag}/territories.json`)).main[tag].localeDisplayNames.territories;

  const system = numbersFile.defaultNumberingSystem;
  const symbols = numbersFile[`symbols-numberSystem-${system}`];
  const numbers = {
    decimal: symbols.decimal,
    group: symbols.group,
    currencyDecimal: symbols.currencyDecimal ?? symbols.decimal,
    currencyGroup: symbols.currencyGroup ?? symbols.group,
    minus: symbols.minusSign,
    percent: symbols.percentSign,
    digits: digitsFor(numbersFile, system),
    decimalPattern: numbersFile[`decimalFormats-numberSystem-${system}`].standard,
    percentPattern: numbersFile[`percentFormats-numberSystem-${system}`].standard,
    currencyPattern: numbersFile[`currencyFormats-numberSystem-${system}`].standard,
    minimumGrouping: Number(numbersFile.minimumGroupingDigits),
  };

  const months = (context, width) =>
    Array.from({ length: 12 }, (_, i) => gregorian.months[context][width][String(i + 1)]);
  const days = (context, width) => WEEKDAYS.map((day) => gregorian.days[context][width][day]);
  const styles = (table, transform = (p) => p) => ({
    full: transform(table.full), long: transform(table.long),
    medium: transform(table.medium), short: transform(table.short),
  });
  const dateTime = gregorian.dateTimeFormats;
  const dates = {
    months: months('format', 'wide'),
    monthsShort: months('format', 'abbreviated'),
    monthsStandalone: months('stand-alone', 'wide'),
    monthsNarrow: months('stand-alone', 'narrow'),
    weekdays: days('format', 'wide'),
    weekdaysShort: days('format', 'abbreviated'),
    weekdaysNarrow: days('stand-alone', 'short'),
    am: gregorian.dayPeriods.format.abbreviated.am,
    pm: gregorian.dayPeriods.format.abbreviated.pm,
    eras: [gregorian.eras.eraAbbr['0'], gregorian.eras.eraAbbr['1']],
    date: styles(gregorian.dateFormats),
    time: styles(gregorian.timeFormats, stripZone),
    dateTime: styles(dateTime),
    monthYear: dateTime.availableFormats.yMMMM ?? dateTime.availableFormats.yMMM,
    monthDay: dateTime.availableFormats.MMMMd ?? dateTime.availableFormats.MMMd,
  };

  const relative = UNITS.map((unit) => {
    const field = fields[unit];
    const forms = (direction) => Object.entries(field[`relativeTime-type-${direction}`] ?? {})
      .map(([key, pattern]) => [key.replace('relativeTimePattern-count-', ''), pattern]);
    const named = Object.entries(field)
      .filter(([key]) => key.startsWith('relative-type-'))
      .map(([key, text]) => [Number(key.replace('relative-type-', '')), text])
      .sort((a, b) => a[0] - b[0]);
    return { unit, future: forms('future'), past: forms('past'), named };
  });

  const listPattern = (type) => {
    const p = lists[`listPattern-type-${type}`];
    return { two: p['2'], start: p.start, middle: p.middle, end: p.end };
  };

  const currencies = CURRENCIES
    .filter((code) => currenciesFile[code]?.symbol)
    .map((code) => [code, currenciesFile[code].symbol]);

  const [language, ...rest] = tag.split('-');
  const region = rest.find((part) => /^[A-Z]{2}$|^\d{3}$/.test(part));
  let name = languages[tag] ?? languages[language];
  if (!languages[tag] && region && territories[region]) name = `${name} (${territories[region]})`;

  const likely = supplemental.likely[tag] ?? supplemental.likely[language] ?? 'und-Latn-001';
  const likelyRegion = region ?? likely.split('-').find((part) => /^[A-Z]{2}$|^\d{3}$/.test(part)) ?? '001';
  const firstDay = supplemental.firstDay[likelyRegion] ?? supplemental.firstDay['001'];

  return { tag, name, firstDay: WEEKDAYS.indexOf(firstDay) + 1, numbers, dates, relative, lists: { and: listPattern('standard'), or: listPattern('or') }, currencies };
}

function styleSource(styles) {
  return `data.Styles(\n      full: ${str(styles.full)},\n      long: ${str(styles.long)},\n      medium: ${str(styles.medium)},\n      short: ${str(styles.short)},\n    )`;
}

function pairs(items, show = str, indent = '      ') {
  if (items.length === 0) return '[]';
  return '[\n' + items.map(([a, b]) => `${indent}#(${show(a)}, ${str(b)}),`).join('\n') + `\n${indent.slice(2)}]`;
}

function listSource(p) {
  return `data.ListPattern(\n        two: ${str(p.two)},\n        start: ${str(p.start)},\n        middle: ${str(p.middle)},\n        end: ${str(p.end)},\n      )`;
}

function localeModule(d) {
  const n = d.numbers;
  const relative = d.relative.map((r) => `    #(\n      ${str(r.unit)},\n      data.Relative(\n        future: ${pairs(r.future, str, '          ')},\n        past: ${pairs(r.past, str, '          ')},\n        named: ${pairs(r.named, String, '          ')},\n      ),\n    ),`).join('\n');
  return `// Generated by scripts/cldr.mjs from CLDR ${VERSION}. Do not edit.

import howdy/i18n/internal/data

pub fn data() -> data.Data {
  data.Data(
    tag: ${str(d.tag)},
    name: ${str(d.name)},
    first_day: ${d.firstDay},
    numbers: data.Numbers(
      decimal: ${str(n.decimal)},
      group: ${str(n.group)},
      currency_decimal: ${str(n.currencyDecimal)},
      currency_group: ${str(n.currencyGroup)},
      minus: ${str(n.minus)},
      percent: ${str(n.percent)},
      digits: ${str(n.digits)},
      decimal_pattern: ${str(n.decimalPattern)},
      percent_pattern: ${str(n.percentPattern)},
      currency_pattern: ${str(n.currencyPattern)},
      minimum_grouping: ${n.minimumGrouping},
    ),
    dates: data.Dates(
      months: ${strList(d.dates.months, '      ')},
      months_short: ${strList(d.dates.monthsShort, '      ')},
      months_standalone: ${strList(d.dates.monthsStandalone, '      ')},
      months_narrow: ${strList(d.dates.monthsNarrow, '      ')},
      weekdays: ${strList(d.dates.weekdays, '      ')},
      weekdays_short: ${strList(d.dates.weekdaysShort, '      ')},
      weekdays_narrow: ${strList(d.dates.weekdaysNarrow, '      ')},
      am: ${str(d.dates.am)},
      pm: ${str(d.dates.pm)},
      eras: #(${str(d.dates.eras[0])}, ${str(d.dates.eras[1])}),
      date: ${styleSource(d.dates.date)},
      time: ${styleSource(d.dates.time)},
      date_time: ${styleSource(d.dates.dateTime)},
      month_year: ${str(d.dates.monthYear)},
      month_day: ${str(d.dates.monthDay)},
    ),
    relative: [
${relative}
    ],
    lists: data.Lists(
      and: ${listSource(d.lists.and)},
      or: ${listSource(d.lists.or)},
    ),
    currencies: ${pairs(d.currencies, str, '      ')},
  )
}
`;
}

async function locales() {
  const likely = (await fetchJson('cldr-core/supplemental/likelySubtags.json')).supplemental.likelySubtags;
  const weekData = (await fetchJson('cldr-core/supplemental/weekData.json')).supplemental.weekData;
  const currencyData = (await fetchJson('cldr-core/supplemental/currencyData.json')).supplemental.currencyData;
  const parentLocales = (await fetchJson('cldr-core/supplemental/parentLocales.json')).supplemental.parentLocales.parentLocale;
  const supplemental = { likely, firstDay: weekData.firstDay };

  await rm(join(OUT, 'internal', 'cldr'), { recursive: true, force: true });
  await mkdir(join(OUT, 'internal', 'cldr'), { recursive: true });
  for (const tag of LOCALES) {
    const d = await localeData(tag, supplemental);
    await writeFile(join(OUT, 'internal', 'cldr', `${moduleName(tag)}.gleam`), localeModule(d));
  }

  // Parents that are not simply the tag with its last subtag removed, for
  // the languages with data, such as es-AR -> es-419.
  const languages = new Set(LOCALES.map((tag) => tag.split('-')[0]));
  const parents = Object.entries(parentLocales)
    // A parent of root marks where falling back must stop, as zh-Hant
    // must not fall back to zh, which is written in simplified characters.
    .filter(([child]) => languages.has(child.split('-')[0]))
    .sort(([a], [b]) => a.localeCompare(b));
  const digits = Object.entries(currencyData.fractions)
    .filter(([code, info]) => code !== 'DEFAULT' && Number(info._digits) !== 2)
    .sort(([a], [b]) => a.localeCompare(b));
  const byDigits = new Map();
  for (const [code, info] of digits) {
    const n = Number(info._digits);
    if (!byDigits.has(n)) byDigits.set(n, []);
    byDigits.get(n).push(code);
  }

  const imports = LOCALES.map((tag) => `import howdy/i18n/internal/cldr/${moduleName(tag)}`).join('\n');
  const arms = LOCALES.map((tag) => `    ${str(tag)} -> Ok(${moduleName(tag)}.data())`).join('\n');
  const parentArms = parents.map(([child, parent]) => `    ${str(child)} -> Ok(${str(parent)})`).join('\n');
  const digitArms = [...byDigits.entries()].map(([n, codes]) => `    ${codes.map(str).join(' | ')} -> ${n}`).join('\n');
  const module = `//// The locales with formatting data, from CLDR ${VERSION}.

// Generated by scripts/cldr.mjs. Do not edit.

import howdy/i18n/internal/data.{type Data}
${imports}

@internal
pub const version = ${str(VERSION)}

@internal
pub const locales = ${strList(LOCALES, '')}

@internal
pub fn lookup(tag: String) -> Result(Data, Nil) {
  case tag {
${arms}
    _ -> Error(Nil)
  }
}

/// The parent of a tag when it is not the tag with its last part removed.
/// \`root\` means there is none: stop falling back.
@internal
pub fn parent(tag: String) -> Result(String, Nil) {
  case tag {
${parentArms}
    _ -> Error(Nil)
  }
}

/// How many digits follow the decimal point in an amount of a currency.
@internal
pub fn currency_digits(code: String) -> Int {
  case code {
${digitArms}
    _ -> 2
  }
}
`;
  await writeFile(join(OUT, 'internal', 'cldr.gleam'), module);
}

await mkdir(join(OUT, 'internal'), { recursive: true });
await plurals();
await locales();
execFileSync('gleam', ['format', join(OUT, 'plural.gleam'), join(OUT, 'internal')], { stdio: 'inherit' });
console.log(`Wrote CLDR ${VERSION} data for ${LOCALES.length} locales to ${OUT}`);
