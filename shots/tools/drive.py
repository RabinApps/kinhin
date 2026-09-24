#!/usr/bin/env python3
"""Drive the RUNNING kinhin app and capture its live window.

The offline harness (shots/capture/) is preferred for layout audits; use
this when you need the app exactly as launched (menu bar, real state).

Usage: python3 shots/tools/drive.py <action> <name>
Actions:
  fleet | config | runtimes   switch to a tab
  wizard                      open the onboarding overlay (step 1)
  step2 | step3 | step4       wizard forge / repos / finish (wizard first)

Writes shots/out/<name>.png (window capture via CGWindowID, occlusion-proof)
and shots/out/<name>-ax.txt (AX tree dump via tools/axdump.swift).
"""
import os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
DEST = os.path.join(ROOT, "shots", "out")
os.makedirs(DEST, exist_ok=True)

def osa(script, timeout=120):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=timeout)
    return r.stdout.strip(), r.stderr.strip()

def pid():
    out = subprocess.run(["pgrep", "-x", "kinhin"], capture_output=True, text=True).stdout.split()
    if not out:
        sys.exit("kinhin is not running")
    return out[0]

def axdump(name):
    subprocess.run(["swift", "axdump.swift", pid(), os.path.join(DEST, f"{name}-ax.txt")],
                   cwd=HERE, capture_output=True, timeout=120)

def capture(name):
    wid = subprocess.run(["./winid", "kinhin"], cwd=HERE, capture_output=True, text=True).stdout.strip()
    png = os.path.join(DEST, f"{name}.png")
    if wid:
        subprocess.run(["screencapture", "-x", "-o", f"-l{wid}", png], check=True)
    else:
        sys.exit("no kinhin window found")
    axdump(name)
    print(f"captured {name} (wid={wid})")

def click_segment(title):
    # The tab bar lives in the window's radio group.
    osa(f'tell application "System Events" to tell process "kinhin" '
        f'to click radio button "{title}" of radio group 1 of window 1')
    time.sleep(1.2)

def click_setup():
    osa('tell application "System Events" to tell process "kinhin" '
        'to click button "Setup" of window 1')
    time.sleep(0.8)

def advance_wizard(n):
    """Advance the wizard n steps. Continue is nested (AX click by title is
    unreliable) and the token field swallows Return, so click Continue by
    coordinates parsed from the live AX dump."""
    for _ in range(n):
        ax = subprocess.run(["swift", "axdump.swift", pid()], cwd=HERE,
                            capture_output=True, text=True, timeout=120).stdout
        rect = None
        for line in ax.splitlines():
            if "] Continue" in line or "] Start fleet" in line:
                try:
                    frame = line.split("[", 1)[1].split("]")[0]
                    x, y, w, h = (int(p) for p in frame.replace(" ", "").split(","))
                    rect = (x + w // 2, y + h // 2)
                    break
                except ValueError:
                    continue
        if not rect:
            sys.exit("Continue/Start-fleet button not found in AX")
        osa(f'tell application "System Events" to click at {{{rect[0]}, {rect[1]}}}')
        time.sleep(1.0)

action, name = sys.argv[1], sys.argv[2]
subprocess.run(["open", os.path.join(ROOT, "dist", "kinhin.app")], check=False)
time.sleep(0.5)

if action == "wizard":
    click_setup()
elif action == "step2":
    click_setup(); advance_wizard(1)
elif action == "step3":
    click_setup(); advance_wizard(2)
elif action == "step4":
    click_setup(); advance_wizard(3)
elif action == "config":
    click_segment("Config")
elif action == "runtimes":
    click_segment("Runtimes")
elif action == "fleet":
    click_segment("Fleet")
else:
    sys.exit(f"unknown action: {action}")

capture(name)
