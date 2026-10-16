#!/bin/bash
# Records a scripted browser session of a web product (Playwright + Chromium), locally or in a container.
# A Linux container is enough: no Mac, no desktop session, nothing to grant.
#
# Usage: video/scripts/record-web.sh --scenario FILE [--out FILE] [--runner local|docker|apple] [options]
#   --scenario FILE   scenario JSON (see adapters/kinhin/scenarios/site.json, docs/videos-for-your-project.md)
#   --out FILE        output (default video/raw/web.webm, repo-relative)
#   --runner NAME     local (default): this machine's Node + Chromium
#                     docker: the official Playwright image under `docker run`
#                     apple:  the same image under apple/container's `container run`
#   --serve CMD       start the product first (run from the repo root, inside the runner), e.g.
#                     "npm --prefix website run preview -- --port 4173"
#   --wait-url URL    with --serve: wait until URL answers before recording (default: the scenario's baseUrl)
#   --image IMAGE     container image (default mcr.microsoft.com/playwright:v1.64.0-noble, matching package.json)
# Env: BASE_URL, PACE, CHROMIUM_PATH are passed through (see sources/web/record.mjs).
#
# In a container, the product must be reachable from inside it: use --serve (it runs in the container), or a
# public URL. localhost on the host is not localhost inside a container.
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/../.."

SCENARIO=""
OUT="video/raw/web.webm"
RUNNER=local
SERVE=""
WAIT_URL=""
IMAGE="mcr.microsoft.com/playwright:v1.64.0-noble"

while [ $# -gt 0 ]; do
  case "$1" in
    --scenario) SCENARIO="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    --runner) RUNNER="$2"; shift ;;
    --serve) SERVE="$2"; shift ;;
    --wait-url) WAIT_URL="$2"; shift ;;
    --image) IMAGE="$2"; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$SELF" | sed '$d'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$SCENARIO" ] || { echo "--scenario is required" >&2; exit 2; }
[ -f "$SCENARIO" ] || [ -f "video/$SCENARIO" ] || { echo "no such scenario: $SCENARIO" >&2; exit 2; }
[ -f "$SCENARIO" ] || SCENARIO="video/$SCENARIO"
case "$OUT" in video/*) ;; *) OUT="video/$OUT" ;; esac
mkdir -p "$(dirname "$OUT")"

# The commands that run wherever the browser is (this machine, or inside the container), from the repo root.
if [ -z "$WAIT_URL" ]; then
  WAIT_URL="$(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(process.env.BASE_URL||s.baseUrl||"")' "$SCENARIO")"
fi
INNER='set -e
cd video && npm install --no-audit --no-fund >/dev/null && cd ..
if [ -n "$SERVE" ]; then
  sh -c "$SERVE" >/tmp/serve.log 2>&1 &
  SERVE_PID=$!
  trap "kill $SERVE_PID 2>/dev/null || true" EXIT
  for i in $(seq 1 90); do curl -fsS -o /dev/null "$WAIT_URL" 2>/dev/null && break; sleep 1; done
  curl -fsS -o /dev/null "$WAIT_URL" || { echo "the product did not answer at $WAIT_URL (see /tmp/serve.log)" >&2; tail -5 /tmp/serve.log >&2; exit 1; }
fi
node video/sources/web/record.mjs "$SCENARIO" "$OUT"'

export SERVE WAIT_URL SCENARIO OUT
case "$RUNNER" in
  local)
    bash -c "$INNER"
    ;;
  docker|apple)
    if [ "$RUNNER" = docker ]; then CLI=(docker run --rm); else CLI=(container run --rm); fi
    command -v "${CLI[0]}" >/dev/null || { echo "${CLI[0]} not found" >&2; exit 1; }
    "${CLI[@]}" -v "$PWD":/work -w /work \
      -e SERVE="$SERVE" -e WAIT_URL="$WAIT_URL" -e SCENARIO="$SCENARIO" -e OUT="$OUT" \
      -e BASE_URL="${BASE_URL:-}" -e PACE="${PACE:-1}" \
      "$IMAGE" bash -c "$INNER"
    ;;
  *) echo "unknown runner: $RUNNER (local, docker, apple)" >&2; exit 2 ;;
esac
echo "==> wrote $OUT"
