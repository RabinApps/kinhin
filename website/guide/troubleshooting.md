# Troubleshooting

- **`kinhin doctor` shows "tart: NOT FOUND"** — install tart with
  `brew tap openai/tools && brew trust openai/tools && brew install openai/tools/tart`,
  then re-run `kinhin doctor`.
- **"tart: INSTALLED BUT KILLED ON LAUNCH ✗"** — the OpenAI-tap bottle is un-notarized;
  Gatekeeper kills it before it runs. Roll back to the notarized Cirrus Labs build —
  `kinhin doctor` and the setup app print/offer the exact commands:
  ```bash
  brew uninstall openai/tools/tart openai/tools/softnet
  brew tap cirruslabs/cli
  brew trust cirruslabs/cli
  brew install cirruslabs/cli/tart
  ```
- **Jobs queue but no VMs start** — check that the job's `runs-on:` contains _every_ label in
  your config; the scaler only counts jobs it could actually run.
- **VM boots but the runner never registers** — the base image may predate the injected agent.
  Re-run `kinhin image prepare`. Full logs: `kinhin logs -n 200` or
  `~/Library/Application Support/Kinhin/logs/kinhin.log`.
- **Token rejected** — re-run `kinhin auth set`; the PAT needs `repo` scope and access to the
  repo.
- **First launch blocked** — only applies to old releases or locally built copies (official
  releases are signed and notarized). Right-click → Open, or `xattr -cr /Applications/kinhin.app`.
- **Upgrading from the old name** — see [Migrating from Orchard](/guide/migrating); the
  migration runs automatically on first launch.
