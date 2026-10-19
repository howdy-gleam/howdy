#!/usr/bin/env bash
# Render every howdy_ui gallery example and its CSS on Erlang and on
# JavaScript, and fail if the two differ anywhere. Needs node.
set -euo pipefail
cd "$(dirname "$0")"

# Compiler output (dependency warnings, mostly) only shows if a build fails.
render() {
  if ! gleam build --target "$1" > "build/$1.log" 2>&1; then
    cat "build/$1.log" >&2
    exit 1
  fi
  gleam run --target "$1" --no-print-progress -m parity_test/all 2>/dev/null > "build/$1.txt"
}

mkdir -p build
render erlang
render javascript

if cmp -s build/erlang.txt build/javascript.txt; then
  echo "parity: Erlang and JavaScript render the same ($(grep -c '^=== ' build/erlang.txt) sections)"
  exit 0
fi

echo "parity: Erlang and JavaScript render differently." >&2
# Name the section holding the first difference, and show that line from
# each target.
line=$(cmp build/erlang.txt build/javascript.txt | sed -E 's/.* line ([0-9]+).*/\1/' || true)
section=$(head -n "$line" build/erlang.txt | grep '^=== ' | tail -n 1 || true)
echo "first difference in ${section#=== }, line $line:" >&2
echo "  erlang:     $(sed -n "${line}p" build/erlang.txt | cut -c1-200)" >&2
echo "  javascript: $(sed -n "${line}p" build/javascript.txt | cut -c1-200)" >&2
exit 1
