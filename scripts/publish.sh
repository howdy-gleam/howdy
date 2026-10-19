#!/usr/bin/env bash
# Publish the Howdy packages to Hex, with their docs. See RELEASING.md.
#
#   scripts/publish.sh             publish every package not on Hex yet
#   scripts/publish.sh --dry-run   build what can be built, publish nothing
#
# In this repository the packages depend on each other by path. Hex takes
# only Hex dependencies, so each package is published from a copy whose path
# dependencies on other Howdy packages are rewritten to the version ranges
# they stand for: `>=` the version in this tree, `<` its next major.
#
# A package whose version is already on Hex is skipped, so after a release
# only the packages whose version changed are published. Run it from the
# release tag. `gleam publish` asks before each package; set HEXPM_API_KEY to
# avoid signing in every time.
set -euo pipefail

cd "$(dirname "$0")/.."

dry_run=false
if [[ "${1:-}" == "--dry-run" ]]; then dry_run=true; fi

# Each package comes after the packages it depends on.
packages=(
  "howdy:."
  "howdy_telemetry:telemetry"
  "howdy_database:database"
  "howdy_mail:mail"
  "howdy_storage:storage"
  "howdy_openapi:openapi"
  "howdy_ui:ui"
  "howdy_remote:remote"
  "howdy_flags:flags"
  "howdy_cache:cache"
  "howdy_dev:howdy_dev"
  "howdy_auth:auth"
  "howdy_admin:admin"
)

version_of() {
  sed -n -E 's/^version = "([^"]+)"$/\1/p' "$1/gleam.toml" | head -n 1
}

# Whether Hex has this version of the package. Anything but a yes or a no
# stops the script, rather than guessing.
on_hex() {
  local status
  status="$(curl -s -o /dev/null -w '%{http_code}' \
    "https://hex.pm/api/packages/$1/releases/$2")"
  case "$status" in
    200) return 0 ;;
    404) return 1 ;;
    *)
      echo "Could not ask Hex about $1 $2 (HTTP $status). Try again later." >&2
      exit 1
      ;;
  esac
}

# The lines of the [dependencies] and [dev-dependencies] tables.
dependencies() {
  awk '/^\[/ { deps = ($0 == "[dependencies]" || $0 == "[dev-dependencies]" || $0 == "[dev_dependencies]") ; next } deps && NF' "$1"
}

core="$(version_of .)"

if [[ "$dry_run" == false ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "The working tree has uncommitted changes. Publish from a clean release tag." >&2
    exit 1
  fi
  if [[ "$(git rev-parse HEAD)" != "$(git rev-parse -q --verify "v$core^{commit}" || true)" ]]; then
    echo "HEAD is not the release tag v$core. Check it out first: git checkout v$core" >&2
    exit 1
  fi
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Only the files git knows, so nothing ignored ends up in a package.
git ls-files -z --cached --others --exclude-standard \
  | tar --null --ignore-failed-read -T - -c 2>/dev/null \
  | tar -x -C "$work"

# Point every path dependency on a Howdy package at its Hex versions.
for entry in "${packages[@]}"; do
  path="${entry#*:}"
  [[ "$path" == "." ]] && continue
  for other in "${packages[@]}"; do
    dep="${other%%:*}"
    version="$(version_of "${other#*:}")"
    sed -i -E \
      "s#^$dep = \{ path = \"[^\"]*\" \}#$dep = \">= $version and < $((${version%%.*} + 1)).0.0\"#" \
      "$work/$path/gleam.toml"
  done
done

available=() # on Hex
pending=()   # would be published by this dry run
published=()
skipped=()

contains() {
  local item="$1"
  shift
  local name
  for name in "$@"; do [[ "$name" == "$item" ]] && return 0; done
  return 1
}

for entry in "${packages[@]}"; do
  name="${entry%%:*}"
  path="${entry#*:}"
  version="$(version_of "$path")"
  echo "== $name $version"

  if on_hex "$name" "$version"; then
    echo "   already on Hex"
    available+=("$name")
    continue
  fi

  toml="$work/$path/gleam.toml"
  others="$(dependencies "$toml" | grep -E '\b(path|git) *=' | cut -d' ' -f1 | tr '\n' ' ' || true)"
  if [[ -n "$others" ]]; then
    echo "   skipped: depends on ${others% }, which is not on Hex"
    skipped+=("$name")
    continue
  fi

  missing=""
  waiting=""
  for dep in $(sed -n -E 's/^(howdy[a-z_]*) = ">=.*/\1/p' "$toml"); do
    if contains "$dep" "${available[@]}"; then
      continue
    elif contains "$dep" "${pending[@]}"; then
      waiting+="$dep "
    else
      missing+="$dep "
    fi
  done
  if [[ -n "$missing" ]]; then
    echo "   skipped: ${missing% } is not on Hex"
    skipped+=("$name")
    continue
  fi

  if [[ "$dry_run" == true ]]; then
    if [[ -n "$waiting" ]]; then
      echo "   would publish after ${waiting% }, depending on:"
      sed -n -E 's/^(howdy[a-z_]* = ">=.*)/     \1/p' "$toml"
    else
      if ! (cd "$work/$path" && gleam export hex-tarball >"$work/export.log" 2>&1); then
        cat "$work/export.log" >&2
        exit 1
      fi
      echo "   would publish; its Hex tarball builds"
    fi
    pending+=("$name")
    continue
  fi

  (cd "$work/$path" && gleam publish)
  available+=("$name")
  published+=("$name $version")
done

echo
if [[ "$dry_run" == true ]]; then
  echo "Dry run: nothing was published."
else
  echo "Published: ${published[*]:-nothing}"
fi
if (( ${#skipped[@]} > 0 )); then
  echo "Not published: ${skipped[*]}"
fi
