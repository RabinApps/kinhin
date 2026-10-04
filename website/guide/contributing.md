---
outline: [2, 3]
---

# Contributing to kinhin

kinhin is built by one developer, and bug reports, feature requests and pull requests are welcome on
[GitHub](https://github.com/RabinApps/kinhin). Not writing code? You can also
[add your project to Who uses kinhin](/guide/used-by) or [support the project](/guide/support).

## Before you open a PR

`swift build` and `swift test` need no VMs or network. Follow the conventions
in [CONTRIBUTING.md](https://github.com/RabinApps/kinhin/blob/main/CONTRIBUTING.md): no
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

- The [Architecture guide](/guide/architecture) has the package layout, folder map and diagrams.
  On GitHub, read [docs/architecture.md](https://github.com/RabinApps/kinhin/blob/main/docs/architecture.md).
- [CONTRIBUTING.md](https://github.com/RabinApps/kinhin/blob/main/CONTRIBUTING.md) has the
  contributor conventions (Swift, error handling, logging, tests).
- The [Issue tracker](https://github.com/RabinApps/kinhin/issues) has a list of
  good first issues.
