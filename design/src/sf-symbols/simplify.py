"""Simplify the traced SF Symbol outlines (trace-symbols.swift output) into compact paths.

Usage:
  swiftc -O trace-symbols.swift -o trace && ./trace server.rack cpu person.2 > symbols.json
  python3 simplify.py symbols.json > ../icons.json
"""
import json, re, math, sys

def rdp(pts, eps):
    if len(pts) < 3: return pts
    (x1, y1), (x2, y2) = pts[0], pts[-1]; dx, dy = x2 - x1, y2 - y1; L = math.hypot(dx, dy)
    best, idx = 0, 0
    for i in range(1, len(pts) - 1):
        x, y = pts[i]
        dist = abs(dy * x - dx * y + x2 * y1 - y2 * x1) / L if L else math.hypot(x - x1, y - y1)
        if dist > best: best, idx = dist, i
    if best > eps: return rdp(pts[:idx + 1], eps)[:-1] + rdp(pts[idx:], eps)
    return [pts[0], pts[-1]]

out = {}
for name, v in json.load(open(sys.argv[1])).items():
    subs, cur = [], None
    for c, args in re.findall(r"([MLQCZ])([^MLQCZ]*)", v["d"]):
        nums = [float(x) for x in args.split()]
        if c == "M": cur = [(nums[0], nums[1])]; subs.append(cur)
        elif c == "L": cur.append((nums[0], nums[1]))
        elif c != "Z": cur.append((nums[-2], nums[-1]))
    parts = []
    for s in subs:
        if s[0] == s[-1]: s = s[:-1]
        if len(s) < 3: continue
        far = max(range(len(s)), key=lambda i: math.hypot(s[i][0] - s[0][0], s[i][1] - s[0][1]))
        ring = rdp(s[:far + 1], 0.07)[:-1] + rdp(s[far:] + [s[0]], 0.07)[:-1]
        if len(ring) >= 3: parts.append("M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in ring) + " Z")
    out[name] = {"w": round(v["w"], 2), "h": round(v["h"], 2), "d": " ".join(parts)}
json.dump(out, open("/dev/stdout", "w"))
