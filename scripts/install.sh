#!/bin/bash
# kinhin one-line installer.
#
#   curl -fsSL https://github.com/OWNER/kinhin/releases/latest/download/install.sh | bash
#   curl -fsSL ... | bash -s -- v0.1.0                        # pin a version
#   bash scripts/install.sh /path/to/kinhin-0.1.0-arm64.dmg  # offline / air-gapped
#
# What it does:
#   1. Fetches (or uses the given) kinhin-x.y.z-arm64.dmg from GitHub Releases
#   2. Verifies it against the release checksums.txt when one exists
#   3. Mounts the DMG and copies kinhin.app to /Applications
#   4. Symlinks the bundled kinhin CLI into the bin dir
#   5. Installs without Gatekeeper prompts: quarantine is applied by browsers,
#      not by curl, so a curl-fetched DMG launches cleanly. (A local DMG that
#      passed through a browser may still be quarantined; we clear that too.)
#
#   bash scripts/install.sh --uninstall      # reverses everything above
#
# Override destinations for testing / custom layouts:
#   REPO=owner/kinhin INSTALL_DIR=/path BIN_DIR=/path bash scripts/install.sh ...
set -euo pipefail

REPO="${REPO:-OWNER/kinhin}"
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
TMP_DIR="$(mktemp -d /tmp/kinhin-install.XXXXXX)"
MNT="$TMP_DIR/mnt"
cleanup() { hdiutil detach "$MNT" -quiet 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

info() { echo "==> $*"; }
die()  { echo "error: $*" >&2; exit 1; }

need_mac() {
    [[ "$(uname -s)" == "Darwin" ]] || die "kinhin installs on macOS only"
    [[ "$(uname -m)" == "arm64" ]] || die "kinhin requires Apple Silicon (arm64)"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    need_mac
    if [[ -e "$INSTALL_DIR/kinhin.app" ]]; then
        info "Removing $INSTALL_DIR/kinhin.app"
        rm -rf "$INSTALL_DIR/kinhin.app"
    else
        info "No kinhin.app at $INSTALL_DIR (nothing to do there)"
    fi
    # Pre-rename installs lived at Orchard.app; remove that too if present.
    if [[ -e "$INSTALL_DIR/Orchard.app" ]]; then
        info "Removing legacy $INSTALL_DIR/Orchard.app"
        rm -rf "$INSTALL_DIR/Orchard.app"
    fi
    # Sweep every candidate bin dir; only remove symlinks that point into a
    # kinhin.app or a legacy Orchard.app (a foreign `kinhin`/`orchard` is
    # never touched).
    for candidate in \
        /opt/homebrew/bin/kinhin /usr/local/bin/kinhin "$HOME/.local/bin/kinhin" \
        /opt/homebrew/bin/orchard /usr/local/bin/orchard "$HOME/.local/bin/orchard"; do
        if [[ -L "$candidate" ]] \
            && { [[ "$(readlink "$candidate")" == *kinhin.app* ]] || [[ "$(readlink "$candidate")" == *Orchard.app* ]]; }; then
            info "Removing $candidate"
            rm -f "$candidate"
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
        TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
            | sed -n 's/.*"tag_name": *"*\([^"]*\)"*.*/\1/p' | head -n1)"
        [[ -n "$TAG" ]] || die "could not determine the latest release tag (is $REPO reachable and public? pin one: install.sh v0.1.0)"
    fi
    info "Fetching kinhin $TAG from GitHub Releases"
    BASE="https://github.com/$REPO/releases/download/$TAG"
    curl -fL --retry 3 -o "$TMP_DIR/dmg" "$BASE/kinhin-${TAG#v}-arm64.dmg"
    curl -fL --retry 3 -o "$TMP_DIR/checksums.txt" "$BASE/checksums.txt" \
        || echo "note: no checksums.txt in this release; skipping verification"
    DMG="$TMP_DIR/dmg"
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
    EXPECTED="$(awk -v f="$(basename "$DMG")" '$2 ~ f {print $1}' "$CHECKSUMS")"
    [[ -n "$EXPECTED" ]] || die "checksum file does not mention $(basename "$DMG")"
    echo "$EXPECTED  $DMG" | shasum -a 256 -c - >/dev/null \
        || die "checksum mismatch — do not install this download"
    info "Checksum OK"
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
need_mac
mkdir -p "$MNT"
info "Mounting DMG"
hdiutil attach -nobrowse -readonly -quiet -mountpoint "$MNT" "$DMG" \
    || die "could not mount the DMG"
[[ -d "$MNT/kinhin.app" ]] || die "kinhin.app not found in the DMG"

info "Copying kinhin.app to $INSTALL_DIR"
rm -rf "$INSTALL_DIR/kinhin.app"
mkdir -p "$INSTALL_DIR"
# ditto preserves bundle structure/metadata and does not preserve quarantine
ditto "$MNT/kinhin.app" "$INSTALL_DIR/kinhin.app"
# Belt and suspenders for browser-downloaded DMGs (quarantine may be stamped
# on the mounted app itself before the copy)
xattr -dr com.apple.quarantine "$INSTALL_DIR/kinhin.app" 2>/dev/null || true

info "Linking kinhin CLI into $BIN_DIR"
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/kinhin.app/Contents/Resources/bin/kinhin" "$BIN_DIR/kinhin"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: $BIN_DIR is not in your PATH — add it to use 'kinhin' in a shell" >&2 ;;
esac

"$BIN_DIR/kinhin" version || echo "note: '$BIN_DIR/kinhin version' failed — check the install"

echo
echo "==> Installed kinhin${TAG:+ $TAG} to $INSTALL_DIR/kinhin.app"
echo "    Next steps:"
echo "      kinhin config init    # then set repo + labels in the config"
echo "      kinhin auth set       # GitHub PAT (stored in Keychain)"
echo "      kinhin doctor         # prerequisites + capacity check"
echo "      kinhin image prepare  # once; downloads the macOS base image"
echo "      kinhin start          # or: kinhin daemon install"
echo "    To remove later: bash scripts/install.sh --uninstall"
