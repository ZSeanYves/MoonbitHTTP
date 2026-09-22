#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
server_log="${TMPDIR:-/tmp}/moonbithttp-smoke-server.log"

cd "$repo_root"
moon run cmd/smoke_server --target native >"$server_log" 2>&1 &
server_pid=$!

cleanup_server() {
  kill "$server_pid" 2>/dev/null || true
  for _ in {1..40}; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      wait "$server_pid" 2>/dev/null || true
      return
    fi
    sleep 0.05
  done
  kill -KILL "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}

trap cleanup_server EXIT

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

if command -v wget >/dev/null 2>&1; then
  wget_response="$(wget --quiet --output-document=- --no-proxy http://127.0.0.1:18080/)"
  test "$wget_response" = "MoonbitHTTP smoke"
  wget_post_response="$(wget --quiet --output-document=- --no-proxy --post-data='roundtrip' http://127.0.0.1:18080/echo)"
  test "$wget_post_response" = "roundtrip"
fi

if command -v nghttp >/dev/null 2>&1; then
  nghttp --no-dep --no-push --header='accept: text/plain' http://127.0.0.1:18080/ \
    | grep -q 'MoonbitHTTP smoke'
  nghttp --upgrade --no-dep --no-push --header='accept: text/plain' http://127.0.0.1:18080/ \
    | grep -q 'MoonbitHTTP smoke'
fi

echo "curl/Wget HTTP/1.1, nghttp2 prior-knowledge, and h2c upgrade checks passed"
