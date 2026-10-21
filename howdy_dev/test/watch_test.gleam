import gleam/dict
import howdy/dev/internal/watch.{Stamp}
import simplifile

pub fn changed_lists_added_removed_and_modified_files_test() {
  let before =
    dict.from_list([
      #("src/a.gleam", Stamp(100, 10, 1)),
      #("src/b.gleam", Stamp(100, 20, 2)),
      #("src/c.gleam", Stamp(100, 30, 3)),
    ])
  let after =
    dict.from_list([
      #("src/a.gleam", Stamp(100, 10, 1)),
      #("src/b.gleam", Stamp(101, 20, 2)),
      #("src/d.gleam", Stamp(100, 5, 4)),
    ])
  assert watch.changed(before, after)
    == ["src/b.gleam", "src/c.gleam", "src/d.gleam"]
  assert watch.changed(before, before) == []
}

pub fn changed_notices_new_contents_behind_an_unchanged_stat_test() {
  let before = dict.from_list([#("src/a.gleam", Stamp(100, 10, 1))])
  let after = dict.from_list([#("src/a.gleam", Stamp(100, 10, 2))])
  assert watch.changed(before, after) == ["src/a.gleam"]
}

pub fn snapshot_reads_every_file_under_the_directories_test() {
  let dir = "build/watch_test"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir <> "/nested")
  let assert Ok(Nil) = simplifile.write(dir <> "/one.gleam", "1")
  let assert Ok(Nil) = simplifile.write(dir <> "/nested/two.gleam", "22")

  let snapshot = watch.snapshot([dir, "does/not/exist"])
  assert dict.size(snapshot) == 2
  let assert Ok(Stamp(size:, ..)) =
    dict.get(snapshot, dir <> "/nested/two.gleam")
  assert size == 2

  let assert Ok(Nil) = simplifile.write(dir <> "/nested/two.gleam", "222")
  assert watch.changed(snapshot, watch.snapshot([dir]))
    == [dir <> "/nested/two.gleam"]
  let _ = simplifile.delete(dir)
}

/// The case the code review reproduced: same length, same whole-second
/// timestamp, different bytes.
pub fn snapshot_notices_same_size_edit_with_preserved_mtime_test() {
  let dir = "build/watch_same_size_test"
  let path = dir <> "/file.gleam"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(Nil) = simplifile.write(path, "aaaa")
  let before = watch.snapshot([dir])
  let mtime = mtime_seconds(path)

  let assert Ok(Nil) = simplifile.write(path, "bbbb")
  set_mtime_seconds(path, mtime)
  let after = watch.snapshot([dir])

  // Metadata alone cannot tell these apart.
  let assert Ok(Stamp(mtime_seconds: m1, size: s1, ..)) = dict.get(before, path)
  let assert Ok(Stamp(mtime_seconds: m2, size: s2, ..)) = dict.get(after, path)
  assert m1 == m2
  assert s1 == s2

  assert watch.changed(before, after) == [path]

  // Rewriting identical bytes is not a change.
  let assert Ok(Nil) = simplifile.write(path, "bbbb")
  set_mtime_seconds(path, mtime)
  assert watch.changed(after, watch.snapshot([dir])) == []
  let _ = simplifile.delete(dir)
}

@external(erlang, "watch_test_ffi", "mtime_seconds")
fn mtime_seconds(path: String) -> Int

@external(erlang, "watch_test_ffi", "set_mtime_seconds")
fn set_mtime_seconds(path: String, seconds: Int) -> Nil
