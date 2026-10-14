# Troubleshooting

Start with `kinhin heal`: the [healing agent](/guide/healing) fixes many of the problems below on its own, lists the
fixes waiting for your approval, and says what only you can do.

- **`kinhin doctor` shows "tart: NOT FOUND"** — run `kinhin setup repair tart` (or use the setup
  window's fix button), then re-run `kinhin doctor`.
- **"tart: INSTALLED BUT KILLED ON LAUNCH ✗"** — the OpenAI-tap bottle is un-notarized;
  Gatekeeper kills it before it runs. `kinhin doctor` and the setup app print/offer the exact
  rollback commands; the manual equivalents are in [Installing Tart](/guide/install#installing-tart).
- **Jobs queue but no VMs start** — check that the job's `runs-on:` contains _every_ label in
  your config; the scaler only counts jobs it could actually run.
- **Scale set: `runner group 'default' was not found; create it in GitHub before attaching`** —
  with `scale_set:` on a GitHub account, kinhin looks the runner group up by an exact,
  case-sensitive name, and its default (`default`) is not GitHub's built-in group name
  (`Default`), so no scale set is ever created and the listener retries forever. Set
  `runner_group: "Default"` under `scale_set:` in `config.yaml`, spelled exactly as GitHub
  spells it, then restart the app — account-level config is not live-reloaded. Walkthrough:
  [Troubleshooting scale sets](/guide/forges/github#troubleshooting-scale-sets).
- **VM boots but the runner never registers** — the base image may predate the injected agent.
  Re-run `kinhin image prepare`. Full logs: `kinhin logs -n 200` or
  `~/Library/Application Support/Kinhin/logs/kinhin.log`.
- **`lifecycle failed: runner registration failed … ssh: connect to host <ip> port 22: Operation timed out`** —
  the fresh VM booted and got an IP, but its SSH server did not answer within the bring-up window
  (at least `vm_boot_timeout`, default 300s). Common causes: the **first boot of a freshly prepared
  image** (macOS first-boot work can delay sshd for minutes — big images like full Xcode are the
  usual offenders), the host being busy with a bake or other jobs, or a softnet hiccup. kinhin
  retries the TCP/SSH probes for the whole window, then deletes the VM and scales a fresh one — the
  job normally lands on the replacement, so an isolated occurrence is harmless. If it repeats:
  raise `vm_boot_timeout` (e.g. `600`) for slow images, keep the host quiet during boot storms,
  and re-prepare the image if the guest agent is flaky on every boot.
- **Tart: `Error Domain=VZErrorDomain Code=-9 "The virtual machine encountered a security error."`** (with
  `Failed to create new HostKey`; `tart ip` then says `no IP address found, is your VM running?`) — the
  macOS login keychain's password often differs from your account password. Check it with
  `security unlock-keychain ~/Library/Keychains/login.keychain-db`: if that says _The user name or passphrase
  you entered is not correct._, reset the keychain. In a reported case, over Screen Sharing, **Keychain
  Access → Settings → Reset My Default Keychain** fixed it. This deletes the passwords saved in the login
  keychain, so re-enter the ones you need, then confirm the kinhin token with `kinhin doctor --check-tokens`.
  Do not delete the keychain instead; that removes the same passwords without fixing the mismatch. Full
  steps: [Tart FAQ, Keychain password mismatch](https://tart.run/faq/#keychain-password-mismatch). Other
  errors such as `SecKeyCreateRandomKey_ios failed` can share this cause. Steps that did not help in the
  reported cases: reinstalling Tart, rebooting, stopping Multipass, updating the Command Line Tools.
- **Token rejected** — re-run `kinhin auth set`; the PAT needs `repo` scope and access to the
  repo.
- **First launch blocked** — only applies to old releases or locally built copies (official
  releases are signed and notarized). Right-click → Open, or `xattr -cr /Applications/kinhin.app`.

## Building kinhin and CI failures (for contributors)

CI builds on the `kinhin-xcode` runner with Xcode 26.5 (Swift 6.3.x). A newer Xcode on your Mac can accept code that
CI's compiler rejects or crashes on, so a green local build is not proof. Run the CI jobs on your branch and read the
log from the terminal:

```bash
gh workflow run ci.yml --ref my-branch                       # test, tsan and docs on your branch
gh run list --workflow ci.yml --branch my-branch --limit 3   # find the run
gh run view <run id> --json jobs --jq '.jobs[] | "\(.name) \(.conclusion) \(.databaseId)"'
gh api repos/RabinApps/kinhin/actions/jobs/<job id>/logs --allow-escape-sequences | sed 's/\x1b\[[0-9;]*m//g' > job.log
```

- **`error: passing closure as a 'sending' parameter risks causing data races` with the note `closure captures reference to
  mutable let 'x'`** (`SendingClosureRisksDataRace`) — a local `let x = Mutex(...)` is captured by a `Task` or `addTask`
  closure that the enclosing task also uses. Swift 6.3 rejects a noncopyable `Mutex` there; newer compilers accept it.
  Use `Locked(...)` (`Sources/KinhinKit/Core/Locked.swift`) instead: same `withLock`, but a `Sendable` class. After a
  crash or an error the compiler only reports the files it reached, so convert every local `Mutex` in the file (and
  its siblings), not only the line it names.
- **`compile command failed due to signal 6`, `SmallVector unable to grow`, and `While emitting IR SIL function
  "@$s…_TR"`** — the compiler crashed building a reabstraction thunk. The one we hit came from handing a main-actor
  method to an API as a function value (`Binding(get: …, set: select)`). Pass a closure instead (`set: { select($0) }`).
  `swift demangle '<the symbol>'` names the types in the thunk, which points at the code to look for. Bisect on CI with a
  throwaway `ci-bisect/*` branch whose workflow builds one product, since the failing compiler is not on your Mac.
- **Localization tests fail only on CI** (`the compiled String Catalog is missing from …kinhin_kinhin-app.bundle`, or text
  like `1 instances` where `1 instance` is expected) — Swift 6.3's default (native) build system copies
  `Localizable.xcstrings` without compiling it, so no plural forms exist. Build and test with `--build-system swiftbuild`
  (Swift 6.4 already defaults to it). Every kinhin script and workflow passes it; add it when you run `swift test` by hand
  with a 6.3 toolchain. A release packaged without it would ship an uncompiled catalog.
- **A test passes alone and locally but fails in `swift test --parallel` on CI**, for example because it finds files another
  test left behind — parallel runs use several processes that share the machine's temp directory. Give each test its own
  directory and never assert on, or clean, the shared temp directory. `UpdateChecker(downloadRoot:)` and the update tests
  show the pattern.
- **`docs` job: `Video suite … Cannot find package 'yaml'`** — that job runs the video unit tests with Node only. The video
  scripts load `yaml` lazily (only when a YAML config is read) and `scripts/video-check.sh` runs a one-time
  `npm ci --omit=dev` when `node_modules` is missing. Do not add top-level imports of packages to scripts that the CI planner or
  the claims check import.
- **Orphaned `kinhin daemon` processes after the e2e suite** — each belongs to a `/tmp/ke2e-*` sandbox that is gone. A
  sandbox now stops its daemons when it is disposed, and `scripts/e2e-sweep.sh --force` clears the rest. Check
  `ps eww -p <pid> | tr ' ' '\n' | grep KINHIN_SUPPORT_DIR` shows a `/tmp/ke2e-…` directory before you kill one by hand.
- **Reproducing CI's compiler locally** — the swift.org 6.3.2 toolchain can be unpacked without installing it
  (`pkgutil --expand-full`), but it needs an SDK from the same generation: this Mac's macOS 27 SDK needs Swift 6.4, so the
  build fails with `unknown argument: '-target-arch-variant'`. Without Xcode 26.5's SDK, use CI as the oracle.
