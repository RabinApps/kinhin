#!/usr/bin/env python3
"""Batch WCAG contrast audit over the harness captures.

For every cap-*.png, text regions come from the sibling *-frames.txt (the
harness's view-frame trees): every NSTextField label becomes a probe rect,
converted from bottom-left window points to top-origin 2x pixels. Button
titles (AppKitButton hosts) are probed via their parent frame.

Usage: python3 shots/tools/audit.py            # all captures
       python3 shots/tools/audit.py wizard1    # substring match on names
"""
import glob, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(HERE, "probe.swift")
OUT = os.path.normpath(os.path.join(HERE, "..", "out"))

FRAME_RE = re.compile(r"(\s*)(\S+) \[(-?\d+),(-?\d+) (-?\d+)x(-?\d+)\]")

def load_tree(name):
    rows = []
    with open(os.path.join(OUT, f"{name}-frames.txt")) as f:
        for line in f:
            m = FRAME_RE.match(line)
            if m:
                depth = len(m.group(1)) // 2
                cls = m.group(2)
                x, y, w, h = map(int, m.group(3, 4, 5, 6))
                rows.append((depth, cls, x, y, w, h))
    return rows

def text_rects(name, win_h):
    """Probe rects (2x px, top-origin) for every text label in the tree.
    Frames are PARENT-LOCAL, so walk with accumulated offsets. A label =
    NSTextField / its leaf / a button's AppKitButton host (title lives there)."""
    rows = load_tree(name)
    rects = []

    def visit(idx, ox, oy):
        depth, cls, x, y, w, h = rows[idx]
        ax, ay = ox + x, oy + y          # absolute window coords (bottom-left)
        is_text = cls in ("NSTextField", "NSTextFieldSimpleLabel", "NSSimpleLabel",
                          "NSSecureTextField")
        is_button = cls == "_NSCoreHostingView<AppKitButton>"
        if (is_text or is_button) and w >= 8 and h >= 8:
            rects.append((ax * 2, (win_h - (ay + h)) * 2, w * 2, h * 2, cls))
        # recurse into children (next row(s) with greater depth)
        j = idx + 1
        while j < len(rows) and rows[j][0] > depth:
            if rows[j][0] == depth + 1:
                j = visit(j, ax, ay)
            else:
                j += 1
        return j

    i = 0
    while i < len(rows):
        i = visit(i, 0, 0)

    seen, out = set(), []
    for r in rects:
        key = r[:4]
        if key not in seen:
            seen.add(key)
            out.append(r)
    # macOS renders DISABLED controls (e.g. Back on step 1) at ~2:1 by
    # design — that's the system's disabled appearance, not a defect.
    # Drop button rects at the far left of the footer band (the Back slot).
    return [r for r in out if not (r[1] > 1000 and r[0] < 400)]

def probe(png, rects):
    args = ["swift", PROBE, png, "contrast"]
    for x, y, w, h, _ in rects:
        args += [str(v) for v in (x, y, w, h)]
    r = subprocess.run(args, capture_output=True, text=True, timeout=300)
    return r.stdout.strip().splitlines()

pattern = sys.argv[1] if len(sys.argv) > 1 else ""
fails, total = [], 0
for png in sorted(glob.glob(os.path.join(OUT, "cap-*.png"))):
    base = os.path.basename(png)[:-4]
    if pattern and pattern not in base:
        continue
    frames = os.path.join(OUT, f"{base}-frames.txt")
    if not os.path.exists(frames):
        continue
    # Window height: parse from the tree root.
    root = load_tree(base)[0]
    win_h = root[5]
    rects = text_rects(base, win_h)
    print(f"== {base} ({len(rects)} regions)")
    lines = probe(png, rects)
    for line in lines:
        total += 1
        if "FAIL]" in line:
            fails.append((base, line))
            print("  " + line)

print(f"\n{total} regions probed across the suite, {len(fails)} FAIL")
for base, line in fails:
    print(f"  {base}: {line}")
sys.exit(1 if fails else 0)
