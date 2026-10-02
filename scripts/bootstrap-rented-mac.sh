#!/bin/bash
# Prepare a freshly rented Apple Silicon Mac (MacStadium, Scaleway, AWS EC2 Mac, ...) to run kinhin.
#
#   ssh admin@your-mac 'bash -s' < scripts/bootstrap-rented-mac.sh
#   bash scripts/bootstrap-rented-mac.sh            # or run it on the Mac itself
#
# What it does (idempotent; safe to re-run):
#   1. Checks the host: Apple Silicon, macOS 15+, Homebrew present
#   2. Installs Tart (brew) if missing
#   3. Installs kinhin with the official installer if `kinhin` is not on PATH
#   4. Creates a starter config with `kinhin config init` if none exists
#   5. Prints the remaining steps
#
# What it deliberately does not do: store a forge token. Tokens go into the login Keychain with
# `kinhin auth set`, typed by the account owner, never passed as a script argument or env var.
# See docs/rented-mac.md for the full walkthrough, including the Keychain/auto-login caveat.
set -euo pipefail

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "this script prepares a Mac; run it on the rented Mac"
[[ "$(uname -m)" == "arm64" ]] || die "kinhin needs Apple Silicon (arm64); this host is $(uname -m)"

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
(( macos_major >= 15 )) || die "kinhin needs macOS 15 or newer; this host runs $(sw_vers -productVersion)"

# Homebrew lives outside PATH in a non-interactive ssh session.
for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x $brew_bin ]] && eval "$("$brew_bin" shellenv)" && break
done
command -v brew >/dev/null || die "Homebrew not found; install it first (https://brew.sh), then re-run"

if command -v tart >/dev/null; then
    say "tart already installed ($(tart --version))"
else
    say "installing tart"
    brew tap openai/tools
    brew trust openai/tools
    brew install openai/tools/tart
fi

if command -v kinhin >/dev/null; then
    say "kinhin already installed ($(kinhin version))"
else
    say "installing kinhin"
    curl --proto '=https' --tlsv1.2 -fsSL \
        https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
    # The installer may have used ~/.local/bin, which a non-interactive shell does not have on PATH.
    export PATH="$HOME/.local/bin:$PATH"
    command -v kinhin >/dev/null || die "kinhin installed but not on PATH; check the installer output"
fi

config="$HOME/Library/Application Support/Kinhin/config.yaml"
if [[ -f $config ]]; then
    say "config already exists: $config"
else
    say "creating starter config"
    kinhin config init
fi

cat <<EOF

Next, on this Mac (see docs/rented-mac.md):

  1. Edit the config:   $config
       set the accounts: entry (forge, scope) and the labels your jobs request
  2. Unlock the login Keychain for this session (needed over plain ssh):
       security unlock-keychain ~/Library/Keychains/login.keychain-db
  3. Store the forge token:   kinhin auth set        # or --gitlab, --gitea, ...
  4. Check the host:          kinhin doctor
  5. Bake the base image:     kinhin image prepare   # once, takes a while
  6. Run it headless:         kinhin daemon install  # needs a GUI login session; see the doc
EOF
