#!/bin/bash
# Remove what an interrupted end-to-end run leaves behind: kinhin daemons the suite started, forge and runner
# containers it created, and its /tmp/ke2e-* sandboxes. Safe to run any time; it does nothing while a run is active,
# and it only touches things the suite created (sandboxes named ke2e-*, containers named ke2e-* or built from a
# ke2e-* image), never a real fleet.
#
#   scripts/e2e-sweep.sh           sweep
#   scripts/e2e-sweep.sh --force   sweep even if a run looks active
set -u

if [ "${1:-}" != "--force" ] && pgrep -f "E2ETests.xctest" >/dev/null 2>&1; then
  echo "e2e-sweep: a run is active; nothing swept (use --force to override)"
  exit 0
fi

swept=0
# Host-lane runner agents live in a sandbox (/tmp/ke2e-<id>/host-runner/...), so their command lines name it.
pkill -f "/ke2e-[a-z0-9]*/host-runner/" 2>/dev/null
for dir in /tmp/ke2e-*; do
  [ -d "$dir" ] || continue
  if [ -f "$dir/daemon.pid" ]; then
    pid="$(cat "$dir/daemon.pid" 2>/dev/null)"
    # Only a kinhin daemon, never a recycled pid.
    if [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -q "kinhin daemon"; then
      kill "$pid" 2>/dev/null
      sleep 1
      kill -9 "$pid" 2>/dev/null
      swept=$((swept + 1))
    fi
  fi
  rm -rf "$dir"
done

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker ps -a --format '{{.Names}} {{.Image}}' | while read -r name image; do
    case "$name" in ke2e-*|ke2ed-*) docker rm -f -v "$name" >/dev/null 2>&1 ;; esac
    case "$image" in ke2e-*) docker rm -f -v "$name" >/dev/null 2>&1 ;; esac
  done
fi

# Tart images the suite baked and the runner clones it made are both named ke2e-*. A real fleet's kinhin-* VMs are
# left alone: the suite's daemon never mints or adopts them, and a Tart lane refuses to start while any exist.
if command -v tart >/dev/null 2>&1; then
  tart list --source local --quiet 2>/dev/null | while read -r name; do
    case "$name" in ke2e-*|ke2ed-*) tart stop "$name" >/dev/null 2>&1; tart delete "$name" >/dev/null 2>&1 ;; esac
  done
fi

echo "e2e-sweep: done ($swept orphaned daemon(s) stopped)"
