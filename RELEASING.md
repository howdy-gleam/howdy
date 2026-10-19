# Releasing Howdy

Every package in this repository is released together, as one Howdy
version. A release is a git tag, `v<version>`, and the website's docs and
component pages for that release are built from the tag. The packages are
then published to Hex, where their API docs go to HexDocs.

## Version numbers

- The Howdy version is the version of the core `howdy` package, and follows
  semantic versioning: a patch fixes things, a minor adds things, a major
  breaks things.
- Each other package keeps its own version, and changes it when it changes.
  `releases/releases.json` records which versions of every package make up
  each Howdy release, so users can see what goes together.
- Each other package is also tagged `<package>-v<version>`, such as
  `howdy_ui-v1.0.0`, at the release that first shipped that version. Its
  HexDocs "source" links point at that tag. `scripts/release.sh` refuses to
  release a package that has changed since its tag without a new version.
- Apps depend on Hex versions:

  ```sh
  gleam add howdy@1 howdy_ui@1
  ```

  A package that is not on Hex is installed from a tag, never a
  branch. Its path dependencies on the other packages come from the same
  checkout, so every Howdy package in the app must then come from git too:

  ```toml
  howdy = { git = "https://github.com/mikeyjones/howdy.git", ref = "v1.0.0" }
  howdy_ui = { git = "https://github.com/mikeyjones/howdy.git", ref = "v1.0.0", path = "ui" }
  ```

## Making a release

1. Bump `version` in the `gleam.toml` of every package that changed, and in
   the root `gleam.toml` to the new Howdy version.
2. Commit, so the working tree is clean.
3. Run:

   ```sh
   scripts/release.sh 1.1.0
   ```

   It checks the versions, exports every package's public API, records the
   release in `releases/`, points the install instructions in `docs/` and
   the links in the READMEs at the new tag, then commits and tags `v1.1.0`
   and `<package>-v<version>` for each package with a new version. Pass
   `--no-tag` to stop before committing and review the changes first.
4. Push the branch and the tags it prints:

   ```sh
   git push origin HEAD v1.1.0 howdy_ui-v1.0.1
   ```

5. Publish to Hex, from the tag:

   ```sh
   git checkout v1.1.0
   scripts/publish.sh --dry-run
   scripts/publish.sh
   ```

   See "Publishing to Hex" below.
6. In the website, point the dependencies at the new tag and take a
   snapshot of its docs and components; see the website's README.

## Publishing to Hex

`scripts/publish.sh` publishes each package whose version is not on Hex
yet, dependencies first, with its docs. In this repository the packages
depend on each other by path, which Hex does not accept, so each is
published from a copy whose path dependencies on other Howdy packages are
rewritten to `>=` the version in the tree and `<` its next major.

`gleam publish` asks before each package. Set `HEXPM_API_KEY` to a Hex API
key to avoid signing in for every one. `--dry-run` publishes nothing: it
builds the Hex tarball of each package whose dependencies are already on
Hex, and lists the rewritten dependencies of the rest.

A package with a dependency that is not on Hex is skipped, and so is
everything that depends on it.

Hex lets a version be replaced, with `gleam publish --replace`, only
shortly after it is published. After that, fix it in a new version.

Each package's `internal_modules` hides `howdy/<package>/internal/*` from
HexDocs and from other packages. A new package needs the same line.

## What is recorded

`releases/releases.json` lists every release, its date and its package
versions. The website shows it as a compatibility table.

`releases/since.json` records, for every public module, function, constant
and type in every package, the Howdy release that first shipped it, and the
ones that deprecated or removed it. It is worked out from
`gleam export package-interface`, so it cannot drift from the code:

- Something new in this release is marked as added in it.
- Something marked `@deprecated` for the first time is marked as deprecated
  in it.
- Something that has gone is kept, and marked as removed in it.
- An internal module is left out, even one recorded before its package
  marked it internal.

The website shows these on the component pages. Never edit either file by
hand; run the release again instead.

## Docs

User docs live in `docs/`, next to the code, and are released with it. A
change that adds or changes a feature should change its docs in the same
pull request. See `docs/README.md`.
