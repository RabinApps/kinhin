#!/usr/bin/env python3
"""Embed the latest capture PNGs as base64 data URIs in shots/out/view.html
so the whole gallery is viewable in the Freebuff preview (its static server
serves single registered files only — hence data URIs, no asset requests).

Usage: python3 shots/tools/gallery.py [name1.png name2.png ...]
Defaults to every cap-*.png in shots/out/.
"""
import base64, sys, os, glob

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.normpath(os.path.join(here, "..", "out"))

names = sys.argv[1:] or sorted(os.path.basename(p) for p in glob.glob(os.path.join(out, "cap-*.png")))
if not names:
    sys.exit("no captures found — run shots/capture/build-captures.sh first")

parts = ["""<!doctype html>
<html><head><meta charset="utf-8"><title>kinhin UI captures</title>
<style>body{margin:16px;background:#1c1c1e;color:#fff;font:14px -apple-system}
img{border:1px solid #555;max-width:100%}
h2{margin:14px 0 6px;font-size:15px}</style></head>
<body>"""]
for name in names:
    with open(os.path.join(out, name), "rb") as f:
        b64 = base64.b64encode(f.read()).decode()
    title = os.path.splitext(name)[0].replace("cap-", "").replace("-", " ")
    parts.append(f'<h2>{title}</h2>\n<img src="data:image/png;base64,{b64}" alt="{name}">\n')
parts.append("</body></html>\n")

dest = os.path.join(out, "view.html")
with open(dest, "w") as f:
    f.write("\n".join(parts))
print(f"wrote {dest} with {len(names)} image(s)")
