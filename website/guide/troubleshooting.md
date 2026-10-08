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
- **Token rejected** — re-run `kinhin auth set`; the PAT needs `repo` scope and access to the
  repo.
- **First launch blocked** — only applies to old releases or locally built copies (official
  releases are signed and notarized). Right-click → Open, or `xattr -cr /Applications/kinhin.app`.
