"""Rebuild the named design pages, bind tokens, auto-fix, adopt the fixed file, lint and export.

Usage (from design/src, OpenPencil installed, design/kinhin-app.fig open):
  python3 finish_pages.py diag settings
Every page script is one of: fleet runtimes acct diag settings setup sheets components.
"""
import sys, json, subprocess, time, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
PAGES = {"fleet": ["Fleet"], "runtimes": ["Runtimes"], "acct": ["Accounts", "Toolchains"], "diag": ["Diagnostics"],
         "settings": ["Settings"], "setup": ["Setup & Menu"], "sheets": ["Sheets"], "components": ["Components"]}
scripts = sys.argv[1:] or list(PAGES)
os.chdir(HERE)
for s in scripts:
    subprocess.run(["python3", s + ".py"], check=True)
for s in scripts:
    for p in PAGES[s]:
        lib.dedupe(p)
expected = {p for names in PAGES.values() for p in names}
present = {p["name"] for p in lib._pages()}
missing = expected - present
if missing:
    sys.exit(f"refusing to save: the live document is missing pages {sorted(missing)} (would overwrite the file)")
r = lib._call(["eval", "--args", json.dumps({"code": open(os.path.join(HERE, "bind.js")).read()})])
print("bind", r.stdout.replace("\n", " "))
os.chdir(ROOT)
lib._act(); time.sleep(1)
subprocess.run(["openpencil", "documents", "save"])
subprocess.run(["openpencil", "lint", "design/kinhin-app.fig", "--fix", "-o", "/private/tmp/kinhin-fixed.fig"], capture_output=True)
subprocess.run(["cp", "/private/tmp/kinhin-fixed.fig", "design/kinhin-app.fig"])
subprocess.run(["osascript", "-e", 'tell application "OpenPencil" to quit']); time.sleep(3)
subprocess.run(["open", "-a", "OpenPencil", ROOT + "/design/kinhin-app.fig"]); time.sleep(8); lib._act(); time.sleep(2)
print(subprocess.run(["openpencil", "lint", "design/kinhin-app.fig"], capture_output=True, text=True).stdout[-200:])
for s in scripts:
    for p in PAGES[s]:
        f = p.lower().replace(" ", "-").replace("&", "-")
        subprocess.run(["openpencil", "export", "design/kinhin-app.fig", "--page", p, "-f", "png", "-s", "1", "-o", f"design/exports/{f}.png"], capture_output=True)
print("finished")
