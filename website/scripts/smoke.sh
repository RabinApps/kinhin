#!/usr/bin/env bash
# Smoke test of the built Worker: serves .open-next locally with wrangler and checks what the live site must do.
#   scripts/smoke.sh      (after scripts/build-site.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
port=${PORT:-8788}
base=http://localhost:$port

# Reuse a server that is already answering on the port (a developer's `wrangler dev`, or a previous step); otherwise start one and
# stop it, and everything it spawned, when this script ends.
started=0
if curl -fsS -o /dev/null "$base/" 2>/dev/null; then
  echo "smoke: using the server already running at $base"
else
  npx opennextjs-cloudflare populateCache local >/dev/null
  npx wrangler dev --local --port "$port" >"${TMPDIR:-/tmp}/kinhin-wrangler.log" 2>&1 &
  pid=$!
  started=1
fi

# `kill $pid` alone only stops the npx wrapper: wrangler and the workerd that listens on the port are its descendants, and would
# stay behind holding the port for the next step.
killtree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do killtree "$child"; done
  kill "$1" 2>/dev/null || true
}
cleanup() {
  [ "$started" = 1 ] || return 0
  killtree "$pid"
  for _ in $(seq 1 20); do curl -fsS -o /dev/null "$base/" 2>/dev/null || return 0; sleep 0.5; done
  # Something is still listening (a detached workerd): stop whatever holds the port.
  if command -v lsof >/dev/null 2>&1; then lsof -ti "tcp:$port" 2>/dev/null | xargs kill 2>/dev/null || true; fi
}
trap cleanup EXIT
for _ in $(seq 1 60); do curl -fsS -o /dev/null "$base/" 2>/dev/null && break; sleep 1; done

fail=0
check() { # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
header() { curl -s -D - -o /dev/null "${@:2}" | tr -d '\r' | grep -i "^$1:" | head -n 1 | cut -d: -f2- | sed 's/^ *//' | cut -d';' -f1; }

check "home is HTML" 200 "$(code "$base/")"
check "a docs page is HTML" 200 "$(code "$base/guide/quick-start")"
check ".md copy of a page" "text/markdown" "$(header content-type "$base/guide/quick-start.md")"
check ".md copy of the home page" 200 "$(code "$base/index.md")"
check "Accept: text/markdown returns markdown" "text/markdown" "$(header content-type -H 'Accept: text/markdown' "$base/guide/quick-start")"
check "browsers still get HTML" "text/html" "$(header content-type -H 'Accept: text/html,*/*;q=0.8' "$base/guide/quick-start")"
check "markdown starts with the title" "# Quick start" "$(curl -s -H 'Accept: text/markdown' "$base/guide/quick-start" | head -n 1)"
check "llms.txt" 200 "$(code "$base/llms.txt")"
check "llms-full.txt" 200 "$(code "$base/llms-full.txt")"
check "search index" 200 "$(code "$base/search-index.json")"
check "sitemap" 200 "$(code "$base/sitemap.xml")"
check "old .html URL redirects" 308 "$(code "$base/how-many-macos-vms-can-run-at-once.html")"
check "unknown page is a 404" 404 "$(code "$base/definitely-not-a-page")"
# Old release snapshots, when this build has any.
for tag in $(node -e 'for (const v of JSON.parse(require("fs").readFileSync("versions.json","utf8"))) console.log(v)'); do
  [ -d "public/$tag" ] && check "snapshot $tag" 200 "$(code "$base/$tag/guide/quick-start")"
done
[ -f public/appcast.xml ] && check "Sparkle appcast" 200 "$(code "$base/appcast.xml")"
exit $fail
