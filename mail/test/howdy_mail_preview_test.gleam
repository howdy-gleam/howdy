import gleam/string
import howdy/mail
import howdy/mail/preview

pub fn build_test() {
  let welcome =
    preview.new("Welcome", fn() {
      mail.message()
      |> mail.to([mail.address("a@example.com")])
      |> mail.subject("Hi")
      |> mail.text("Hi")
    })
  assert preview.group(welcome) == "Emails"
  assert preview.name(welcome) == "Welcome"
  let assert Ok(_) = preview.build(welcome)
}

pub fn crashing_template_test() {
  let broken = preview.new("Broken", fn() { panic as "missing sample" })
  let assert Error(reason) = preview.build(broken)
  assert string.contains(reason, "missing sample")
}

pub fn keys_test() {
  let invoice =
    preview.new("Invoice (PDF)", fn() { mail.message() })
    |> preview.in_group("Billing & Plans")
  assert preview.key(invoice) == "billing---plans.invoice--pdf-"
  assert preview.find([invoice], "billing---plans.invoice--pdf-") == Ok(invoice)
  assert preview.find([invoice], "nope") == Error(Nil)
}
