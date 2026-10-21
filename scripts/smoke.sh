#!/usr/bin/env bash
# Exercise a running howdy server the way real clients do: HTTP/1.1,
# HTTP/2 with prior knowledge, HTTP/2 over TLS via ALPN, a WebSocket
# handshake and a forwarded client header. Complements the unit tests,
# which never open a socket to a deployed instance.
#
#   scripts/smoke.sh http://127.0.0.1:8787 [/path] [/websocket-path]
#   scripts/smoke.sh https://app.example.com /health /ws
#
# Self-signed certificates are accepted (-k); this checks protocol
# behaviour, not certificate trust. Requires curl built with nghttp2.
set -u

base="${1:?usage: smoke.sh <base-url> [path] [websocket-path]}"
path="${2:-/}"
ws="${3:-}"
base="${base%/}"
fail=0

check() {
  local name="$1" expected="$2"; shift 2
  local out
  # A successful WebSocket handshake keeps the socket open, so cap the wait;
  # the write-out is still printed on timeout.
  out="$(curl -s -k -o /dev/null --max-time 5 "$@" 2>/dev/null)"
  if [[ "$out" == "$expected" ]]; then
    printf '  ok    %s (%s)\n' "$name" "$out"
  else
    printf '  FAIL  %s: expected %s, got %s\n' "$name" "$expected" "$out"
    fail=1
  fi
}

echo "howdy smoke: $base$path"
w='%{http_code} %{http_version}'

check "HTTP/1.1" "200 1.1" --http1.1 -w "$w" "$base$path"

case "$base" in
  https://*)
    check "HTTP/2 over TLS (ALPN)" "200 2" --http2 -w "$w" "$base$path"
    ;;
  *)
    check "HTTP/2 prior knowledge" "200 2" --http2-prior-knowledge -w "$w" "$base$path"
    # Upgrade: h2c is not negotiated by ewe; the request is served as HTTP/1.1.
    check "Upgrade: h2c falls back to HTTP/1.1" "200 1.1" --http2 -w "$w" "$base$path"
    ;;
esac

check "forwarded client header accepted" "200" -w '%{http_code}' \
  -H 'X-Forwarded-For: 203.0.113.9' -H 'X-Forwarded-Proto: https' "$base$path"

if [[ -n "$ws" ]]; then
  origin="${base}"
  check "WebSocket handshake, same origin" "101" -w '%{http_code}' --http1.1 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    -H "Origin: $origin" "$base$ws"
  check "WebSocket handshake, foreign origin refused" "403" -w '%{http_code}' --http1.1 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    -H 'Origin: https://attacker.example' "$base$ws"
fi

exit $fail
