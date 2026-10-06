#!/bin/bash
# Submits a file (DMG, zip or pkg) to Apple's notary service and, by default,
# waits for the verdict and staples DMGs.
#
# Usage:
#   scripts/notarize.sh <file>          submit (or resume) -> wait -> staple: the release path
#   scripts/notarize.sh submit <file>   upload only; record the submission id; return immediately
#   scripts/notarize.sh wait <file>     poll a recorded submission until it settles, then staple
#   scripts/notarize.sh staple <file>   staple now, without waiting (fails unless already accepted)
#   scripts/notarize.sh status <file>   print the recorded submission id and its live status
#
# Why submit and wait are separate: Apple's queue routinely holds submissions
# for hours. One blocked `notarytool --wait` that gets killed — tool-call
# timeout, CI job limit, Ctrl-C — also destroys the only record of the
# submission, so the retry uploads the same bytes again and waits from zero.
# Here the id is written to a sidecar the moment the upload returns:
#
#   <file>.notary        sha256=<hash of the file that was uploaded>
#                        id=<submission uuid>
#                        submittedAt=<utc timestamp>
#
# Every later `wait`, `staple` and `status`, and a re-run of the default form,
# resume from it instead of resubmitting. The sha256 is re-checked first, so a
# rebuilt artifact can never be stapled against another file's ticket — it
# fails with instructions instead.
#
# Exit codes: 0 accepted (or notarization skipped), 1 rejected / failed, 75 the
# wait hit NOTARY_WAIT_SECONDS while still In Progress — resume with
# `scripts/notarize.sh wait <file>`.
#
# Environment:
#   NOTARY_WAIT_SECONDS  bound on the wait (unset = wait as long as Apple takes)
#   NOTARY_POLL_SECONDS  seconds between polls (default 20)
#   NOTARY_KEYCHAIN_PROFILE  a stored notarytool profile, the preferred form:
#       xcrun notarytool store-credentials kinhin --key AuthKey_XXXX.p8 \
#         --key-id <id> --issuer <issuer>
#     Nothing on disk, nothing in the environment, no .p8 file to guard.
#   App Store Connect API key, all three required:
#       NOTARY_KEY_PATH   path to the AuthKey_XXXX.p8 file
#       NOTARY_KEY_ID     the key ID
#       NOTARY_ISSUER_ID  the issuer ID
#
# When no credentials are set the script exits 0 without notarizing, so local
# and fork builds keep working. A partial set is an error.
set -euo pipefail

usage() {
    echo "usage: notarize.sh [submit|wait|staple|status] <file>" >&2
    exit 2
}

MODE="full"
case "${1:-}" in
    submit | wait | staple | status) MODE="$1"; shift ;;
esac
[ -n "${1:-}" ] || usage
FILE="$1"
if [ ! -f "$FILE" ]; then
    echo "FATAL: $FILE does not exist" >&2
    exit 1
fi

STATE="$FILE.notary"
POLL_SECONDS="${NOTARY_POLL_SECONDS:-20}"
WAIT_BUDGET="${NOTARY_WAIT_SECONDS:-}"

hash_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

# First value of a top-level-ish JSON string field. notarytool emits flat
# objects ({"status":"In Progress","id":"…"}), and grep keeps us independent of
# key order and of plutil's parser.
json_field() {
    grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$2" 2>/dev/null |
        head -1 | sed -E 's/^[^:]*:[[:space:]]*"//; s/"$//'
}

state_field() {
    sed -n "s/^$1=//p" "$STATE" | head -1
}

resolve_auth() {
    AUTH=()
    SKIP_AUTH=0
    if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
        if [ -n "${NOTARY_KEY_PATH:-}${NOTARY_KEY_ID:-}${NOTARY_ISSUER_ID:-}" ]; then
            echo "FATAL: set NOTARY_KEYCHAIN_PROFILE or the NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER_ID trio, not both" >&2
            exit 1
        fi
        AUTH=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
        echo "==> notarytool profile: $NOTARY_KEYCHAIN_PROFILE"
    else
        set_count=0
        for name in NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID; do
            if [ -n "${!name:-}" ]; then set_count=$((set_count + 1)); fi
        done
        if [ "$set_count" -eq 0 ]; then
            SKIP_AUTH=1
            return 0
        fi
        if [ "$set_count" -ne 3 ]; then
            echo "FATAL: set all of NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID, or none" >&2
            exit 1
        fi
        AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
    fi
}

skip_without_credentials() {
    if [ "$SKIP_AUTH" = 1 ]; then
        echo "==> notarization skipped (no notary credentials): $FILE"
        exit 0
    fi
}

require_state() {
    if [ ! -f "$STATE" ]; then
        echo "FATAL: no submission recorded for $FILE" >&2
        echo "  run: scripts/notarize.sh submit '$FILE'" >&2
        exit 1
    fi
    local recorded current
    recorded="$(state_field sha256)"
    current="$(hash_of "$FILE")"
    if [ "$recorded" != "$current" ]; then
        echo "FATAL: $FILE changed since it was submitted" >&2
        echo "  recorded: $recorded" >&2
        echo "  current:  $current" >&2
        echo "  delete '$STATE' and submit again:" >&2
        echo "    scripts/notarize.sh submit '$FILE'" >&2
        exit 1
    fi
}

require_id() {
    local id
    id="$(state_field id)"
    if [ -z "$id" ]; then
        echo "FATAL: $STATE records no submission id — delete it and submit again" >&2
        exit 1
    fi
    echo "$id"
}

# --- submit -----------------------------------------------------------------
do_submit() {
    echo "==> notarytool submit $FILE"
    local tmp id
    tmp="$(mktemp)"
    if ! xcrun notarytool submit "$FILE" ${AUTH[@]+"${AUTH[@]}"} --output-format json >"$tmp" 2>&1; then
        cat "$tmp" >&2
        rm -f "$tmp"
        echo "FATAL: submission of $FILE failed" >&2
        exit 1
    fi
    id="$(json_field id "$tmp")"
    if [ -z "$id" ]; then
        cat "$tmp" >&2
        rm -f "$tmp"
        echo "FATAL: no submission id in the notarytool response" >&2
        exit 1
    fi
    rm -f "$tmp"
    # Written atomically and immediately: this line is what survives a kill.
    {
        echo "sha256=$(hash_of "$FILE")"
        echo "id=$id"
        echo "submittedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$STATE.tmp"
    mv "$STATE.tmp" "$STATE"
    echo "==> submitted: $id (recorded in $STATE)"
}

# --- wait -------------------------------------------------------------------
print_notary_log() {
    xcrun notarytool log "$1" ${AUTH[@]+"${AUTH[@]}"} >&2 || true
}

wait_for_verdict() {
    local id start last_print last_status status now_e fails tmp
    id="$1"
    start="$(date +%s)"
    last_print=0
    last_status=""
    fails=0
    echo "==> waiting on submission $id (poll every ${POLL_SECONDS}s; Apple's queue can take hours)"
    while :; do
        tmp="$(mktemp)"
        if xcrun notarytool info "$id" ${AUTH[@]+"${AUTH[@]}"} --output-format json >"$tmp" 2>&1; then
            fails=0
            status="$(json_field status "$tmp")"
            now_e="$(date +%s)"
            if [ "$status" != "$last_status" ] || [ $((now_e - last_print)) -ge 60 ]; then
                echo "==> $(date '+%H:%M:%S') $status ($((now_e - start))s elapsed)"
                last_status="$status"
                last_print="$now_e"
            fi
            case "$status" in
                Accepted)
                    rm -f "$tmp"
                    return 0
                    ;;
                Invalid)
                    cat "$tmp" >&2
                    rm -f "$tmp"
                    echo "FATAL: notarization of $FILE was rejected" >&2
                    print_notary_log "$id"
                    exit 1
                    ;;
            esac
        else
            fails=$((fails + 1))
            echo "warning: notarytool info failed ($fails/3): $(cat "$tmp")" >&2
            if [ "$fails" -ge 3 ]; then
                rm -f "$tmp"
                echo "FATAL: cannot poll submission $id — resume with: scripts/notarize.sh wait '$FILE'" >&2
                exit 1
            fi
        fi
        rm -f "$tmp"
        now_e="$(date +%s)"
        if [ -n "$WAIT_BUDGET" ] && [ $((now_e - start)) -ge "$WAIT_BUDGET" ]; then
            echo "FATAL: still '${last_status:-In Progress}' after ${WAIT_BUDGET}s." >&2
            echo "  The submission stays alive on Apple's side; nothing was lost." >&2
            echo "  Resume later:   scripts/notarize.sh wait '$FILE'" >&2
            echo "  Or check now:   scripts/notarize.sh status '$FILE'" >&2
            exit 75
        fi
        sleep "$POLL_SECONDS"
    done
}

# --- staple -----------------------------------------------------------------
staple_file() {
    case "$FILE" in
        *.dmg | *.pkg)
            if xcrun stapler validate "$FILE" >/dev/null 2>&1; then
                echo "==> $FILE already stapled and valid"
                return 0
            fi
            echo "==> stapler staple $FILE"
            xcrun stapler staple "$FILE"
            xcrun stapler validate "$FILE"
            ;;
        *)
            echo "==> $FILE accepted (not stapled: only dmg/pkg support tickets)"
            ;;
    esac
}

require_accepted() {
    local id status
    id="$1"
    status="$(xcrun notarytool info "$id" ${AUTH[@]+"${AUTH[@]}"} --output-format json 2>/dev/null |
        json_field status /dev/stdin || true)"
    if [ "$status" != "Accepted" ]; then
        echo "FATAL: submission $id is '${status:-unknown}', not Accepted — wait first:" >&2
        echo "  scripts/notarize.sh wait '$FILE'" >&2
        exit 1
    fi
}

# --- modes ------------------------------------------------------------------
case "$MODE" in
    submit)
        resolve_auth
        skip_without_credentials
        do_submit
        echo "==> upload done; the queue runs server-side. Resume whenever:"
        echo "    scripts/notarize.sh wait '$FILE'"
        ;;
    status)
        resolve_auth
        skip_without_credentials
        require_state
        id="$(require_id)"
        status="$(xcrun notarytool info "$id" ${AUTH[@]+"${AUTH[@]}"} --output-format json 2>/dev/null |
            json_field status /dev/stdin || true)"
        echo "$id ${status:-unknown}"
        ;;
    wait)
        resolve_auth
        skip_without_credentials
        require_state
        id="$(require_id)"
        wait_for_verdict "$id"
        staple_file
        ;;
    staple)
        resolve_auth
        skip_without_credentials
        require_state
        id="$(require_id)"
        require_accepted "$id"
        staple_file
        ;;
    full)
        resolve_auth
        skip_without_credentials
        if [ -f "$STATE" ]; then
            echo "==> resuming recorded submission $(state_field id) (submitted $(state_field submittedAt))"
        else
            do_submit
        fi
        id="$(require_id)"
        wait_for_verdict "$id"
        staple_file
        ;;
esac
