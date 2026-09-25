#!/bin/bash
# Submits a file (DMG, zip or pkg) to Apple's notary service and waits for the
# verdict. DMGs are stapled afterwards; zips cannot be stapled (Gatekeeper
# checks them online).
#
# Usage: scripts/notarize.sh <file>
#
# Credentials (App Store Connect API key), all required:
#   NOTARY_KEY_PATH   path to the AuthKey_XXXX.p8 file
#   NOTARY_KEY_ID     the key ID
#   NOTARY_ISSUER_ID  the issuer ID
#
# When none are set the script exits 0 without notarizing, so local and fork
# builds keep working. A partial set is an error.
set -euo pipefail

FILE="${1:?usage: notarize.sh <file>}"

set_count=0
for name in NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID; do
    if [ -n "${!name:-}" ]; then set_count=$((set_count + 1)); fi
done
if [ "$set_count" -eq 0 ]; then
    echo "==> notarization skipped (NOTARY_* not set): $FILE"
    exit 0
fi
if [ "$set_count" -ne 3 ]; then
    echo "FATAL: set all of NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID, or none" >&2
    exit 1
fi

AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
RESULT="$(mktemp)"
trap 'rm -f "$RESULT"' EXIT

echo "==> notarytool submit $FILE"
# `--wait` returns non-zero only on transport errors; the verdict is in the JSON.
xcrun notarytool submit "$FILE" "${AUTH[@]}" --wait --output-format json > "$RESULT" || true
cat "$RESULT"

STATUS="$(/usr/bin/plutil -extract status raw -o - "$RESULT" 2>/dev/null || echo "unknown")"
ID="$(/usr/bin/plutil -extract id raw -o - "$RESULT" 2>/dev/null || echo "")"
if [ "$STATUS" != "Accepted" ]; then
    echo "FATAL: notarization of $FILE finished with status: $STATUS" >&2
    if [ -n "$ID" ]; then
        xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
    fi
    exit 1
fi

case "$FILE" in
    *.dmg | *.pkg)
        echo "==> stapler staple $FILE"
        xcrun stapler staple "$FILE"
        xcrun stapler validate "$FILE"
        ;;
    *)
        echo "==> $FILE accepted (not stapled: only dmg/pkg support tickets)"
        ;;
esac
