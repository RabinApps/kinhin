# Contributing

`swift build` and `swift test` need no VMs or network. Layout, style, error-handling and commit conventions are in
[CLAUDE.md](CLAUDE.md); the package layout is in [docs/architecture.md](docs/architecture.md).

Before opening a PR:

```bash
swift format format -i -r Sources Tests
swift format lint --strict -r Sources Tests
swift test
```
