#!/bin/bash
# Runs the scripted demo fleet inside a disposable Tart macOS VM and pulls the recording back.
# The VM is a throwaway demo machine, not one of kinhin's runner VMs.
#
# Modes (how the guest gets, or doesn't get, a screen):
#   --gui        (default) `tart run`: a VM window on this Mac, the guest has a real desktop session.
#   --vnc        `tart run --no-graphics --vnc`: the same guest desktop, no window; connect with
#                Screen Sharing to the printed vnc:// URL to watch or click.
#   --headless   `tart run --no-graphics`: no desktop. Cannot screen-record; instead it builds, runs
#                the DemoTimeline unit tests and renders the offscreen UI captures (shots/capture),
#                copying shots/out/ back.
#
# Usage: video/adapters/kinhin/record-app-in-tart.sh [--gui|--vnc|--headless] [options]
#   --image NAME     base image to clone (default ghcr.io/cirruslabs/macos-tahoe-xcode:latest; needs full Xcode)
#   --vm NAME        VM name (default kinhin-demo; reused if it already exists)
#   --seconds N      recording length (default 50, one pass of the 48 s loop)
#   --user NAME      guest user (default admin)
#   --keep           leave the VM running afterwards (default: stop it; the VM disk is kept either way)
#   --delete         delete the VM afterwards instead of just stopping it
# Env: KINHIN_DEMO        demo script (built-in name, or a .json path inside the repo; default launch)
#      TART_SSH_PASSWORD  guest password (default admin, the Cirrus images' default); with `sshpass`
#                         installed it is used for ssh/rsync, otherwise set up an ssh key first.
#
# One-time, by hand, in --gui or --vnc mode (macOS will not let a script do these):
#   1. log the guest user into the desktop (Cirrus images auto-login; verify with this script's check),
#   2. System Settings > Privacy & Security > Screen Recording: allow Terminal (or the app you use). The guest's
#      `kinhin video record` window capture needs it; it leaves the pointer out of the take,
#      then `tart stop` and re-run: the permission persists in the VM disk.
set -euo pipefail

MODE=gui
IMAGE="ghcr.io/cirruslabs/macos-tahoe-xcode:latest"
VM=kinhin-demo
SECONDS_TO_RECORD=50
GUEST_USER=admin
KEEP=0
DELETE=0
PASSWORD="${TART_SSH_PASSWORD:-admin}"

while [ $# -gt 0 ]; do
  case "$1" in
    --gui) MODE=gui ;;
    --vnc) MODE=vnc ;;
    --headless) MODE=headless ;;
    --image) IMAGE="$2"; shift ;;
    --vm) VM="$2"; shift ;;
    --seconds) SECONDS_TO_RECORD="$2"; shift ;;
    --user) GUEST_USER="$2"; shift ;;
    --keep) KEEP=1 ;;
    --delete) DELETE=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

cd "$(dirname "$0")/../../.."   # the repository root
command -v tart >/dev/null || { echo "tart not found (kinhin setup repair tart, or brew install cirruslabs/cli/tart)" >&2; exit 1; }
command -v rsync >/dev/null || { echo "rsync not found" >&2; exit 1; }
mkdir -p video/raw/kinhin shots/out

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
WRAP=()
if command -v sshpass >/dev/null; then WRAP=(sshpass -p "$PASSWORD"); fi

TART_PID=""
IP=""
cleanup() {
  if [ "$KEEP" = 0 ]; then
    tart stop "$VM" >/dev/null 2>&1 || true
    [ -n "$TART_PID" ] && wait "$TART_PID" 2>/dev/null || true
    if [ "$DELETE" = 1 ]; then tart delete "$VM" >/dev/null 2>&1 || true; fi
  else
    echo "==> VM $VM left running${IP:+ at $IP}; stop it with: tart stop $VM"
  fi
}
trap cleanup EXIT

guest() { ${WRAP[@]+"${WRAP[@]}"} ssh "${SSH_OPTS[@]}" "$GUEST_USER@$IP" "$@"; }

# Runs a command inside the guest's logged-in desktop session (a plain ssh session is not in it, so
# GUI apps and the window capture `kinhin video record` uses would not see the display) and gives it a tty
# (dev-run.sh insists on one).
guest_gui() {
  local cmd="$1"
  guest "sudo launchctl asuser \$(id -u $GUEST_USER) sudo -u $GUEST_USER -H /usr/bin/script -q /dev/null /bin/bash -lc $(printf '%q' "$cmd")"
}

echo "==> VM $VM ($MODE)"
if ! tart list --quiet 2>/dev/null | grep -qx "$VM"; then
  echo "==> cloning $IMAGE (the first pull of a macOS image is tens of GB)"
  tart clone "$IMAGE" "$VM"
fi

RUN_ARGS=(run)
case "$MODE" in
  gui) ;;
  vnc) RUN_ARGS+=(--no-graphics --vnc) ;;
  headless) RUN_ARGS+=(--no-graphics) ;;
esac
tart "${RUN_ARGS[@]}" "$VM" >"video/raw/tart-$VM.log" 2>&1 &
TART_PID=$!

echo "==> waiting for the guest IP"
IP="$(tart ip "$VM" --wait 180)"
for _ in $(seq 1 60); do guest true 2>/dev/null && break; sleep 2; done
guest true 2>/dev/null || { echo "cannot ssh to $GUEST_USER@$IP (install sshpass, or ssh-copy-id; password via TART_SSH_PASSWORD)" >&2; exit 1; }
if [ "$MODE" = vnc ]; then
  echo "==> watch it: open the vnc:// URL in $PWD/video/raw/tart-$VM.log (or Screen Sharing to $IP)"
  grep -ho 'vnc://[^ ]*' "video/raw/tart-$VM.log" 2>/dev/null | tail -1 || true
fi

echo "==> copying the repo into the guest"
${WRAP[@]+"${WRAP[@]}"} rsync -a --delete \
  --exclude .git --exclude .build --exclude node_modules --exclude dist \
  --exclude video/raw --exclude video/out --exclude shots/out \
  -e "ssh ${SSH_OPTS[*]}" ./ "$GUEST_USER@$IP:kinhin-src/"

if [ "$MODE" = headless ]; then
  echo "==> headless: unit tests for the demo timeline, then the offscreen UI captures"
  guest "cd kinhin-src && swift test --filter DemoTimelineTests"
  guest "cd kinhin-src && shots/capture/build-captures.sh"
  ${WRAP[@]+"${WRAP[@]}"} rsync -a -e "ssh ${SSH_OPTS[*]}" "$GUEST_USER@$IP:kinhin-src/shots/out/" shots/out/
  echo "==> captures in shots/out/"
  exit 0
fi

echo "==> checking the guest has a desktop session"
CONSOLE_USER="$(guest 'stat -f %Su /dev/console')"
if [ "$CONSOLE_USER" != "$GUEST_USER" ]; then
  echo "the guest desktop is logged in as '$CONSOLE_USER', not '$GUEST_USER'." >&2
  echo "Log $GUEST_USER in (System Settings > Users & Groups > Automatically log in as), then re-run." >&2
  exit 1
fi
# The recorder is kinhin video record, so the probe is that command: --list-windows needs the same Screen Recording grant.
if ! guest_gui "cd \$HOME/kinhin-src && swift build --product kinhin >/dev/null && \"\$(swift build --product kinhin --show-bin-path)/kinhin\" video record --list-windows >/dev/null" >/dev/null 2>&1; then
  echo "kinhin video record failed in the guest: grant Screen Recording to Terminal in the guest" >&2
  echo "(System Settings > Privacy & Security > Screen Recording), restart the VM, then re-run." >&2
  exit 1
fi

echo "==> recording ${SECONDS_TO_RECORD}s in the guest (the first run builds the app, which takes a while)"
guest_gui "cd \$HOME/kinhin-src && KINHIN_DEMO=${KINHIN_DEMO:-launch} video/adapters/kinhin/record-app.sh $SECONDS_TO_RECORD"
mkdir -p video/raw/kinhin
for f in app.mov app.json; do
  ${WRAP[@]+"${WRAP[@]}"} scp "${SSH_OPTS[@]}" "$GUEST_USER@$IP:kinhin-src/video/raw/kinhin/$f" "video/raw/kinhin/$f"
done
echo "==> wrote video/raw/kinhin/app.mov"
