---
outline: [2, 3]
---

# Contributing to kinhin

`kinhin` is built by one developer, and the community makes it better. There are
two ways to contribute:

1. **Open an issue or PR** on [GitHub](https://github.com/RabinApps/kinhin) for
   bug reports, feature requests, and code changes. The
   [Contributing guide](https://github.com/RabinApps/kinhin/blob/main/CONTRIBUTING.md)
   covers the development workflow, and the
   [Architecture guide](https://github.com/RabinApps/kinhin/blob/main/docs/architecture.md)
   covers the package layout.
2. **Add your company or project to the list** of organizations running kinhin.
   See [external-contributors.md](https://github.com/RabinApps/kinhin/blob/main/docs/external-contributors.md).

## Before you open a PR

`swift build` and `swift test` need no VMs or network. Follow the conventions
in [CLAUDE.md](https://github.com/RabinApps/kinhin/blob/main/CLAUDE.md): no
print statements in `KinhinKit` or the app, errors are thrown, logging goes
through `Log`, and access control is `internal` unless explicitly needed.

```bash
swift format format -i -r Sources Tests
swift format lint --strict -r Sources Tests
swift test
```

From the repo root, `swift package --disable-sandbox dev` runs the debug app
with a stable signing identity so the Keychain's **Always Allow** answer
survives rebuilds.

## ThreadSanitizer

If you touch shared state, actors, locks, or anything `nonisolated(unsafe)`,
also run `scripts/tsan.sh` (serial, ~5–10 min).

## Where to start

- The [Architecture guide](https://github.com/RabinApps/kinhin/blob/main/docs/architecture.md)
  has the package layout and folder map.
- [CLAUDE.md](https://github.com/RabinApps/kinhin/blob/main/CLAUDE.md) has the
  contributor conventions (Swift, error handling, logging, tests).
- The [Issue tracker](https://github.com/RabinApps/kinhin/issues) has a list of
  good first issues.
