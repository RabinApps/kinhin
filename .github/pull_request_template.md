## What and why

<!-- What changes, and what problem it solves. Link the issue if there is one. -->

## Type

- [ ] Behavior change
- [ ] Mechanical only (move, rename, formatting; kept out of behavior commits)
- [ ] Docs / website only
- [ ] `skills/` change (shipped product surface)

## Checklist

- [ ] `scripts/check.sh` passes (`--fast` is fine while iterating)
- [ ] `scripts/tsan.sh` run, if this touches shared state, actors, locks or `nonisolated(unsafe)`
- [ ] `cd website && npx vitepress build` run, if `docs/` or `website/` changed
- [ ] Tests added or updated
- [ ] `CHANGELOG.md` updated for user-visible changes
- [ ] User-facing app strings go through the String Catalog (`scripts/l10n-lint.sh`)

## Tested against

<!-- Real forge/runtime, or "unit tests only". kinhin is a beta; say so plainly. -->
