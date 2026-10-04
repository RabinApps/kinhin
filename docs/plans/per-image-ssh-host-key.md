# Per-image SSH host key for Tart guests

## Goal

Remove the noisy boot-time unverified-host-key fallback for Tart runner VMs that are cloned from a prepared image, without weakening the existing threat model.

Today, every Tart runner VM rotates its sshd host key through the guest agent at boot, learns the new public key, and pins it per instance. If that fails or times out, the VM connects over SSH without host-key verification and the app records a warning for `kinhin doctor`. The new behavior should let a prepared image carry one known host key, so a clone can verify against that image key directly and avoid the per-VM rotation in the common case.

## Chosen approach

Bake one host key into the image once, and pin that key on the host once, keyed by image name.

This is the "image-bake pins a per-image host key so VM boots never need the guest-agent host-key dance" approach we selected. It is not "one static key shared silently across everything," and it is not "drop verification."

The key is per image, not per VM instance. That is intentional and limited: it removes the noisy boot-time unverified fallback and the per-instance known-hosts churn, while still requiring strict host-key verification. It does not make cloned VMs instance-distinct by host key, so the stronger shared-network isolation is still `tart_softnet: true`.

## New behavior

1. During `kinhin image prepare`, after the scratch VM is reachable over SSH, kinhin installs one sshd host key pair in the scratch VM, restarts sshd, reads the new `ssh-ed25519` public key back, and pins it on the host once under the image name.
2. Later, when a runner VM is cloned from that prepared image, the boot path verifies the SSH connection against that image key directly.
3. If the image key is present and verifies, the per-VM rotate-and-pin dance does not run for that boot.
4. If the image key is absent or strict verification against it fails, the runtime tries the existing per-VM guest-agent rotation once, and if that also fails, it falls back to the current unverified-SSH behavior and records the warning as today.

The fallback policy is explicit: do not hard-fail the boot, do not invent a third behavior, and keep the old safety net. The only change is that the image key is the preferred anchor first.

## Files to change

- `Sources/KinhinKit/Core/GuestHostKeyPinning.swift`
  - Add `ImageHostKey`, a small store for one pinned `ssh-ed25519 ...` line per image name.
  - Private directory `state/image-host-keys/`, one file per image, same owner-only private-file discipline as the existing private files.
  - API: `hasPinned(_:)`, `pinned(_:)`, `pin(_:publicKey:)`, `forget(_:)`, and `installInGuest(tart:vm:)` which runs the guest-side key generation/restart and returns the public key.
  - This is new code alongside the existing per-instance machinery, not a modification of `GuestHostKeyPins`.

- `Sources/KinhinKit/Images/ImagePreparer.swift`
  - In `prepareScratchVM`, replace the current "give the scratch VM its own SSH host key" step with: install one image host key into the scratch VM via `ImageHostKey.installInGuest(tart:vm:)`, then validate and pin it once under `options.target` via `ImageHostKey.pin(_:publicKey:)`.
  - This happens while the scratch VM is still the source of the later `tart clone` into the target image, so the key is baked into the committed image.

- `Sources/KinhinKit/Runtimes/Runtime.swift`
  - In `TartRuntime.awaitReady`, replace the unconditional per-VM host-key rotation with: if `ImageHostKey.hasPinned(route.image)` is true, verify against `ImageHostKey.pinned(route.image)`; if that verification fails, try the existing `GuestHostKeyPinning.pin` once; if that also fails, fall back to the current unverified behavior and record the warning as today.
  - The fallback reason text should make clear that the image key was trusted but did not match the booted clone.

- `docs/security.md`
  - Update the Tart guest SSH host-key verification note to describe the new path accurately: prepared images now have a pinned per-image host key learned during `kinhin image prepare`; booting a clone from a prepared image verifies against that image key first; if it matches, no per-VM rotation happens at boot; if it is missing or does not match, the runtime retries per-VM rotation once and then falls back to unverified SSH with a warning; the key is per image, not per VM instance, so the stronger shared-network isolation is still `tart_softnet: true`.

## What does not change

- Docker and Apple container runtimes: no host-key story there today, and none added here.
- The per-instance `GuestHostKeyPins` path: still used for the fallback and for any future per-instance rotation.
- The softnet story: unchanged. `tart_softnet: true` is still the main untrusted-code isolation control.
- GitHub scale-set work in `docs/plans/github-scaleset.md`: not touched by this plan.

## Non-goals

- A single static host key shared across all images. That would weaken the honest threat model and is not what we decided to do.
- Removing the per-VM rotate path entirely.
- Making the boot fail hard on a mismatched image key.
- Changing any Linux-container or Docker SSH behavior.

## Testability note

The existing `FakeTart` already supports `exec([String], timeout:)` and the per-VM host-key fake hooks, so this can be tested with the existing fakes. The image-key path should be testable through the same fake tart and fake SSH patterns already used for `GuestHostKeyPinningTests` and the image-bake tests.

## Verification

Before calling this done:

- `swift build`
- `swift test`
- `swift format lint --strict -r Sources Tests`
- `scripts/tsan.sh` if shared state / actors / locks are touched

The new store uses a `Mutex`-guarded directory and private file writes, so TSan is worth running.

## Open choice

Whether to land this as one commit or two:

- Option A: one commit for the store, the bake-time pinning, the runtime boot change, and the docs update.
- Option B: one commit for the store plus bake-time pinning, then a second commit for the runtime boot change and docs.

The runtime change depends on the store, but it is a separate behavioral step and a separate review surface. Docs can also be split out if that is preferred.
