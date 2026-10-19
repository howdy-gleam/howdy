import gleam/bit_array
import gleam/erlang/atom.{type Atom}
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import howdy
import howdy/form
import howdy/problem
import howdy/service
import howdy/testing
import howdy/ui
import howdy/ui/internal/rich_text_script
import howdy/ui/rich_text
import howdy/ui/rich_text/document.{
  Attached, Attachment, Bold, BulletList, Code, CodeBlock, Divider, Document,
  Heading, Italic, LineBreak, Link, Mention, Mentioned, NumberedList, Paragraph,
  Quote, Strike, Text,
}
import howdy/ui/rich_text/script
import lustre/element
import simplifile

fn sample() -> document.Document {
  let ada = Mention(trigger: "@", kind: "person", id: "1", label: "Ada")
  Document([
    Heading(2, [Text("Notes", [])]),
    Paragraph([
      Text("Hi ", []),
      Mentioned(ada),
      Text(", see ", []),
      Text("this", [Bold, Italic, Link("https://example.com/a?b=1")]),
      LineBreak,
      Text("gone", [Strike]),
      Text(" and ", []),
      Text("x()", [Code]),
    ]),
    BulletList([
      [Paragraph([Text("one", [])])],
      [
        Paragraph([Text("two", [])]),
        NumberedList(3, [[Paragraph([Text("three", [])])]]),
      ],
    ]),
    Quote([Paragraph([Text("quoted", [])])]),
    CodeBlock("let x = 1\n<b>"),
    Divider,
    Attached(Attachment(
      key: "uploads/a.png",
      name: "a.png",
      content_type: "image/png",
      size: 2048,
    )),
    Paragraph([Mentioned(ada)]),
  ])
}

// -- Decoding is the safety check --------------------------------------------

pub fn a_document_survives_json_test() {
  let json = document.to_string(sample())
  assert document.decode(json) == Ok(sample())
}

pub fn the_editors_own_json_is_read_test() {
  // As ProseMirror writes it, with attributes the server does not keep.
  let json =
    "{\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"marks\":[{\"type\":\"bold\"}],\"text\":\"Hi\"}]},{\"type\":\"ordered_list\",\"attrs\":{\"order\":1},\"content\":[{\"type\":\"list_item\",\"content\":[{\"type\":\"paragraph\"}]}]},{\"type\":\"attachment\",\"attrs\":{\"key\":\"k\",\"name\":\"n.txt\",\"content_type\":\"text/plain\",\"size\":3,\"url\":\"https://files/k\",\"upload\":null}}]}"
  assert document.decode(json)
    == Ok(
      Document([
        Paragraph([Text("Hi", [Bold])]),
        NumberedList(1, [[Paragraph([])]]),
        Attached(Attachment(
          key: "k",
          name: "n.txt",
          content_type: "text/plain",
          size: 3,
        )),
      ]),
    )
}

pub fn anything_the_editor_cannot_make_is_refused_test() {
  let refused = fn(json) {
    case document.decode(json) {
      Ok(_) -> False
      Error(_) -> True
    }
  }
  let paragraph = fn(inline) {
    "{\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\",\"content\":["
    <> inline
    <> "]}]}"
  }
  assert refused("not json")
  assert refused("{\"type\":\"paragraph\"}")
  assert refused(
    "{\"type\":\"doc\",\"content\":[{\"type\":\"script\",\"text\":\"x\"}]}",
  )
  assert refused(
    "{\"type\":\"doc\",\"content\":[{\"type\":\"heading\",\"attrs\":{\"level\":9}}]}",
  )
  assert refused(paragraph("{\"type\":\"image\",\"attrs\":{\"src\":\"x\"}}"))
  assert refused(paragraph(
    "{\"type\":\"text\",\"text\":\"x\",\"marks\":[{\"type\":\"style\"}]}",
  ))
  assert refused(paragraph(
    "{\"type\":\"text\",\"text\":\"x\",\"marks\":[{\"type\":\"link\",\"attrs\":{\"href\":\"javascript:alert(1)\"}}]}",
  ))
  assert refused(paragraph(
    "{\"type\":\"text\",\"text\":\"x\",\"marks\":[{\"type\":\"link\",\"attrs\":{\"href\":\"java\\tscript:alert(1)\"}}]}",
  ))
  assert refused(paragraph(
    "{\"type\":\"mention\",\"attrs\":{\"trigger\":\"@\",\"kind\":\"person\",\"id\":\"\",\"label\":\"x\"}}",
  ))
  assert refused(
    "{\"type\":\"doc\",\"content\":[{\"type\":\"attachment\",\"attrs\":{\"key\":\"\",\"name\":\"a\",\"content_type\":\"b\",\"size\":1}}]}",
  )
}

pub fn deep_nesting_is_refused_test() {
  let deep =
    list.repeat(Nil, 25)
    |> list.fold("{\"type\":\"paragraph\"}", fn(inner, _) {
      "{\"type\":\"blockquote\",\"content\":[" <> inner <> "]}"
    })
  let assert Error(_) =
    document.decode("{\"type\":\"doc\",\"content\":[" <> deep <> "]}")
}

pub fn safe_links_test() {
  assert document.is_safe_link("https://example.com")
  assert document.is_safe_link("HTTP://example.com")
  assert document.is_safe_link("mailto:ada@example.com")
  assert document.is_safe_link("tel:+441234")
  assert document.is_safe_link("/docs?x=1#y")
  assert document.is_safe_link("#top")
  assert document.is_safe_link("page/with:colon")
  assert !document.is_safe_link("javascript:alert(1)")
  assert !document.is_safe_link("JavaScript:alert(1)")
  assert !document.is_safe_link("data:text/html,x")
  assert !document.is_safe_link("vbscript:x")
  assert !document.is_safe_link(" javascript:x")
  assert !document.is_safe_link("https://a b")
  assert !document.is_safe_link("")
}

pub fn a_hand_made_document_is_filled_out_for_the_editor_test() {
  let json =
    Document([Quote([]), BulletList([[NumberedList(1, [])]])])
    |> document.to_string
  assert json
    == "{\"type\":\"doc\",\"content\":[{\"type\":\"blockquote\",\"content\":[{\"type\":\"paragraph\"}]},{\"type\":\"bullet_list\",\"content\":[{\"type\":\"list_item\",\"content\":[{\"type\":\"paragraph\"},{\"type\":\"ordered_list\",\"attrs\":{\"order\":1},\"content\":[{\"type\":\"list_item\",\"content\":[{\"type\":\"paragraph\"}]}]}]}]}]}"
  assert document.to_string(Document([]))
    == "{\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\"}]}"
  // Unsafe links built by hand are left out rather than posted.
  assert !string.contains(
    document.to_string(
      Document([Paragraph([Text("x", [Link("javascript:x")])])]),
    ),
    "javascript",
  )
}

// -- Reading a document ------------------------------------------------------

pub fn plain_text_test() {
  assert document.to_plain_text(sample())
    == "Notes\n\nHi @Ada, see this\ngone and x()\n\n- one\n- two\n  3. three\n\n> quoted\n\nlet x = 1\n<b>\n\n---\n\n[a.png]\n\n@Ada"
}

pub fn mentions_are_listed_once_test() {
  assert document.mentions(sample())
    == [Mention(trigger: "@", kind: "person", id: "1", label: "Ada")]
}

pub fn attachments_are_listed_test() {
  assert list.map(document.attachments(sample()), fn(file) { file.key })
    == ["uploads/a.png"]
}

pub fn emptiness_test() {
  assert document.is_empty(document.empty())
  assert document.is_empty(Document([]))
  assert document.is_empty(
    Document([Paragraph([Text("  ", []), LineBreak]), BulletList([[]])]),
  )
  assert !document.is_empty(Document([Divider]))
  assert !document.is_empty(Document([Paragraph([Text("x", [])])]))
}

pub fn from_text_test() {
  assert document.from_text("One\nline\r\n\r\nTwo\n\n\n")
    == Document([
      Paragraph([Text("One", []), LineBreak, Text("line", [])]),
      Paragraph([Text("Two", [])]),
    ])
  assert document.from_text("  ") == document.empty()
}

// -- Showing a document ------------------------------------------------------

pub fn a_document_is_drawn_as_escaped_prose_test() {
  let html = element.to_string(document.view(sample()))
  assert string.contains(html, "<h2>Notes</h2>")
  assert string.contains(
    html,
    "<a href=\"https://example.com/a?b=1\" rel=\"noopener noreferrer nofollow\"><strong><em>this</em></strong></a>",
  )
  assert string.contains(html, "<br><s>gone</s>")
  assert string.contains(html, "<code>x()</code>")
  assert string.contains(html, "<ol start=\"3\"><li><p>three</p></li></ol>")
  assert string.contains(html, "<pre><code>let x = 1\n&lt;b&gt;</code></pre>")
  assert string.contains(html, "<hr>")
  assert string.contains(html, "data-mention=\"person\"")
  assert string.contains(html, ">@Ada</span>")
  // Without a URL, an attachment is a card with its name and size.
  assert string.contains(html, "a.png")
  assert string.contains(html, "PNG · 2 KB")
  assert !string.contains(html, "<img")
}

pub fn mentions_and_attachments_are_drawn_by_the_app_test() {
  let html =
    document.view_with(
      sample(),
      mention: fn(mention) {
        document.mention_view(
          Mention(..mention, label: "Ada Lovelace"),
          href: Some("/people/" <> mention.id),
        )
      },
      attachment: fn(file) {
        document.attachment_view(file, url: Some("/files/" <> file.key))
      },
    )
    |> element.to_string
  assert string.contains(html, "href=\"/people/1\"")
  assert string.contains(html, ">@Ada Lovelace</a>")
  assert string.contains(html, "src=\"/files/uploads/a.png\"")
  assert string.contains(html, "alt=\"a.png\"")
}

pub fn an_empty_paragraph_keeps_its_line_test() {
  assert element.to_string(document.view(document.empty()))
    |> string.contains("<p><br></p>")
}

// -- The editor --------------------------------------------------------------

fn render(editor: rich_text.Editor) -> String {
  element.to_string(rich_text.view(editor))
}

pub fn an_editor_tells_the_script_what_to_do_test() {
  let html =
    rich_text.new(name: "body")
    |> rich_text.value(sample())
    |> rich_text.placeholder("Write")
    |> rich_text.mentions(trigger: "@", kind: "person", search: "/people")
    |> rich_text.attachments(start: "/uploads", url: fn(file) {
      Some("/files/" <> file.key)
    })
    |> rich_text.max_size(1_000_000)
    |> rich_text.accept(["image/*"])
    |> rich_text.required
    |> render
  assert string.starts_with(html, "<howdy-rich-text ")
  assert string.contains(html, "data-script=\"" <> script.url() <> "\"")
  assert script.url() == "/_howdy/rich-text/" <> rich_text_script.hash <> ".js"
  assert string.contains(html, "data-placeholder=\"Write\"")
  assert string.contains(
    html,
    "data-mentions=\"[{&quot;trigger&quot;:&quot;@&quot;,&quot;kind&quot;:&quot;person&quot;,&quot;search&quot;:&quot;/people&quot;}]\"",
  )
  assert string.contains(html, "data-upload-start=\"/uploads\"")
  assert string.contains(html, "data-max-size=\"1000000\"")
  assert string.contains(
    html,
    "data-text-too-large=\"Too large: the limit is 1 MB.\"",
  )
  assert string.contains(html, "accept=\"image/*\"")
  assert string.contains(html, "data-required")
  // The value posted, with each attachment's URL for the editor to show.
  assert string.contains(html, "name=\"body\" type=\"hidden\"")
  assert string.contains(
    html,
    "&quot;url&quot;:&quot;/files/uploads/a.png&quot;",
  )
  // The proxy a label points at, holding a value since there is text.
  assert string.contains(html, "id=\"rich-text-body\"")
  assert string.contains(html, "required")
  assert string.contains(html, "value=\"filled\"")
  // The toolbar, with an attach button because there are attachments.
  assert string.contains(html, "role=\"toolbar\"")
  assert string.contains(html, "data-command=\"attach\"")
  assert string.contains(html, "aria-label=\"Heading 2\"")
  // What the server drew is shown until the editor takes over.
  assert string.contains(html, "data-howdy-rich-text-preview")
  assert string.contains(html, "<h2>Notes</h2>")
}

pub fn an_empty_editor_shows_its_placeholder_test() {
  let html =
    rich_text.new(name: "Comment Body")
    |> rich_text.placeholder("Say something")
    |> rich_text.required
    |> render
  assert string.contains(html, "<p data-placeholder=\"Say something\"><br></p>")
  assert string.contains(html, "id=\"rich-text-comment-body\"")
  assert !string.contains(html, "value=\"filled\"")
  // No attachments, so no attach button.
  assert !string.contains(html, "data-command=\"attach\"")
}

pub fn chosen_tools_test() {
  let html =
    rich_text.new(name: "bio")
    |> rich_text.tools([[rich_text.Bold], [rich_text.Heading(4)]])
    |> render
  assert string.contains(html, "data-command=\"bold\"")
  assert string.contains(html, "data-command=\"heading-4\"")
  assert !string.contains(html, "data-command=\"italic\"")
  // One stop in the tab order, and a line between the groups.
  assert string.contains(html, "tabindex=\"0\"")
  assert list.length(string.split(html, "tabindex=\"-1\"")) > 1
  let none = rich_text.new(name: "bio") |> rich_text.tools([]) |> render
  assert !string.contains(none, "role=\"toolbar\"")
}

pub fn a_disabled_editor_posts_nothing_test() {
  let html = rich_text.new(name: "bio") |> rich_text.disabled |> render
  assert string.contains(html, "data-disabled")
  assert string.contains(html, "disabled name=\"bio\" type=\"hidden\"")
}

// -- Reading what was posted -------------------------------------------------

pub fn the_form_field_test() {
  let validator = fn(fields) {
    use body <- rich_text.field(fields, "body", [
      rich_text.not_empty(),
      rich_text.max_length(10),
    ])
    Ok(body)
  }
  let errors = fn(fields) {
    case validator(form.from_fields(fields)) {
      Ok(_) -> []
      Error(errors) ->
        list.map(errors, fn(error: service.FieldError) {
          #(error.field, error.problem)
        })
    }
  }
  let posted = fn(value) { [#("body", document.to_string(value))] }
  assert validator(form.from_fields(posted(document.from_text("Hello"))))
    == Ok(document.from_text("Hello"))
  assert errors([]) == [#("body", problem.Required)]
  assert errors([#("body", "<script>")])
    == [#("body", problem.Custom("not_rich_text", "is not valid rich text"))]
  assert errors(posted(document.empty())) == [#("body", problem.Blank)]
  assert errors(posted(document.from_text("Far too long a note")))
    == [#("body", problem.TooLong(10))]
}

pub fn suggestions_test() {
  assert rich_text.suggestions_to_json([
      rich_text.suggestion(id: "1", label: "Ada"),
      rich_text.Suggestion(
        id: "2",
        label: "Alan",
        detail: Some("alan@example.com"),
        image: None,
      ),
    ])
    |> json_string
    == "[{\"id\":\"1\",\"label\":\"Ada\",\"detail\":null,\"image\":null},{\"id\":\"2\",\"label\":\"Alan\",\"detail\":\"alan@example.com\",\"image\":null}]"
}

fn json_string(value: json.Json) -> String {
  json.to_string(value)
}

// -- The browser code --------------------------------------------------------

fn app() -> howdy.App {
  howdy.new() |> howdy.controller(ui.rich_text())
}

pub fn the_bundle_is_served_and_cached_for_good_test() {
  let res =
    testing.get("/_howdy/rich-text/" <> rich_text_script.hash <> ".js")
    |> testing.send(app())
  assert res.status == 200
  assert response.get_header(res, "content-type")
    == Ok("text/javascript; charset=utf-8")
  assert response.get_header(res, "cache-control")
    == Ok("public, max-age=31536000, immutable")
  assert string.contains(testing.text(res), "ProseMirror")
  // An older name still works, but is not cached.
  let old =
    testing.get("/_howdy/rich-text/0000000000000000.js") |> testing.send(app())
  assert old.status == 200
  assert response.get_header(old, "cache-control") == Ok("no-cache")
}

// build.mjs writes the bundle and its hash together; a bundle changed
// without rebuilding would be cached under the old name for good.
pub fn the_hash_names_the_bundle_test() {
  let assert Ok(bundle) = simplifile.read_bits("priv/rich_text.js")
  let hash =
    sha(atom.create("sha256"), bundle)
    |> bit_array_to_hex
    |> string.slice(0, 16)
  assert hash == rich_text_script.hash
}

fn bit_array_to_hex(bits: BitArray) -> String {
  string.lowercase(bit_array.base16_encode(bits))
}

@external(erlang, "crypto", "hash")
fn sha(algorithm: Atom, data: BitArray) -> BitArray
