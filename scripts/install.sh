#!/bin/bash
# kinhin one-line installer.
#
#   curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
#   curl -fsSL ... | bash -s -- v0.1.0                        # pin a version
#   bash scripts/install.sh /path/to/kinhin-0.1.0-arm64.dmg  # offline / air-gapped
#
# What it does:
#   1. Fetches (or uses the given) kinhin-x.y.z-arm64.dmg from GitHub Releases
#   2. Verifies it against the release checksums.txt (a download without one
#      is refused; a local DMG is checked against DMG.sha256 when present)
#   3. Mounts the DMG, checks the app's code signature (release copies of this
#      script are pinned to the release's Developer ID Team ID and require
#      Gatekeeper to accept the app), and copies kinhin.app to /Applications
#   4. Symlinks the bundled kinhin CLI into the bin dir
#   Quarantine is never stripped: a curl-fetched DMG carries none, and a
#   browser-downloaded one is left for Gatekeeper to assess.
#
#   bash scripts/install.sh --uninstall      # reverses everything above
#
# Override destinations for testing / custom layouts:
#   REPO=RabinApps/kinhin INSTALL_DIR=/path BIN_DIR=/path bash scripts/install.sh ...
set -euo pipefail

REPO="${REPO:-RabinApps/kinhin}"
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$REPO" != *..* ]] \
    || { echo "error: REPO must look like owner/name" >&2; exit 1; }
# Stamped with the Developer ID Team ID by the release workflow. A copy that
# still carries the placeholder (run from a checkout, or a fork) cannot pin the
# signer and falls back to the checks it can make.
TEAM_ID="@TEAM_ID@"
# https only, TLS 1.2+, for every network fetch.
CURL=(curl --proto '=https' --tlsv1.2 -fL --retry 3)
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

# Resolve the CLI bin dir: Homebrew on Apple Silicon first (its bin is user-
# writable), then /usr/local/bin if writable, otherwise ~/.local/bin.
default_bin_dir() {
    if [[ -d /opt/homebrew/bin && -w /opt/homebrew/bin ]]; then
        echo /opt/homebrew/bin
    elif [[ -d /usr/local/bin && -w /usr/local/bin ]]; then
        echo /usr/local/bin
    else
        mkdir -p "$HOME/.local/bin"
        echo "$HOME/.local/bin"
    fi
}
BIN_DIR="${BIN_DIR:-$(default_bin_dir)}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinhin-install.XXXXXX")"
MNT="$TMP_DIR/mnt"
cleanup() { hdiutil detach "$MNT" -quiet 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

info() { echo "==> $*"; }
die()  { echo "error: $*" >&2; exit 1; }

need_mac() {
    [[ "$(uname -s)" == "Darwin" ]] || die "kinhin installs on macOS only"
    [[ "$(uname -m)" == "arm64" ]] || die "kinhin requires Apple Silicon (arm64)"
}

# Everything below runs inside main(), invoked on the last line: a download that is
# cut off mid-script (curl | bash) defines the function but never calls it.
main() {
# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    need_mac
    # Stop the headless daemon first: its LaunchAgent points into the app being removed.
    for label in com.kinhin.daemon com.orchard.daemon; do
        plist="$HOME/Library/LaunchAgents/$label.plist"
        if [[ -f "$plist" ]]; then
            info "Stopping and removing the $label LaunchAgent"
            launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
            rm -f "$plist"
        fi
    done
    if [[ -e "$INSTALL_DIR/kinhin.app" ]]; then
        info "Removing $INSTALL_DIR/kinhin.app"
        rm -rf "$INSTALL_DIR/kinhin.app"
    else
        info "No kinhin.app at $INSTALL_DIR (nothing to do there)"
    fi
    # Pre-rename installs lived at Orchard.app; remove it only when it really is ours.
    if [[ -e "$INSTALL_DIR/Orchard.app" ]]; then
        legacy_id="$(defaults read "$INSTALL_DIR/Orchard.app/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
        if [[ "$legacy_id" == com.RabinApps.* || "$legacy_id" == com.orchard.* || "$legacy_id" == com.kinhin.* ]]; then
            info "Removing legacy $INSTALL_DIR/Orchard.app"
            rm -rf "$INSTALL_DIR/Orchard.app"
        else
            echo "note: left $INSTALL_DIR/Orchard.app alone (bundle id '${legacy_id:-unknown}' is not kinhin's)" >&2
        fi
    fi
    # Sweep every candidate bin dir; only remove symlinks that point at the CLI
    # inside a kinhin.app / legacy Orchard.app (a foreign `kinhin`/`orchard` is
    # never touched).
    for candidate in \
        /opt/homebrew/bin/kinhin /usr/local/bin/kinhin "$HOME/.local/bin/kinhin" \
        /opt/homebrew/bin/orchard /usr/local/bin/orchard "$HOME/.local/bin/orchard"; do
        if [[ -L "$candidate" ]]; then
            target="$(readlink "$candidate")"
            case "$target" in
                */kinhin.app/Contents/Resources/bin/*|*/Orchard.app/Contents/Resources/bin/*)
                    info "Removing $candidate"
                    rm -f "$candidate"
                    ;;
            esac
        fi
    done
    echo "note: kept your config, logs, and Keychain token:"
    echo "      ~/Library/Application Support/Kinhin/   (remove manually if wanted)"
    echo "      a pre-rename Orchard/ support directory is migrated automatically on next launch"
    echo "      'kinhin auth clear' removes the Keychain PAT"
    echo "==> kinhin uninstalled."
    exit 0
fi

# ---------------------------------------------------------------------------
# Locate a DMG: local file argument, pinned version, or latest release
# ---------------------------------------------------------------------------
ARG="${1:-}"
DMG=""
TAG=""
if [[ -n "$ARG" && "$ARG" != v* ]]; then
    [[ -f "$ARG" ]] || die "not a file: $ARG"
    DMG="$ARG"
    info "Using local DMG: $DMG"
else
    need_mac
    if [[ -n "$ARG" || -n "${KINHIN_VERSION:-}" ]]; then
        TAG="${ARG:-$KINHIN_VERSION}"
        [[ "$TAG" == v* ]] || TAG="v$TAG"
    else
        info "Looking up the latest release of $REPO"
        TAG="$("${CURL[@]}" -sS "https://api.github.com/repos/$REPO/releases/latest" \
            | sed -n 's/.*"tag_name": *"*\([^"]*\)"*.*/\1/p' | head -n1)"
        [[ -n "$TAG" ]] || die "could not determine the latest release tag (is $REPO reachable and public? pin one: install.sh v0.1.0)"
    fi
    [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+(-[0-9]+)?)?$ ]] || die "unexpected release tag: $TAG"
    info "Fetching kinhin $TAG from GitHub Releases"
    BASE="https://github.com/$REPO/releases/download/$TAG"
    DMG_NAME="kinhin-${TAG#v}-arm64.dmg"
    "${CURL[@]}" -o "$TMP_DIR/$DMG_NAME" "$BASE/$DMG_NAME"
    "${CURL[@]}" -o "$TMP_DIR/checksums.txt" "$BASE/checksums.txt" \
        || die "no checksums.txt in release $TAG; refusing to install an unverified download"
    DMG="$TMP_DIR/$DMG_NAME"
fi

# ---------------------------------------------------------------------------
# Verify checksum when one is available (release checksums.txt or local .sha256)
# ---------------------------------------------------------------------------
CHECKSUMS=""
if [[ -f "$TMP_DIR/checksums.txt" ]]; then
    CHECKSUMS="$TMP_DIR/checksums.txt"
elif [[ -f "$DMG.sha256" ]]; then
    CHECKSUMS="$DMG.sha256"
fi
if [[ -n "$CHECKSUMS" ]]; then
    info "Verifying sha256"
    # Exact file-name match (optional `*` binary marker), first hit only.
    EXPECTED="$(awk -v f="$(basename "$DMG")" '$2 == f || $2 == "*" f {print $1; exit}' "$CHECKSUMS")"
    [[ -n "$EXPECTED" ]] || die "checksum file does not mention $(basename "$DMG")"
    echo "$EXPECTED  $DMG" | shasum -a 256 -c - >/dev/null \
        || die "checksum mismatch — do not install this download"
    info "Checksum OK"
elif [[ -n "$DMG" && -z "$TAG" ]]; then
    echo "warning: no $(basename "$DMG").sha256 next to the local DMG; its integrity is not checked" >&2
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
need_mac
mkdir -p "$MNT"
info "Mounting DMG"
# </dev/null: a piped (curl | bash) script must never be read by hdiutil's licence prompt.
hdiutil attach -nobrowse -readonly -quiet -mountpoint "$MNT" "$DMG" </dev/null \
    || die "could not mount the DMG"
[[ -d "$MNT/kinhin.app" ]] || die "kinhin.app not found in the DMG"

info "Checking the code signature"
codesign --verify --deep --strict "$MNT/kinhin.app" || die "kinhin.app has an invalid code signature"
if [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    # Release copy: the app must be signed by our Developer ID (not just by anyone
    # with a matching checksum), and Gatekeeper must accept it.
    REQ="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM_ID\""
    codesign --verify --strict -R="$REQ" "$MNT/kinhin.app" \
        || die "kinhin.app is not signed by the kinhin Developer ID (team $TEAM_ID); refusing to install it"
    spctl -a -t exec "$MNT/kinhin.app" 2>/dev/null \
        || die "Gatekeeper rejects kinhin.app (not notarized or revoked); refusing to install it"
else
    spctl -a -t exec "$MNT/kinhin.app" 2>/dev/null \
        || echo "note: Gatekeeper does not accept this build (ad-hoc or unnotarized, e.g. a fork); the signer is not pinned" >&2
fi

info "Copying kinhin.app to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
# Copy beside the destination first, then swap: a failed copy never leaves the
# machine without an app.
STAGE="$(mktemp -d "$INSTALL_DIR/.kinhin-install.XXXXXX")"
trap 'rm -rf "$STAGE"; cleanup' EXIT
ditto "$MNT/kinhin.app" "$STAGE/kinhin.app"
rm -rf "$INSTALL_DIR/kinhin.app"
mv "$STAGE/kinhin.app" "$INSTALL_DIR/kinhin.app"
rm -rf "$STAGE"

info "Linking kinhin CLI into $BIN_DIR"
mkdir -p "$BIN_DIR"
CLI_LINK="$BIN_DIR/kinhin"
if [[ -e "$CLI_LINK" || -L "$CLI_LINK" ]]; then
    existing="$(readlink "$CLI_LINK" 2>/dev/null || true)"
    case "$existing" in
        */kinhin.app/Contents/Resources/bin/*) ;;
        *) die "$CLI_LINK already exists and is not a kinhin link; move it aside and re-run" ;;
    esac
fi
ln -sf "$INSTALL_DIR/kinhin.app/Contents/Resources/bin/kinhin" "$CLI_LINK"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: $BIN_DIR is not in your PATH — add it to use 'kinhin' in a shell" >&2 ;;
esac

"$BIN_DIR/kinhin" version || echo "note: '$BIN_DIR/kinhin version' failed — check the install"

echo
echo "==> Installed kinhin${TAG:+ $TAG} to $INSTALL_DIR/kinhin.app"
echo "    Next steps:"
echo "      kinhin config init    # then set accounts: + labels in the config"
echo "      kinhin auth set       # GitHub PAT (stored in Keychain)"
echo "      kinhin doctor         # prerequisites + capacity check"
echo "      kinhin image prepare  # once; downloads the macOS base image"
echo "      kinhin start          # or: kinhin daemon install"
echo "    To remove later: bash scripts/install.sh --uninstall"
}

main "$@"
