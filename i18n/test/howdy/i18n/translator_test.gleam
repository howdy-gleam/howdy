import howdy/i18n

pub fn canonical_test() {
  assert i18n.canonical("EN-us") == "en-US"
  assert i18n.canonical("zh_hant_tw") == "zh-Hant-TW"
  assert i18n.canonical("zh-TW") == "zh-Hant-TW"
  assert i18n.canonical("es-419") == "es-419"
  assert i18n.canonical("") == "und"
}

pub fn fallbacks_test() {
  assert i18n.fallbacks(i18n.new("de-CH")) == ["de-CH", "de"]
  assert i18n.fallbacks(i18n.new("es-AR")) == ["es-AR", "es-419", "es"]
  assert i18n.fallbacks(i18n.new("en-NZ")) == ["en-NZ", "en-001", "en"]
  // Traditional Chinese does not fall back to simplified.
  assert i18n.fallbacks(i18n.new("zh-TW")) == ["zh-Hant-TW", "zh-Hant"]
}

pub fn data_locale_test() {
  assert i18n.data_locale(i18n.new("de-CH")) == "de-CH"
  assert i18n.data_locale(i18n.new("de-LU")) == "de"
  assert i18n.data_locale(i18n.new("es-AR")) == "es-419"
  assert i18n.data_locale(i18n.new("zh-HK")) == "zh-Hant"
  assert i18n.data_locale(i18n.new("xx")) == "en"
  assert i18n.locale(i18n.new("pt_br")) == "pt-BR"
}

pub fn pick_test() {
  let available = ["de", "en-GB", "fr-CA", "zh"]
  assert i18n.pick(i18n.new("de-AT"), available) == "de"
  assert i18n.pick(i18n.new("en"), available) == "en-GB"
  assert i18n.pick(i18n.new("fr"), available) == "fr-CA"
  assert i18n.pick(i18n.new("ja"), available) == ""
  assert i18n.pick(i18n.new("zh-CN"), available) == "zh"
  assert i18n.pick(i18n.new("zh-TW"), available) == ""
}

pub fn language_name_test() {
  assert i18n.language_name("de") == Ok("Deutsch")
  assert i18n.language_name("ja") == Ok("日本語")
  assert i18n.language_name("xx") == Error(Nil)
}

pub fn pick_canonical_catalogue_tags_test() {
  assert i18n.pick(i18n.new("zh-TW"), ["en", "zh-TW"]) == "zh-TW"
  assert i18n.pick(i18n.new("pt-BR"), ["pt", "pt-br"]) == "pt-br"
  assert i18n.pick(i18n.new("zh-HK"), ["zh", "zh-TW"]) == ""
}
