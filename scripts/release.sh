#!/usr/bin/env bash
# Release every Howdy package together as one Howdy version. See RELEASING.md.
#
#   scripts/release.sh 1.0.0            check, record, commit and tag
#   scripts/release.sh 1.0.0 --no-tag   check and record only, to review first
#
# It never pushes or publishes. Push the branch and tags, then run
# scripts/publish.sh, when you are happy.
set -euo pipefail

cd "$(dirname "$0")/.."

version="${1:-}"
tag_it=true
if [[ "${2:-}" == "--no-tag" ]]; then tag_it=false; fi

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: scripts/release.sh VERSION [--no-tag]   (VERSION like 1.0.0)" >&2
  exit 2
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "The working tree has uncommitted changes. Commit or stash them first." >&2
  exit 1
fi

if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
  echo "Tag v$version already exists." >&2
  exit 1
fi

packages=(
  "howdy:."
  "howdy_dev:howdy_dev"
  "howdy_ui:ui"
  "howdy_database:database"
  "howdy_auth:auth"
  "howdy_mail:mail"
  "howdy_storage:storage"
  "howdy_admin:admin"
  "howdy_remote:remote"
  "howdy_telemetry:telemetry"
  "howdy_openapi:openapi"
  "howdy_flags:flags"
  "howdy_jobs:jobs"
  "howdy_notifications:notifications"
  "howdy_cache:cache"
  "howdy_i18n:i18n"
)

echo "== Checking versions"
gleam run -m howdy_release -- check "$version"

# Each package other than howdy is tagged <name>-v<version> when released,
# which is where its HexDocs source links point. A package that has changed
# since its tag needs a new version.
#
# A package is published to Hex depending on each other Howdy package from
# that one's version at the time up to its next major (see publish.sh), and
# keeps those ranges until it is published again. So a package whose Howdy
# dependency has gone up a major since its tag cannot be used with this
# release, even unchanged: it needs a new version, published with the new
# range.
declare -A package_paths
for entry in "${packages[@]}"; do package_paths["${entry%%:*}"]="${entry#*:}"; done

# The version in a gleam.toml read from stdin.
version_in() {
  sed -n -E 's/^version = "([^"]+)"$/\1/p' | head -n 1
}

# The Howdy packages a gleam.toml read from stdin depends on by path in its
# [dependencies], the only ones Hex holds it to.
howdy_dependencies() {
  awk '/^\[/ { deps = ($0 == "[dependencies]"); next } deps' \
    | sed -n -E 's/^(howdy[a-z_]*) = \{ *path = .*/\1/p'
}

package_tags=()
unbumped=()
outgrown=()
for entry in "${packages[@]}"; do
  name="${entry%%:*}"
  path="${entry#*:}"
  [[ "$name" == "howdy" ]] && continue
  package_version="$(version_in <"$path/gleam.toml")"
  tag="$name-v$package_version"
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    if ! git diff --quiet "$tag" HEAD -- "$path/src" "$path/priv" "$path/gleam.toml"; then
      unbumped+=("$name")
      continue
    fi
    for dep in $(howdy_dependencies <"$path/gleam.toml"); do
      dep_toml="${package_paths[$dep]}/gleam.toml"
      dep_toml="${dep_toml#./}"
      was="$(git show "$tag:$dep_toml" | version_in)"
      now="$(version_in <"$dep_toml")"
      if [[ "${was%%.*}" != "${now%%.*}" ]]; then
        outgrown+=("$name (published for $dep $was, now $now)")
      fi
    done
  else
    package_tags+=("$tag")
  fi
done
if (( ${#unbumped[@]} > 0 )); then
  echo "Changed since their last release, so bump their versions: ${unbumped[*]}" >&2
  exit 1
fi
if (( ${#outgrown[@]} > 0 )); then
  echo "Published for an older major of a Howdy package, so bump their versions:" >&2
  printf '  %s\n' "${outgrown[@]}" >&2
  exit 1
fi

# A manifest still locking a bumped package to its old version passes with
# newer Gleam but fails CI's `gleam deps download` ("Incompatible locked
# version"), and only for a fresh checkout.
stale=()
for entry in "${packages[@]}"; do
  name="${entry%%:*}"
  path="${entry#*:}"
  package_version="$(sed -n -E 's/^version = "([^"]+)"$/\1/p' "$path/gleam.toml" | head -n 1)"
  while IFS= read -r manifest; do
    locked="$(sed -n -E "s/^  \{ name = \"$name\", version = \"([^\"]+)\".*source = \"local\".*/\1/p" "$manifest")"
    if [[ -n "$locked" && "$locked" != "$package_version" ]]; then
      stale+=("$manifest ($name $locked, now $package_version)")
    fi
  done < <(git ls-files '*manifest.toml')
done
if (( ${#stale[@]} > 0 )); then
  echo "These manifests lock an old version. Run \`gleam deps download\` in each:" >&2
  printf '  %s\n' "${stale[@]}" >&2
  exit 1
fi

echo "== Exporting each package's public API"
interfaces="$(mktemp -d)"
trap 'rm -rf "$interfaces"' EXIT
for entry in "${packages[@]}"; do
  name="${entry%%:*}"
  path="${entry#*:}"
  echo "   $name"
  (cd "$path" && gleam export package-interface --out "$interfaces/$name.json" >/dev/null)
done

echo "== Recording the release"
gleam run -m howdy_release -- record "$version" "$(date +%F)" "$interfaces"

echo "== Pointing the docs' install instructions and code links at v$version"
find docs -name '*.djot' -print0 | xargs -0 sed -i -E \
  -e "s#(github\.com/mikeyjones/howdy\.git\", ref = \")v[^\"]*\"#\1v$version\"#g" \
  -e "s#(github\.com/mikeyjones/howdy/(tree|blob)/)[^/)\" ]+#\1v$version#g"

# The READMEs are published to Hex, so their links and install
# instructions go to this release too.
readmes=()
for entry in "${packages[@]}"; do readmes+=("${entry#*:}/README.md"); done
sed -i -E \
  -e "s#(github\.com/mikeyjones/howdy\.git\", ref = \")v[^\"]*\"#\1v$version\"#g" \
  -e "s#(github\.com/mikeyjones/howdy/(tree|blob)/)[^/)\" ]+#\1v$version#g" \
  "${readmes[@]}"

if [[ "$tag_it" == false ]]; then
  echo
  echo "Recorded Howdy $version without committing. Review with: git diff"
  exit 0
fi

git add releases docs "${readmes[@]}"
git commit -q -m "Release Howdy $version"
git tag -a "v$version" -m "Howdy $version"
for tag in "${package_tags[@]}"; do
  git tag -a "$tag" -m "${tag%-v*} ${tag##*-v}, in Howdy $version"
done

echo
echo "Released Howdy $version as tag v$version. To publish it:"
echo "  git push origin HEAD v$version ${package_tags[*]}"
echo "  scripts/publish.sh"
