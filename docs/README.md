# Howdy docs

The user documentation shown at `/docs` on the Howdy website. It lives here,
next to the code, so a feature and its docs change in the same pull request
and are released together; the website reads the docs from each release's
tag.

- Each doc is a [Djot](https://djot.net/) file at `<group>/<doc>.djot`.
- `index.json` lists the groups and docs in the order the navigation shows
  them, with each doc's title and one-line description. A doc that is not
  listed is not shown.
- Link to other docs as `/docs/<group>/<doc>`, and to the component gallery
  as `/components/<name>`. When the website shows an older release, it
  points these at that release.
- Install instructions give `ref = "v<version>"`, and links to code on
  GitHub use `/tree/v1/` or `/blob/v1/`. `scripts/release.sh` points both at
  each new tag, so readers see the code of the release they are reading.
- The site renders Djot with `jot`, which has no tables: use a list.

## Marking what is new

Put `{since="1.1"}` on the line before a heading for a section about
something added in Howdy 1.1. The website shows a "New in 1.1" badge on it,
so readers on an older release know it is not there for them yet:

```djot
{since="1.1"}
## Required STARTTLS
```

Modules, functions and components are labelled for you from
`../releases/since.json`; there is no need to mark those.

## Previewing

Run the website with `HOWDY_DOCS_SOURCE` pointing here to see changes as you
make them:

```sh
HOWDY_DOCS_SOURCE=../howdy-v2/docs gleam dev
```
