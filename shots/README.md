# shots/ — UI capture & audit tooling

Ways to inspect kinhin's UI, plus the instruments they share.
**Prefer `scripts/capture-ui.sh`** — it is deterministic, needs no permissions or
running app, and never touches the Keychain or real config.

```
scripts/capture-ui.sh   offline capture: runs UICaptureTests (Tests/KinhinAppTests)
                        against a throwaway config and writes shots/out/cap-*.png
shots/
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
└── out/                artifacts (gitignored): cap-*.png, view.html, drive.py
                        captures
```

## Workflows

**Render every screen (no app needed):** every sidebar section and Diagnostics
pane plus the setup wizard, in light, dark and right-to-left, from the real window
controller:

```bash
scripts/capture-ui.sh                                  # writes shots/out/cap-*.png
KINHIN_CAPTURE_PAGES=runtimes,settings scripts/capture-ui.sh   # only some pages
python3 shots/tools/gallery.py                         # one viewable shots/out/view.html
swift shots/tools/probe.swift shots/out/cap-runtimes-light.png contrast X Y W H ...
```

Compare each image with its frame in `design/exports/` ("Design first" step 4 in
CONTRIBUTING.md). Add a new screen to `UICaptureTests` when you add one to the app.

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
