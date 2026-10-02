# Contributing

`swift build` and `swift test` need no VMs or network. Layout, style, error-handling and commit conventions are in
[CLAUDE.md](CLAUDE.md); the package layout is in [docs/architecture.md](docs/architecture.md).

Before opening a PR:

```bash
swift format format -i -r Sources Tests
swift format lint --strict -r Sources Tests
swift test
```

## Docs versions

The site at `/` is built from `main`. A release is snapshotted under `/<tag>/` (with a version picker in the nav):
after tagging a release, add its tag (for example `"v0.1.0"`) to the top of `website/versions.json` and push. The docs
workflow builds each listed tag from its own `docs/` and `website/` with `DOCS_VERSION=<tag>`, so a snapshot never
changes when `main` does. Tags cut before the picker existed (such as `v0.0.1-beta-1`) cannot be built this way.
