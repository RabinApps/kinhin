#!/bin/bash
# The video suite's fast gates: the honesty check on every video script, ci.json validation, and the unit tests
# (themes, formats, projects, adapters, CI planning, the verifier, the workflow's policies). Needs only Node 22+;
# tests that need ffmpeg skip themselves without it. No network, no container, no secrets: safe for any CI job.
# The real builds are the e2e tiers: video/scripts/test.sh --smoke | --standard | --full.
set -euo pipefail
cd "$(dirname "$0")/../video"
command -v node >/dev/null || { echo "video suite: skipped (no node)"; exit 0; }
node scripts/video-ci.mjs validate
node scripts/video-claims-lint.mjs --all
node --test tests/unit/*.test.mjs
