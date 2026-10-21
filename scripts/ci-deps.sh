#!/usr/bin/env bash
# Download Gleam dependencies for the project in the current directory so
# later `gleam test`/`gleam run` calls don't touch the Hex API.
#
# On a fresh checkout Gleam treats the manifest as outdated once per path
# dependency (it records one `build/packages/*.config_fingerprint` per
# resolve), and every resolve queries the Hex API. Parallel CI jobs share
# runner IPs, so that quickly trips Hex's rate limit. Keep downloading until
# Gleam stops resolving, backing off when Hex rate-limits us.
set -uo pipefail

max_attempts=30
delay=5

for ((attempt = 1; attempt <= max_attempts; attempt++)); do
  output=$(gleam deps download 2>&1)
  status=$?
  echo "$output"

  if ((status != 0)); then
    if ! grep -q "rate limit" <<<"$output"; then
      exit "$status"
    fi
    echo "Hex API rate limited; retrying in ${delay}s" >&2
    sleep "$delay"
    delay=$((delay < 60 ? delay * 2 : 60))
  elif ! grep -q "Resolving versions" <<<"$output"; then
    exit 0
  fi
done

echo "Dependencies still resolving after ${max_attempts} attempts" >&2
exit 1
