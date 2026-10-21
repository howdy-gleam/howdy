#!/usr/bin/env bash
# Islands end to end, as CI runs them:
#
#   1. the browser tests against `gleam run`, which builds islands on demand;
#   2. from a clean build, `gleam run -m howdy/ui export`, then the browser
#      tests against the release it exported;
#   3. a release exported after the code changed, without bundling again,
#      which must refuse its bundle and say why.
#
# Needs Node 22+ and Chromium (CHROMIUM names the binary). Uses port 8793.
# Leaves src as it found it.
set -euo pipefail
# Job control puts each server in a process group of its own, so stopping
# it stops gleam, erl and the VM together.
set -m
cd "$(dirname "$0")/.."

url=http://127.0.0.1:8793/
logs=$(mktemp -d)
format=src/howdy_islands_example/format.gleam
cp "$format" "$logs/format.gleam"
server=

stop() {
  if [ -n "$server" ]; then
    kill -- "-$server" 2>/dev/null || true
    wait "$server" 2>/dev/null || true
    server=
  fi
  for _ in $(seq 1 40); do
    curl -s -o /dev/null "$url" || return 0
    sleep 0.25
  done
  echo "something still answers on $url"
  return 1
}

cleanup() {
  stop || true
  cp "$logs/format.gleam" "$format"
}
trap cleanup EXIT

start() {
  local log=$1
  shift
  if curl -s -o /dev/null "$url"; then
    echo "something already answers on $url"
    exit 1
  fi
  "$@" > "$log" 2>&1 &
  server=$!
  for _ in $(seq 1 180); do
    curl -sf -o /dev/null "$url" && return 0
    sleep 1
  done
  echo "the server did not start:"
  cat "$log"
  exit 1
}

echo "== Development: gleam run"
start "$logs/dev.log" gleam run
ISLANDS_MODE=dev node browser_test/run.mjs
stop

echo "== Release: clean build, gleam run -m howdy/ui export"
rm -rf build/dev build/prod build/howdy_islands build/erlang-shipment priv/howdy_islands
gleam run -m howdy/ui export
start "$logs/release.log" build/erlang-shipment/entrypoint.sh run
if grep "howdy islands" "$logs/release.log"; then
  echo "the release did not accept its own bundle"
  exit 1
fi
ISLANDS_MODE=release node browser_test/run.mjs
stop

echo "== Release exported after a change, without bundling again"
sed -i 's/"Count: "/"Total: "/' "$format"
gleam export erlang-shipment > /dev/null
start "$logs/stale.log" build/erlang-shipment/entrypoint.sh run
expected="the islands bundle was built from different code than this release runs (changed: howdy_islands_example/format)"
if ! grep -qF "$expected" "$logs/stale.log"; then
  echo "the release did not refuse a stale bundle. Its log:"
  cat "$logs/stale.log"
  exit 1
fi
# The page still renders on the server; the browser is told why the
# islands did not start. Each response is read whole before it is
# searched: `grep -q` stops at the first match, and under pipefail the
# write curl then fails makes the pipeline fail.
page=$(curl -sf "$url")
grep -qF "Total: 5" <<< "$page"
boot=$(curl -sf "${url}_howdy/islands/boot.mjs")
grep -qF "console.error" <<< "$boot"
stop
echo "refused, as it should be: $expected"
