#!/bin/bash
# The video suite's fast gates: the honesty check on every video script, ci.json validation, and the unit tests
# (themes, formats, projects, adapters, CI planning, the verifier, the workflow's policies). Needs only Node 22+ (and a one-time
# npm ci of the runtime dependencies if node_modules is absent); tests that need ffmpeg skip themselves without it. No container,
# no secrets: safe for any CI job.
# The real builds are the e2e tiers: video/scripts/test.sh --smoke | --standard | --full.
set -euo pipefail
cd "$(dirname "$0")/../video"
command -v node >/dev/null || { echo "video suite: skipped (no node)"; exit 0; }
# The one runtime package (YAML configs), when this checkout has none installed: --omit=dev leaves out the editor, the voice
# model and the browser tooling, which the unit tests do not use.
[ -d node_modules/yaml ] || npm ci --omit=dev --ignore-scripts --no-audit --no-fund --loglevel=error
node scripts/video-ci.mjs validate
node scripts/video-claims-lint.mjs --all
node --test tests/unit/*.test.mjs
