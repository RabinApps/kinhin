# shots/ — UI capture & audit tooling

Two independent ways to inspect kinhin's UI, plus the instruments they share.
**Prefer the harness** — it is deterministic, needs no permissions or running
app, and never touches the Keychain or real config.

```
shots/
├── capture/            offline harness (preferred)
│   ├── harness_main.swift    @main: renders wizard steps 1–4 + Config tab
│   ├── AppMainLite.swift     AppMain stand-in (kinhinPresentCrashAlert only)
│   └── build-captures.sh     compile harness WITH app sources → run → gallery
├── tools/              shared instruments
│   ├── axdump.swift          AX tree dump (role, frame, title/value) of the
│   │                         running app's window → for live-app layout audits
│   ├── winid.swift           CGWindowID of kinhin's window (occlusion-proof
│   │                         `screencapture -l` captures)
│   ├── probe.swift           WCAG contrast of text vs background inside PNG
│   │                         rects (coords are 2× on Retina captures)
│   ├── drive.py              drive the RUNNING app (tabs, wizard steps) and
│   │                         capture its window + AX dump
│   └── gallery.py            embed out/cap-*.png as data URIs → out/view.html
└── out/                artifacts (gitignored): cap-*.png, *-frames.txt,
                        view.html, drive.py captures
```

## Workflows

**Audit wizard + Config tab layout/contrast (no app needed):**

```bash
shots/capture/build-captures.sh     # writes shots/out/ and opens-ready gallery
swift shots/tools/probe.swift shots/out/cap-config.png contrast X Y W H ...
```

Then register `shots/out/view.html` as the thread preview to eyeball the PNGs.
Each capture also lands a `*-frames.txt` (view-frame tree, local coords) —
grep it for `[0,0 0x0]` zero-sized views or negative origins.

**Capture the live app** (real launch state, menu bar, daemon):

```bash
open dist/kinhin.app
python3 shots/tools/drive.py config myconfig
```

Requires Screen Recording + Accessibility permission for the terminal host.

**Run the app on a scripted demo fleet** (debug builds only; for screen
recordings, touches no config, Keychain, daemon or forge):

```bash
KINHIN_SUPPORT_DIR=$(mktemp -d) KINHIN_DEMO=launch scripts/dev-run.sh --env-tokens
```

The script lives in `Sources/kinhin-app/Demo/DemoTimeline.swift`: a 48 s loop of
queued jobs, instances cloning → booting → busy → deleted across all four forges
and three runtimes, with one failure and its retry.

## Gotchas learned the hard way

- **Never probe the real Keychain from test scripts**: `SecItemCopyMatching`
  on an ACL-protected item pops a `SecurityAgent` dialog that ignores
  synthetic clicks and freezes every later Keychain read (including the
  app's own bootstrap). The harness avoids Keychain entirely; `drive.py`
  only drives UI. `security find-generic-password` metadata is safe; `-w`
  is not.
- The Freebuff preview server serves **one registered file** — gallery.py
  inlines captures as base64 data URIs so nothing 404s.
- `entire contents of window` in AppleScript is unreliable for this app;
  use `tools/axdump.swift` (Accessibility API) instead.
- Ad-hoc-signed binaries' Keychain ACLs don't survive rebuilds (`-T` grants
  are by code identity). Don't try to make placeholder Keychain items work.
