#!/bin/bash
# Runs the video suite's tests (node:test; no extra dependencies).
#
#   video/scripts/test.sh                 the unit tests: themes, formats, projects, adapters, claims, CI planning,
#                                         the verifier, the workflow's policies (seconds; needs only Node and ffmpeg)
#   video/scripts/test.sh --smoke         + a few real builds in a container (a few minutes)
#   video/scripts/test.sh --standard      + every theme, format and scene type, the cache, determinism (tens of minutes)
#   video/scripts/test.sh --full          + the kinhin launch video in every CI look, and all examples
# Options: --host          build on this machine instead of in a container (needs ffmpeg with libass and Chromium)
#          --runtime NAME  container or docker (default: Apple's container if running, else Docker)
#          --filter TEXT   only tests whose name contains TEXT
# The e2e builds write video/out/ and video/raw/scenes/ (both git-ignored).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d /opt/homebrew/opt/ffmpeg-full/bin ] && export PATH="/opt/homebrew/opt/ffmpeg-full/bin:$PATH"
TIER=""; FILTER=()
while [ $# -gt 0 ]; do
  case "$1" in
    --smoke) TIER=smoke ;; --standard) TIER=standard ;; --full) TIER=full ;;
    --host) export E2E_MODE=host ;;
    --runtime) export E2E_RUNTIME="${2:?--runtime needs container or docker}"; shift ;;
    --filter) FILTER=(--test-name-pattern "${2:?--filter needs text}"); shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -d node_modules ] || npm ci
node scripts/video-ci.mjs validate
if [ -n "$TIER" ]; then
  export E2E_TIER="$TIER"
  exec node --test --test-concurrency=1 ${FILTER[@]+"${FILTER[@]}"} tests/unit/*.test.mjs tests/e2e/*.test.mjs
fi
exec node --test ${FILTER[@]+"${FILTER[@]}"} tests/unit/*.test.mjs
