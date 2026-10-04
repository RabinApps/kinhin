# Windows VMs on Apple Silicon — local fleet runtime, GitHub Actions first, both backends

> **Status:** substrate-probed, plan drafted. Not implemented.
> **Scope decision:** Apple Silicon host, Windows ARM guests first, GitHub Actions runner integration first, local Windows VMs via a scripted or Parallels backend, runners-only to start.
> **Substrate reality on this Mac:** Parallels Desktop 26.4.0 is installed with a real CLI automation surface; no scripted QEMU/UTM fallback is present; no usable Windows template/ISO/install media is present; the Parallels license here is expired and VM creation is admin-backed.

## 1. Goal

Make kinhin able to boot and manage **local Windows VMs on an Apple Silicon Mac**, as a real fleet runtime, with **GitHub Actions as the first supported forge for the Windows runner layer**. The runtime should be designed so other forges can be added later without rewriting it. The app should support **both** a scripted hypervisor backend and Parallels, without pretending the weaker backend is fleet-ready everywhere.

This is not "add Windows as a label." It is a new execution substrate with its own lifecycle, guest access, image/starter story, and per-forge Windows runner install/registration path.

## 2. What the repo already is, and isn't

kinhin is macOS-first CI runner software. Its only VM runtime today is **Tart**, which boots macOS and Linux guests on Apple Silicon through a `tart` binary. The existing runtime model is:

- `RuntimeID`: `tart`, `appleContainer`, `docker`, `host`
- runtime abstraction through the `Runtime` protocol: `health()`, `provision`, `awaitReady`, `execRegistration`, `existingInstanceIDs`, `registrationScript`, `teardown`
- Tart wrapped the way a fleet runtime should wrap a hypervisor: `TartControlling` protocol, `TartController` for the real binary, `UnavailableTart` stand-in, fakeable for tests
- mixed-fleet routing through `runtimes:`, pool labels, `selectRuntime`, `poolLabels(for:)`, and per-image label discipline (Linux Tart images strip `macos`)
- per-forge runner install/registration in `RunnerBootstrap`, with per-forge registration branches in `TartRuntime.registrationScript(...)`
- doctor/checklist/runtime-presence machinery in `SetupStatusComputer` + `DoctorReportBuilder`, same shape for container/docker/host

What is **not** in the repo:

- any Windows execution substrate
- Windows guest access (tart uses SSH over IP; Windows needs an equivalent)
- Windows agent install/registration scripts per forge
- a Windows image/starter story
- Windows usage/readiness probing
- any Parallels or QEMU/UTM integration

## 3. Substrate findings on this Mac

### Parallels is installed and has a real CLI automation surface

- `prlctl` and `prlsrvctl` are on PATH, version 26.4.0 (57513).
- `prlctl` covers the lifecycle verbs a fleet runtime would want: `list`, `create`, `delete`, `register`, `unregister`, `clone`, `start`, `stop`, `status`, `exec`, `enter`, `installtools`, `capture`, `send-key-event`.
- `prlctl exec` is the guest-access seam: it can run a command inside a VM with `--current-user`, `-u user`, `--password`, path resolution, and terminal mode control. This is the closest analog to tart's "SSH into the guest and exec."
- `prlctl list -i` can report `IP_ADDR`.
- `prlctl set` can mutate CPU/memory/boot/network/shared folders and device/policy categories, so sizing a VM is scriptable.

### But VM creation here is admin-backed and template-gated

- `prlctl create ... --ostype windows --distribution win-11` fails for a normal user with: *"The operation failed. To perform this operation, you must enter the host OS administrator's credentials."*
- The same create succeeds via the host admin path: a probe VM `kinhin-win-admin-probe` was created and deleted cleanly through admin-backed elevation.
- So **creation is automatable, but only with host-admin privileges** on this host.
- `prlsrvctl info` reports `Require password to: create-vm remove-vm clone-vm` and `Preferences are locked: on`.

### License state is a real constraint in this environment

- `prlsrvctl info` reports `License state: not valid` / `EXPIRED` (serial present, expiration 08/18/2026).
- That makes "Parallels = fleet-ready default on any Mac" a bad claim, even ignoring the admin gate.

### No usable Windows template/ISO/install media is present here

- The live list of registered VMs is empty after probe cleanup.
- The only leftover VM is a `Debian GNU Linux 12.5 ARM64` entry in state `invalid`, with a missing/corrupt config file: `prlctl register` says "configuration file ... invalid," and recreate-from-template says "Failed to find the ... template."
- `prlctl create --ostemplate list` prints "Failed to find the list template," so the template browser itself is not cleanly usable here.
- `ostype list` does include `windows` / `win`, and `distribution list` includes the full Windows ladder including `win-11`, `win-10`, `win-2022`, `win-2025`, and older entries. So the Windows knobs exist; what is missing is a usable template/ISO/install media in this environment.

### Guest access is plausible, but not end-to-end proven for a freshly-booted Windows VM here

- `prlctl exec --current-user` is the shape we would use, and it returns a clean "VM not found" on the invalid Debian entry rather than "exec unsupported."
- What was **not** proven: booting a real Windows VM, getting its IP, and running a command inside it as the right user without interactive UI. We proved creation-with-admin and the existence of the exec/IP seams; we did not prove Windows guest bring-up.

### No scripted QEMU/UTM fallback here

- `qemu-system-aarch64`, `qemu-system-x86_64`, `utm`, `vmrun`, `VBoxManage` are all not on PATH.
- `qemu-img` exists only because the Android SDK emulator bundled one at `~/Library/Android/sdk/emulator/qemu-img` — not a usable host hypervisor for Windows VMs in this repo's sense.
- No brew `qemu`/`utm`/`parallels` formula present.

## 4. What "support both" actually means

It does **not** mean one runtime that magically works on Parallels and on a scripted hypervisor. The honest shape is:

- **one `RuntimeID.windowsVm` runtime in kinhin**, with the same lifecycle/registration/labels/routing seams the existing runtimes use
- **a hypervisor abstraction** behind it, in the same spirit as `TartControlling`, with multiple implementations:
  - a **scripted hypervisor** implementation (QEMU/UTM-class) intended to be the fleet-ready path
  - a **Parallels** implementation treated as constrained: usable where its automation, admin path, license, and template/ISO situation actually allow it
- **the app/doc/runtime layer decides which implementation is active** based on what is installed and usable on the host, the same way kinhin already gates runtimes on `health()` and on whether a CLI is installed

That matches the repo's existing pattern exactly: Tart has `TartControlling` + `TartController` + `UnavailableTart`; Docker has its own runtime with its own health/checklist presence; and `RuntimeID` already supports mixing runtimes and routing jobs between them.

## 5. First-cut decisions

- **Host:** Apple Silicon.
- **Guest arch:** Windows ARM first.
- **Forge:** GitHub Actions first for the Windows runner layer; design the registration layer to admit other forges later without a rewrite.
- **Guest access seam:** `prlctl exec --current-user` as the first seam on the Parallels backend; the protocol leaves room for explicit user/password or a different access method later.
- **Backends:** ship the abstraction + the Parallels implementation now; keep the scripted-hypervisor backend as an interface for later, because it is not present on this Mac.

## 6. Plan

### 6.1 Confirm the substrate story before committing fleet code

Do not assert the fleet-ready backend from code alone. The probe already shows that on this Mac:

- Parallels CLI is real, but admin-gated, license-expired, and template/ISO-less.
- No scripted QEMU/UTM is present.
- No bootable Windows ARM guest exists here.

So the outcome is: the fleet-ready backend cannot be asserted from this environment. It has to be designed as an abstraction with a real implementation chosen per host. The plan proceeds with the abstraction, the Parallels implementation, and the runner layer, but end-to-end Windows VM validation waits on a bootable Windows ARM guest.

### 6.2 Model `WindowsHypervisor` in the `TartControlling` shape

Add the protocol the Windows runtime will depend on, injectable and fakeable like `TartControlling`.

- `list() -> [WindowsVM]` — existing Windows VMs this backend knows about
- `create(name, source, config) throws` — bootable Windows VM from a template/ISO/prebuilt source
- `start(name) throws`
- `stop(name) throws`
- `delete(name) throws`
- `status(name) -> WindowsVMStatus` — running/stopped/invalid and IP where available
- `exec(name, command, user) throws -> ExecResult` — the guest-access seam; first cut uses `prlctl exec --current-user`
- `ip(of name) throws -> String?` — guest address for the readiness path
- `configure(name, cpus, memory, ...) throws` — sizing a VM to the job's `vm:` settings
- `usage(of names) throws -> [String: ProcessSample]` — usage sampling where the backend supports it, else nothing

Add a fake/stand-in for tests, same pattern as `UnavailableTart`, with failures that read as "backend not available" rather than "no VMs."

Keep the protocol abstract enough that a scripted-hypervisor backend can implement it later without touching the runtime or engine. This is where "support both" lives: both backends implement one protocol; only the protocol is fleet-facing.

### 6.3 Implement the Parallels backend as the first real backend

Implement `WindowsHypervisor` on top of `prlctl`/`prlsrvctl`, with `prlctl exec --current-user` as the first guest-access seam.

- Wrap the CLI the way `TartController` wraps `tart`: a binary locator, shell-out, timeout handling, stderr parsing into typed errors.
- Lifecycle verbs map directly to `prlctl`: `list`, `create`, `delete`, `start`, `stop`, `status`, `exec`, `enter`, `installtools`, `capture`, `send-key-event`, plus `prlctl set`/`prlsrvctl` for config.
- Guest access uses `prlctl exec --current-user` as the first seam, with an explicit extension point for "we need a specific user/password" rather than pretending `--current-user` is universal.
- Treat Parallels creation as **admin-gated and license/template-gated** in both the implementation and the failure messages. The health/checklist surfaces should say so.
- Keep Parallels from being silently promoted to "first-class fleet hypervisor." If the host cannot create/start/exec a Windows VM without interactive admin, a valid license, or a usable template/ISO, the backend reports that clearly and kinhin treats Windows as unavailable there.

A thin scripted-hypervisor interface placeholder can be added for completeness if desired, but it should not be presented as validated fleet-ready on this Mac.

### 6.4 Add `RuntimeID.windowsVm` and the routing/labels skeleton

Extend the existing runtime model, reusing as much as possible.

- Add `windowsVm` to `RuntimeID` and give it a pool representation.
- Windows label story, not `macos`:
  - a `windows` label so workflows opt in with `runs-on: [self-hosted, windows, ...]`
  - an architecture label (`arm64` vs `x64`) because Apple Silicon makes that real and because the runner-agent/arch story differs by it
- Reuse existing mixed-fleet routing: `runtimes:`, per-repo/per-workflow routes, pool labels, `selectRuntime`, and the label discipline that already strips `macos` from Linux Tart runners. Windows should not advertise `macos` either.
- Add doctor/checklist presence for the Windows backend in the same shape as container/docker/host: is the backend installed/usable, is the image/template present, is the backend actually able to bring up a Windows guest.

### 6.5 Add the GitHub Actions-first Windows runner layer

Build the Windows runner path in `RunnerBootstrap`, starting with GitHub Actions, but keep it on the existing registration-script seam so other forges can be added later.

- Add a Windows-flavored GitHub runner install + registration script path, Windows ARM first if that is the substrate.
- Keep registration-script generation on the existing `Runtime.registrationScript(...)` shape, so the engine does not special-case Windows; the Windows runtime just produces a Windows-flavored registration script.
- Make the guest-access seam explicit in the Windows runtime's registration path, because installing/registering the runner happens inside the booted Windows guest via `exec`.
- Isolate per-forge registration logic the way `RunnerBootstrap` already does, so adding GitLab/Buildkite/Gitea/Forgejo/Azure DevOps/Bitbucket later is additive, not a rewrite. Do not implement those in the first cut.

### 6.6 Implement the Windows runtime lifecycle against `WindowsHypervisor`

Fill the `Runtime` protocol seams for Windows, same pattern as `TartRuntime`.

- `health()` — backend installed/usable + image/template present + able to bring up a Windows guest; shape matches the other runtimes' checklist/doctor mapping.
- `provision(id, route)` — create/start a Windows VM from the configured image/template/ISO source; reusable across backends because it goes through `WindowsHypervisor`.
- `awaitReady(id, timeout)` — wait for the VM to be up and reachable through the backend's IP/exec seam.
- `execRegistration(id, ip, script, timeout)` — run the Windows runner install/registration script inside the guest via the backend's `exec` seam.
- `existingInstanceIDs()` — enumerate through the backend's `list`.
- `teardown(id)` — stop then delete, idempotent, same tolerance for "already gone" as the tart teardown.

### 6.7 Add the Windows image/starter story — the first external dependency

This is the step that determines whether Windows VMs become real.

- Decide how a Windows ARM guest enters the system: Parallels template/ISO/install media, prebuilt pvm, or a scripted-hypervisor image build path.
- Surface "no usable Windows image/template/ISO" in doctor/checklist the same way the repo surfaces missing container/docker/tart images.
- This is where the Parallels limits from the probe matter most: if the environment lacks a usable template/ISO and the license/admin story is constrained, the Windows path cannot be validated end-to-end here until a bootable Windows ARM guest exists.

### 6.8 Wire Windows into engine presence/selection

- Make the Windows pool optional and mixed-fleet-capable, using the existing runtime-map/selection paths.
- Fail clearly when the configured backend is not usable, instead of silently pretending Windows jobs can run.
- Keep the "which backend is active" decision at config/health time, so the same config can mean different things on different Macs without the engine branching on Parallels-vs-scripted.

### 6.9 Make app/doc surfaces honest

- Report which Windows backend is available on this Mac and what it can actually do.
- Docs should say where Parallels support is limited (admin gate, license state, template/ISO dependency) and where the scripted path is the intended fleet story later.
- Keep GitHub Actions-first scope visible in doc/app wording; Windows runner integration starts with GitHub Actions.

## 7. Reusable vs new work

Reusable, mostly copy-shaped:

- `RuntimeID` and the `Runtime` protocol seams
- the routing/labels machinery: `runtimes:`, pool labels, `selectRuntime`, `poolLabels(for:)`, label stripping
- the doctor/checklist pattern in `SetupStatusComputer` + `DoctorReportBuilder`
- `RunnerBootstrap` and the per-forge registration-script branches

Genuinely new:

- the `WindowsHypervisor` abstraction and at least one real implementation
- Windows guest access (SSH-analog on Windows is a real choice; `prlctl exec --current-user` is the first Parallels candidate)
- Windows agent install/registration scripts per forge, starting with GitHub Actions
- the Windows image/starter story
- Windows usage/readiness probing
- the Parallels-specific constraints (admin gate, license, template/ISO) surfaced honestly

## 8. Open questions this plan leaves explicit

- **Windows image/template/ISO acquisition** is the first real blocker and is substrate-dependent. The abstraction, Parallels backend, and runner layer can be built first, but end-to-end Windows VM validation waits on a bootable Windows ARM guest.
- **Guest access beyond `--current-user`** — if a freshly-booted Windows VM does not let kinhin run as the current user, the exec seam may need explicit user/password or another access method. The protocol should leave room for that; the first cut uses `--current-user`.
- **Parallels as fleet backend vs dev/constrained backend** — the probe supports treating Parallels as "real but constrained," which is why this plan does not claim it as the fleet default everywhere.
- **Scripted-hypervisor backend** — the more likely fleet-ready shape, but not present on this Mac, so it is design-first until a Mac with it appears.

## 9. Suggested implementation order

1. `WindowsHypervisor` protocol + fake/stand-in
2. `ParallelsWindowsHypervisor` sketch around `prlctl`/`prlsrvctl`, with `exec --current-user` as the first guest-access seam
3. `RuntimeID.windowsVm` + pool/labels additions
4. Windows runtime lifecycle against `WindowsHypervisor`
5. GitHub Actions-first Windows runner install/registration path in `RunnerBootstrap`
6. doctor/checklist/runtime-presence additions for Windows
7. engine presence/selection wiring for the Windows pool
8. app/doc wording that is honest about Parallels limits and the scripted path being interface-only for now
9. Windows image/starter story, once a bootable Windows ARM guest source exists

## 10. Notes/assumptions

- This plan assumes Apple Silicon and Windows ARM as the first target because that is the host and the substrate that best fits it. x86 Windows is a separate substrate/compatibility question and is out of first-cut scope.
- "Runners-only to start" means the Windows VM's job is to host a registered runner and report job state; kinhin stays at the fleet/forge layer. Interactive guest access for live output/diagnostics is future work.
- The Parallels admin gate and expired license seen in this environment are environment symptoms, not necessarily universal, but they are exactly the kind of thing the app/doc surfaces must reflect honestly rather than abstract away.
