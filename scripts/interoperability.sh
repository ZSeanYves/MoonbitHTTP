#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
server_log="${TMPDIR:-/tmp}/moonbithttp-smoke-server.log"

cd "$repo_root"
moon run cmd/smoke_server --target native >"$server_log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true' EXIT

ready=false
for _ in {1..100}; do
  if curl --silent --fail --http1.1 http://127.0.0.1:18080/ >/dev/null; then
    ready=true
    break
  fi
  sleep 0.1
done

if [[ "$ready" != true ]]; then
  cat "$server_log"
  exit 1
fi

get_response="$(curl --silent --fail --http1.1 http://127.0.0.1:18080/)"
test "$get_response" = "MoonbitHTTP smoke"

post_response="$(curl --silent --fail --http1.1 --data-binary 'roundtrip' http://127.0.0.1:18080/echo)"
test "$post_response" = "roundtrip"

if command -v nghttp >/dev/null 2>&1; then
  nghttp --no-dep --no-push --header='accept: text/plain' http://127.0.0.1:18080/ \
    | grep -q 'MoonbitHTTP smoke'
  nghttp --upgrade --no-dep --no-push --header='accept: text/plain' http://127.0.0.1:18080/ \
    | grep -q 'MoonbitHTTP smoke'
fi

echo "curl HTTP/1.1, nghttp2 prior-knowledge, and h2c upgrade checks passed"
