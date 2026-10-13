#!/bin/bash
# Run the end-to-end suite (Tests/E2E): real forges in containers, real runners, real guests.
#
# This is NOT part of scripts/check.sh or CI's per-PR job: it boots containers/VMs and needs Docker, so it runs on
# a dedicated Mac (see .github/workflows/e2e.yml and docs/e2e-testing.md).
#
#   scripts/e2e.sh                 quick tier: CLI, security and coverage guards (no Docker needed)
#   scripts/e2e.sh --local         + Gitea/Forgejo lifecycle, fleet behavior, smoke toolchains (Docker/container)
#   scripts/e2e.sh --full          + GitLab CE, the Tart macOS/Linux and host lanes, the whole toolchain catalog (hours, GBs)
#   scripts/e2e.sh --local -- --filter LifecycleTests     extra args after -- go to `swift test`
#
# Narrow the matrix with KINHIN_E2E_FORGES=gitea,forgejo and KINHIN_E2E_RUNTIMES=docker,appleContainer.
# Other switches: KINHIN_E2E_KEEP=1 (keep sandboxes), KINHIN_E2E_TART_BASE=<macOS tart image> (Tart macOS lane),
# KINHIN_E2E_TART_LINUX_BASE=<Linux tart image> (Tart Linux lane), KINHIN_E2E_HOST=1 (host lane),
# KINHIN_E2E_GITHUB_TOKEN + KINHIN_E2E_GITHUB_REPO (the gated GitHub lane).
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"

tier=quick
extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) tier=quick ;;
    --local) tier=local ;;
    --full) tier=full ;;
    --) shift; extra=("$@"); break ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

# The suite needs a DEBUG kinhin: only debug builds read forge tokens from the environment
# (KINHIN_TOKEN_STORE=env), which keeps the run off the developer's Keychain.
echo "==> building kinhin (debug)"
swift build --product kinhin

# An earlier run that was killed leaves daemons, containers and sandboxes behind; clear them first and again on exit.
"$root/scripts/e2e-sweep.sh"
# Absolute path (the script cd's into Tests/E2E later), and `|| true` so a failing sweep never changes the exit status.
trap '"$root/scripts/e2e-sweep.sh" --force >/dev/null 2>&1 || true' EXIT

export KINHIN_E2E=1
export KINHIN_E2E_BIN="$PWD/.build/debug/kinhin"

case "$tier" in
  quick) filter=(--filter 'CLITests|SecurityTests|CoverageTests') ;;
  local) filter=() ;;
  full)
    filter=()
    export KINHIN_E2E_HEAVY=1
    export KINHIN_E2E_TOOLCHAINS=full
    # Every runtime: the curated Tart bases (tens of GB once) and the host lane, unless the caller chose otherwise.
    if command -v tart >/dev/null 2>&1; then
      export KINHIN_E2E_TART_BASE="${KINHIN_E2E_TART_BASE:-ghcr.io/cirruslabs/macos-tahoe-base:latest}"
      export KINHIN_E2E_TART_LINUX_BASE="${KINHIN_E2E_TART_LINUX_BASE:-ghcr.io/cirruslabs/ubuntu:latest}"
    fi
    export KINHIN_E2E_HOST="${KINHIN_E2E_HOST:-1}"
    ;;
esac

echo "==> running the $tier tier"
cd Tests/E2E
# Not `exec`: the EXIT trap above must run to sweep leftovers, also when the tests fail or are interrupted.
status=0
if [ ${#extra[@]} -gt 0 ]; then
  swift test ${filter[@]+"${filter[@]}"} "${extra[@]}" || status=$?
else
  swift test ${filter[@]+"${filter[@]}"} || status=$?
fi
exit $status
