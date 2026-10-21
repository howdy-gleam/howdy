import gleam/list
import gleam/option.{None, Some}
import gleam/string
import howdy/ui/attachment
import howdy/ui/uploader
import lustre/element

fn render(uploader: uploader.Uploader) -> String {
  element.to_string(uploader.view(uploader))
}

fn count(html: String, part: String) -> Int {
  list.length(string.split(html, part)) - 1
}

pub fn an_uploader_tells_the_script_what_to_do_test() {
  let html =
    uploader.new(name: "avatar", start: "/profile/uploads")
    |> uploader.accept(["image/png", ".pdf"])
    |> uploader.max_size(5_000_000)
    |> uploader.id("avatar-input")
    |> render
  assert string.contains(html, "data-howdy-uploader")
  assert string.contains(html, "data-name=\"avatar\"")
  assert string.contains(html, "data-start=\"/profile/uploads\"")
  assert string.contains(html, "data-max-size=\"5000000\"")
  assert string.contains(html, "data-max-files=\"1\"")
  assert string.contains(
    html,
    "data-text-too-large=\"Too large: the limit is 5 MB.\"",
  )
  assert string.contains(html, "accept=\"image/png,.pdf\"")
  assert string.contains(html, "id=\"avatar-input\"")
  // The file input posts nothing itself: the keys go in hidden inputs.
  assert string.contains(
    html,
    "data-howdy-upload-input id=\"avatar-input\" type=\"file\">",
  )
  assert !string.contains(html, " multiple")
  // The blank row the script copies has a disabled key input.
  assert string.contains(html, "<template data-howdy-upload-blank")
  assert count(html, "data-howdy-upload-item") == 1
  assert string.contains(
    html,
    "data-howdy-upload-key disabled name=\"avatar\" type=\"hidden\"",
  )
  assert string.contains(html, "disabled")
}

pub fn stored_files_are_posted_unless_removed_test() {
  let html =
    uploader.new(name: "photos", start: "/uploads")
    |> uploader.multiple(max_files: 3)
    |> uploader.layout(attachment.Tile)
    |> uploader.required
    |> uploader.stored([
      uploader.Stored(
        key: "photos/1/beach.png",
        name: "beach.png",
        size: 820_000,
        thumbnail: Some("/files/photos/1/beach.png?sig"),
      ),
      uploader.Stored(
        key: "photos/1/notes",
        name: "notes",
        size: 12,
        thumbnail: None,
      ),
    ])
    |> render
  assert string.contains(html, " multiple")
  assert string.contains(html, "data-max-files=\"3\"")
  assert count(html, "data-howdy-upload-item") == 3
  assert string.contains(html, "value=\"photos/1/beach.png\"")
  assert string.contains(html, "value=\"photos/1/notes\"")
  assert string.contains(html, "src=\"/files/photos/1/beach.png?sig\"")
  assert string.contains(html, ">PNG · 820 KB<")
  assert string.contains(html, ">12 B<")
  assert string.contains(html, "aria-label=\"Remove beach.png\"")
  // A stored file satisfies `required` until the script takes over.
  assert !string.contains(html, " required")
}

pub fn a_required_uploader_starts_required_test() {
  let html =
    uploader.new(name: "document", start: "/uploads")
    |> uploader.required
    |> render
  assert string.contains(html, " required")
  assert string.contains(html, "data-required=\"true\"")
}

pub fn words_can_change_test() {
  let html =
    uploader.new(name: "f", start: "/u")
    |> uploader.multiple(max_files: 2)
    |> uploader.words(
      uploader.Words(
        ..uploader.english(),
        prompt: "Déposez vos fichiers",
        too_many: "Au plus {count} fichiers.",
      ),
    )
    |> render
  assert string.contains(html, "Déposez vos fichiers")
  assert string.contains(html, "data-text-too-many=\"Au plus 2 fichiers.\"")
}

pub fn file_sizes_test() {
  assert uploader.file_size(0) == "0 B"
  assert uploader.file_size(999) == "999 B"
  assert uploader.file_size(1000) == "1 KB"
  assert uploader.file_size(2400) == "2.4 KB"
  assert uploader.file_size(820_000) == "820 KB"
  assert uploader.file_size(999_499) == "999 KB"
  assert uploader.file_size(999_500) == "1 MB"
  assert uploader.file_size(2_400_000) == "2.4 MB"
  assert uploader.file_size(9_960_000) == "10 MB"
  assert uploader.file_size(18_000_000) == "18 MB"
  assert uploader.file_size(1_100_000_000) == "1.1 GB"
  assert uploader.describe("report.pdf", 2_400_000) == "PDF · 2.4 MB"
  assert uploader.describe("README", 12) == "12 B"
}
