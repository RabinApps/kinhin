#!/bin/bash
# Warn before a hosted-lane e2e token expires, by opening a GitHub issue.
#
#   KINHIN_E2E_BITBUCKET_TOKEN_EXPIRES=2027-10-20 scripts/e2e-token-expiry.sh
#   scripts/e2e-token-expiry.sh --warn-days 45 --dry-run
#
# Reads KINHIN_E2E_BUILDKITE_TOKEN_EXPIRES, KINHIN_E2E_BITBUCKET_TOKEN_EXPIRES and KINHIN_E2E_AZURE_TOKEN_EXPIRES
# (YYYY-MM-DD, UTC) from the environment. scripts/e2e-forges-setup.sh records them as repository variables and
# .github/workflows/e2e-token-expiry.yml passes them in weekly. A forge with no date is skipped, because Buildkite
# tokens do not expire unless you set a date.
#
# For each token that expires within --warn-days (default 30) it opens one issue per forge, unless one is already
# open, and exits 1 when a token has already expired so the workflow run goes red. It never reads or prints a
# token. Tokens cannot be created through an API, so the issue tells a person how to rotate them:
# scripts/e2e-forges-setup.sh <forge> --rotate.
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    echo "usage: scripts/e2e-token-expiry.sh [--warn-days N] [--dry-run]" >&2
    exit "${1:-2}"
}

warn_days=30
dry=0
while (( $# )); do
    case "$1" in
        --warn-days) (( $# >= 2 )) || usage; warn_days=$2; shift ;;
        --dry-run) dry=1 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
    shift
done
[[ $warn_days =~ ^[0-9]+$ ]] || die "--warn-days needs a number of days"
(( dry )) || command -v gh >/dev/null || die "gh not found"
repo="${GITHUB_REPOSITORY:-RabinApps/kinhin}"

# epoch DATE: midnight UTC of a YYYY-MM-DD date, with GNU date (CI) or BSD date (macOS).
epoch() {
    date -u -d "$1" +%s 2>/dev/null || date -j -u -f %Y-%m-%d "$1" +%s 2>/dev/null || die "cannot read the date '$1'"
}

today="$(epoch "$(date -u +%Y-%m-%d)")"
expired=0

# check FORGE LABEL EXPIRES ROTATE_NAME
check() {
    local forge=$1 label=$2 expires=$3
    if [[ -z $expires ]]; then
        say "$label: no expiry recorded"
        return 0
    fi
    [[ $expires =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]] || die "$label: '$expires' is not a YYYY-MM-DD date"
    local days=$(( ($(epoch "$expires") - today) / 86400 ))
    if (( days > warn_days )); then
        say "$label: expires $expires, $days days left"
        return 0
    fi

    local state
    if (( days < 0 )); then
        state="expired on $expires"
        expired=1
    else
        state="expires on $expires ($days days left)"
    fi
    echo "::warning::$label e2e token $state"
    local title="E2E token expiring: $label"
    if (( dry )); then
        say "[dry-run] $label: $state; would open the issue '$title' unless one is open"
        return 0
    fi
    if [[ -n $(gh issue list --repo "$repo" --state open --search "\"$title\" in:title" --json number --jq '.[].number') ]]; then
        say "$label: $state; an issue is already open"
        return 0
    fi
    gh issue create --repo "$repo" --title "$title" --body "The $label e2e token $state. When it lapses the $label lane fails on its first call with a 401.

Rotate it:

1. Create a new token with the same scopes and a new expiry (the steps are in [docs/e2e-hosted-forges.md](https://github.com/$repo/blob/develop/docs/e2e-hosted-forges.md)).
2. Run \`scripts/e2e-forges-setup.sh $forge --rotate\`. It checks the new token, replaces the secret and records the new expiry.
3. Revoke the old token, then close this issue.

Opened by .github/workflows/e2e-token-expiry.yml." >/dev/null
    say "$label: $state; opened an issue"
}

check buildkite Buildkite "${KINHIN_E2E_BUILDKITE_TOKEN_EXPIRES:-}"
check bitbucket Bitbucket "${KINHIN_E2E_BITBUCKET_TOKEN_EXPIRES:-}"
check azure "Azure DevOps" "${KINHIN_E2E_AZURE_TOKEN_EXPIRES:-}"

exit "$expired"
