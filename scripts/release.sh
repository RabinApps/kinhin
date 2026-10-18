#!/bin/bash
# Repeatable local release: preflight, gates, then build / sign / notarize /
# verify every artifact a v* tag publish would produce — from this checkout.
#
# Usage: scripts/release.sh <version> [--skip-checks] [--no-notarize] [--allow-dirty]
#
# Produces in dist/ (identical set to .github/workflows/release.yml):
#   kinhin-<v>-arm64.dmg    Developer ID signed, notarized, stapled, Gatekeeper-verified
#   kinhin-cli-<v>-arm64.zip  Developer ID signed, notarized
#   install.sh              stamped with the Team ID of the signed app
#   checksums.txt           sha256 of those three files
#
# It never commits, tags, pushes or publishes: the last screen prints the tag
# commands for a human to run. Versioning is verify-only — Sources/KinhinKit/
# Core/Version.swift is the single source of the version (release CI stamps it
# from the tag), and CHANGELOG.md carries a "## v<version>" heading; this
# script fails if either disagrees with <version> instead of editing them.
#
# Prerequisites:
#   - Full Xcode selected (xcode-select -p -> /Applications/Xcode.app), not CLT
#   - A Developer ID Application certificate in the keychain
#       CODESIGN_IDENTITY overrides; otherwise the first one found is used
#   - Notarization credentials, one of:
#       NOTARY_KEYCHAIN_PROFILE   a stored profile (preferred):
#         xcrun notarytool store-credentials kinhin \
#           --key AuthKey_XXXX.p8 --key-id <id> --issuer <issuer>
#       NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID
#
# Flags:
#   --skip-checks    skip scripts/check.sh (iterate only; never ship this way)
#   --no-notarize    skip notarization and the checks that need it — smoke run
#   --allow-dirty    run with uncommitted changes (prints a warning)
set -euo pipefail
cd "$(dirname "$0")/.."

SKIP_CHECKS=0
NO_NOTARIZE=0
ALLOW_DIRTY=0
VERSION=""

usage() {
    echo "usage: scripts/release.sh <version> [--skip-checks] [--no-notarize] [--allow-dirty]" >&2
    exit 2
}

for arg in "$@"; do
    case "$arg" in
        --skip-checks) SKIP_CHECKS=1 ;;
        --no-notarize) NO_NOTARIZE=1 ;;
        --allow-dirty) ALLOW_DIRTY=1 ;;
        --help | -h) usage ;;
        -*) echo "unknown flag: $arg" >&2; usage ;;
        *)
            [ -z "$VERSION" ] || usage
            VERSION="$arg"
            ;;
    esac
done
[ -n "$VERSION" ] || usage

stage() {
    echo ""
    echo "==> $1"
}

# Apple's queue outlives this process: a failed or killed step leaves the
# submission alive server-side, so say how to pick it up instead of leaving
# the operator to guess. The sidecar (<file>.notary) is written the moment the
# upload returns, which is why it is still here to point at.
on_error() {
    local st=$? sidecar file
    sidecar="$(ls dist/*.notary 2>/dev/null | head -1 || true)"
    if [ -n "$sidecar" ]; then
        file="${sidecar%.notary}"
        echo "" >&2
        echo "release: notarization is still running on Apple's side — nothing was lost." >&2
        echo "  check:   scripts/notarize.sh status '$file'" >&2
        echo "  resume:  scripts/notarize.sh wait '$file'" >&2
        echo "  finish:  ./scripts/release-artifacts.sh $VERSION" >&2
    fi
    exit "$st"
}
trap on_error ERR

# --- Preflight: every failure here costs seconds, every one later costs minutes
stage "preflight"

# Same shape release.yml accepts for a tag: plain semver, optional beta suffix.
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta-[0-9]+)?$ ]] || {
    echo "FATAL: version '$VERSION' is not MAJOR.MINOR.PATCH[-beta-N]" >&2
    exit 1
}

SOURCE_VERSION="$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/KinhinKit/Core/Version.swift)"
if [ "$SOURCE_VERSION" != "$VERSION" ]; then
    echo "FATAL: Version.swift says '$SOURCE_VERSION', you asked for '$VERSION'." >&2
    echo "  Version.swift is the single source of the version; bump it, run" >&2
    echo "  scripts/docs-sync.sh (the site and README banners follow it), and add the" >&2
    echo "  CHANGELOG heading, all in a commit first, then re-run this script." >&2
    exit 1
fi
echo "    version: $VERSION (Version.swift matches)"

# The banners are generated from Version.swift (docs-sync). This runs even with --skip-checks, so a
# release cannot ship a banner that names another version. It needs no Swift toolchain.
bash scripts/docs-sync.sh --check

if ! grep -qxF "## v$VERSION" CHANGELOG.md; then
    echo "FATAL: CHANGELOG.md has no '## v$VERSION' heading — add the release notes first." >&2
    if grep -qxF "## Unreleased" CHANGELOG.md; then
        echo "  Run: scripts/changelog.sh promote $VERSION" >&2
    fi
    exit 1
fi
echo "    CHANGELOG: '## v$VERSION' heading present"
bash scripts/changelog.sh check

DIRTY="$(git status --porcelain)"
if [ -n "$DIRTY" ] && [ "$ALLOW_DIRTY" = 0 ]; then
    echo "FATAL: the working tree is dirty; a release must be reproducible from a commit:" >&2
    echo "$DIRTY" >&2
    echo "  Commit (or stash) first, or pass --allow-dirty for a throwaway run." >&2
    exit 1
fi
if [ -n "$DIRTY" ]; then
    echo "    WARNING: --allow-dirty: releasing an uncommitted tree" >&2
else
    echo "    working tree: clean"
fi

# CI's toolchain gate: swift test needs XCTest, which ships with full Xcode
# — fail here rather than minutes into the build. grep -c (not -q) so a
# closed pipe never SIGPIPEs find under `set -o pipefail`.
XCTEST_COUNT="$(find "$(xcode-select -p)" -maxdepth 6 -name 'XCTest.framework' 2>/dev/null | grep -c . || true)"
if [ "$XCTEST_COUNT" -eq 0 ]; then
    echo "FATAL: XCTest not found under $(xcode-select -p). Select full Xcode:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi
echo "    toolchain: $(xcode-select -p)"

# A release is never ad-hoc signed: an ad-hoc DMG cannot be notarized and
# Gatekeeper refuses it. Names are resolved to the identity's SHA-1 hash:
# this keychain holds two certificates with the same "Developer ID
# Application: …" name, and codesign refuses such a name as ambiguous, while
# the hash is unique and equally accepted.
identity_hash() {
    security find-identity -v -p codesigning |
        awk -v want="$1" -F'"' '$2 == want { sub(/^.*\) /, "", $1); gsub(/[ \t]/, "", $1); print $1; exit }'
}
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning |
        sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    resolved="$(identity_hash "$IDENTITY" || true)"
    [ -n "$resolved" ] && IDENTITY="$resolved"
fi
if [ -z "$IDENTITY" ]; then
    echo "FATAL: no Developer ID Application certificate in the keychain." >&2
    echo "  Install one (Xcode > Settings > Accounts > Manage Certificates) or set" >&2
    echo "  CODESIGN_IDENTITY to the identity from:" >&2
    echo "    security find-identity -v -p codesigning" >&2
    exit 1
fi
echo "    codesign: $IDENTITY"
export CODESIGN_IDENTITY="$IDENTITY"

if [ "$NO_NOTARIZE" = 1 ]; then
    echo "    notarization: SKIPPED (--no-notarize) — smoke run only, never publish this"
elif [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    if [ -n "${NOTARY_KEY_PATH:-}${NOTARY_KEY_ID:-}${NOTARY_ISSUER_ID:-}" ]; then
        echo "FATAL: set NOTARY_KEYCHAIN_PROFILE or the NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER_ID trio, not both." >&2
        exit 1
    fi
    echo "    notarization: keychain profile '$NOTARY_KEYCHAIN_PROFILE'"
elif [ -n "${NOTARY_KEY_PATH:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
    echo "    notarization: App Store Connect API key (key id $NOTARY_KEY_ID)"
else
    echo "FATAL: no notarization credentials." >&2
    echo "  Store a profile once (preferred, nothing lands in your environment):" >&2
    echo "    xcrun notarytool store-credentials kinhin \\" >&2
    echo "      --key AuthKey_XXXX.p8 --key-id <key-id> --issuer <issuer-id>" >&2
    echo "  then: NOTARY_KEYCHAIN_PROFILE=kinhin scripts/release.sh $VERSION" >&2
    echo "  (or export all three of NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID)" >&2
    echo "  Pass --no-notarize for a local smoke run that is never published." >&2
    exit 1
fi

# dist/ is a workbench: stale artifacts would otherwise linger next to this
# release's files (and older checksums are how a bad DMG ships).
stage "clean dist/ (previous artifacts)"
if [ -d dist ]; then
    shopt -s nullglob
    for path in dist/kinhin-* dist/install.sh dist/checksums.txt dist/cli; do
        if [ -e "$path" ]; then
            echo "    rm -rf $path"
            rm -rf "$path"
        fi
    done
    shopt -u nullglob
else
    echo "    (no dist/ yet)"
fi

# --- Gates: everything CI runs, failing fast --------------------------------
if [ "$SKIP_CHECKS" = 1 ]; then
    stage "checks: SKIPPED (--skip-checks) — do not publish from this run"
else
    stage "scripts/check.sh"
    ./scripts/check.sh
fi

# --- Build: assemble, sign inside-out, DMG, notarize, staple ----------------
stage "scripts/make-dmg.sh"
export KINHIN_VERSION="$VERSION"
./scripts/make-dmg.sh

# --- Artifacts: CLI zip, Gatekeeper verification, installer, checksums ------
ARTIFACT_FLAGS=()
[ "$NO_NOTARIZE" = 1 ] && ARTIFACT_FLAGS+=(--no-notarize)
stage "scripts/release-artifacts.sh"
./scripts/release-artifacts.sh "${ARTIFACT_FLAGS[@]+"${ARTIFACT_FLAGS[@]}"}" "$VERSION"

# --- Summary ----------------------------------------------------------------
stage "artifacts for v$VERSION"
(cd dist && shasum -a 256 \
    "kinhin-$VERSION-arm64.dmg" \
    "kinhin-cli-$VERSION-arm64.zip" \
    install.sh)

if [ "$NO_NOTARIZE" = 1 ]; then
    echo ""
    echo "release: DONE (SMOKE RUN) — notarization was skipped, so these artifacts"
    echo "are not Gatekeeper-verified. Nothing here may be published or uploaded."
    exit 0
fi

cat <<SUMMARY

release: everything verified. Publishing is a human step — this script never
touches git. When you are ready:

    git tag v$VERSION
    git push origin v$VERSION

The tag triggers .github/workflows/release.yml, which rebuilds from the tag in
the protected 'release' environment and publishes dist/ to GitHub Releases.
Your local dist/ is a rehearsal: it proves the build, the signing and the
installer stamping before the tag exists. With no kinhin-xcode runner, publish
this dist/ instead: see "Local publish" in docs/releasing.md.

Afterwards: add v$VERSION to website/versions.json for the docs snapshot
(see CONTRIBUTING.md, "Docs versions"), and move the CHANGELOG heading into
place if you have not already.
SUMMARY
