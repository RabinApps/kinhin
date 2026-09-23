#!/bin/bash
# Orchard one-line installer.
#
#   curl -fsSL https://github.com/OWNER/orchard/releases/latest/download/install.sh | bash
#   curl -fsSL ... | bash -s -- v0.1.0                        # pin a version
#   bash scripts/install.sh /path/to/Orchard-0.1.0-arm64.dmg  # offline / air-gapped
#
# What it does:
#   1. Fetches (or uses the given) Orchard-x.y.z-arm64.dmg from GitHub Releases
#   2. Verifies it against the release checksums.txt when one exists
#   3. Mounts the DMG and copies Orchard.app to /Applications    #   4. Symlinks the bundled orchard CLI into /usr/local/bin
#   5. Installs without Gatekeeper prompts: quarantine is applied by browsers,
#      not by curl, so a curl-fetched DMG launches cleanly. (A local DMG that
#      passed through a browser may still be quarantined; we clear that too.)
#
#   bash scripts/install.sh --uninstall      # reverses everything above
#
# Override destinations for testing / custom layouts:
#   REPO=owner/orchard INSTALL_DIR=/path BIN_DIR=/path bash scripts/install.sh ...
set -euo pipefail

REPO="${REPO:-OWNER/orchard}"
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
TMP_DIR="$(mktemp -d /tmp/orchard-install.XXXXXX)"
MNT="$TMP_DIR/mnt"
cleanup() { hdiutil detach "$MNT" -quiet 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

info() { echo "==> $*"; }
die()  { echo "error: $*" >&2; exit 1; }

need_mac() {
    [[ "$(uname -s)" == "Darwin" ]] || die "Orchard installs on macOS only"
    [[ "$(uname -m)" == "arm64" ]] || die "Orchard requires Apple Silicon (arm64)"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    need_mac
    if [[ -e "$INSTALL_DIR/Orchard.app" ]]; then
        info "Removing $INSTALL_DIR/Orchard.app"
        rm -rf "$INSTALL_DIR/Orchard.app"
    else
        info "No Orchard.app at $INSTALL_DIR (nothing to do there)"
    fi
    # Sweep every candidate bin dir; only remove symlinks that point into an
    # Orchard.app (a foreign `orchard` is never touched).
    for candidate in /opt/homebrew/bin/orchard /usr/local/bin/orchard "$HOME/.local/bin/orchard"; do
        if [[ -L "$candidate" && "$(readlink "$candidate")" == *Orchard.app* ]]; then
            info "Removing $candidate"
            rm -f "$candidate"
        fi
    done
    echo "note: kept your config, logs, and Keychain token:"
    echo "      ~/Library/Application Support/Orchard/   (remove manually if wanted)"
    echo "      'orchard auth clear' removes the Keychain PAT"
    echo "==> Orchard uninstalled."
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
    if [[ -n "$ARG" || -n "${ORCHARD_VERSION:-}" ]]; then
        TAG="${ARG:-$ORCHARD_VERSION}"
        [[ "$TAG" == v* ]] || TAG="v$TAG"
    else
        info "Looking up the latest release of $REPO"
        TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
            | sed -n 's/.*"tag_name": *"*\([^"]*\)"*.*/\1/p' | head -n1)"
        [[ -n "$TAG" ]] || die "could not determine the latest release tag (is $REPO reachable and public? pin one: install.sh v0.1.0)"
    fi
    info "Fetching Orchard $TAG from GitHub Releases"
    BASE="https://github.com/$REPO/releases/download/$TAG"
    curl -fL --retry 3 -o "$TMP_DIR/dmg" "$BASE/Orchard-${TAG#v}-arm64.dmg"
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
[[ -d "$MNT/Orchard.app" ]] || die "Orchard.app not found in the DMG"

info "Copying Orchard.app to $INSTALL_DIR"
rm -rf "$INSTALL_DIR/Orchard.app"
mkdir -p "$INSTALL_DIR"
# ditto preserves bundle structure/metadata and does not preserve quarantine
ditto "$MNT/Orchard.app" "$INSTALL_DIR/Orchard.app"
# Belt and suspenders for browser-downloaded DMGs (quarantine may be stamped
# on the mounted app itself before the copy)
xattr -dr com.apple.quarantine "$INSTALL_DIR/Orchard.app" 2>/dev/null || true

info "Linking orchard CLI into $BIN_DIR"
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/Orchard.app/Contents/Resources/bin/orchard" "$BIN_DIR/orchard"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: $BIN_DIR is not in your PATH — add it to use 'orchard' in a shell" >&2 ;;
esac

"$BIN_DIR/orchard" version || echo "note: '$BIN_DIR/orchard version' failed — check the install"

echo
echo "==> Installed Orchard${TAG:+ $TAG} to $INSTALL_DIR/Orchard.app"
echo "    Next steps:"
echo "      orchard config init    # then set repo + labels in the config"
echo "      orchard auth set       # GitHub PAT (stored in Keychain)"
echo "      orchard doctor         # prerequisites + capacity check"
echo "      orchard image prepare  # once; downloads the macOS base image"
echo "      orchard start          # or: orchard daemon install"
echo "    To remove later: bash scripts/install.sh --uninstall"
