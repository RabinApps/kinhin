#!/bin/bash
# Warn before a hosted-lane e2e token expires, by opening a GitHub issue.
#
#   KINHIN_E2E_BITBUCKET_TOKEN_EXPIRES=2027-10-20 scripts/e2e-token-expiry.sh
#   scripts/e2e-token-expiry.sh --warn-days 45 --dry-run
#
# Reads KINHIN_E2E_BUILDKITE_TOKEN_EXPIRES, KINHIN_E2E_BITBUCKET_TOKEN_EXPIRES and KINHIN_E2E_AZURE_TOKEN_EXPIRES
# (YYYY-MM-DD, UTC) from the environment. scripts/e2e-forges-setup.sh records them as repository variables and
# .github/workflows/e2e-token-expiry.yml passes them in weekly. A Buildkite token does not expire unless you set a
# date, so without one it is skipped. Bitbucket and Azure DevOps tokens always expire: when
# KINHIN_E2E_BITBUCKET_TOKEN_CONFIGURED or KINHIN_E2E_AZURE_TOKEN_CONFIGURED is "true" (the workflow sets them from
# whether the secret exists) and the date is missing, that is reported and fails the run instead of being skipped.
# An unset or "false" flag means the lane is not set up, so it is skipped.
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

# real_date DATE: true for a real calendar day. BSD date rolls 2026-02-31 over to March instead of refusing it, so
# compare the round trip; GNU date refuses it outright.
real_date() {
    [[ $(date -u -d "$1" +%Y-%m-%d 2>/dev/null || date -j -u -f %Y-%m-%d "$1" +%Y-%m-%d 2>/dev/null) == "$1" ]]
}

# epoch DATE: midnight UTC of a YYYY-MM-DD date, with GNU date (CI) or BSD date (macOS).
epoch() {
    date -u -d "$1" +%s 2>/dev/null || date -j -u -f %Y-%m-%d "$1" +%s 2>/dev/null || die "cannot read the date '$1'"
}

today="$(epoch "$(date -u +%Y-%m-%d)")"
expired=0

# check FORGE LABEL EXPIRES [CONFIGURED]: CONFIGURED is given for a token that always expires.
check() {
    local forge=$1 label=$2 expires=$3 configured=${4-}
    if [[ -z $expires ]]; then
        if [[ $configured == true ]]; then
            echo "::warning::$label e2e token is stored but no expiry date is recorded"
            say "$label: stored with no expiry date; set KINHIN_E2E_$(echo "$forge" | tr '[:lower:]' '[:upper:]')_TOKEN_EXPIRES (gh variable set ... --body YYYY-MM-DD)"
            expired=1
        else
            say "$label: no expiry recorded"
        fi
        return 0
    fi
    # A bad date is reported and fails the run, but must not stop the checks of the forges after it.
    if ! [[ $expires =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]] || ! real_date "$expires"; then
        echo "::warning::$label e2e token expiry '$expires' is not a real YYYY-MM-DD date"
        say "$label: '$expires' is not a real date; fix KINHIN_E2E_$(echo "$forge" | tr '[:lower:]' '[:upper:]')_TOKEN_EXPIRES"
        expired=1
        return 0
    fi
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
check bitbucket Bitbucket "${KINHIN_E2E_BITBUCKET_TOKEN_EXPIRES:-}" "${KINHIN_E2E_BITBUCKET_TOKEN_CONFIGURED:-}"
check azure "Azure DevOps" "${KINHIN_E2E_AZURE_TOKEN_EXPIRES:-}" "${KINHIN_E2E_AZURE_TOKEN_CONFIGURED:-}"

exit "$expired"
