# Migrating from Orchard

Kinhin was previously named **Orchard**. If you ran a pre-rename build, upgrading is a normal
install — the migration is automatic:

- **Your data moves itself.** On first launch (CLI or menu bar), the old
  `~/Library/Application Support/Orchard/` directory — config, logs, toolchain cache, fleet
  state — is moved to `~/Library/Application Support/Kinhin/`. Nothing is re-downloaded,
  nothing is lost. If anything goes wrong, the legacy directory is left untouched for manual
  recovery.
- **Keychain tokens migrate on read.** PATs stored under the old `com.orchard.runner` service
  name are found, re-saved under the new one, and the legacy entry is removed.
- **In-flight VMs are not orphaned.** Instances the old build spawned (`orchard-…` names) are
  still recognized, adopted, and cleaned up by the new engine; new VMs use the `kinhin-…`
  prefix.
- **Forks keep updating.** A pre-rename `ORCHARD_UPDATE_REPO` environment override is still
  honored (the new `KINHIN_UPDATE_REPO` wins when both are set).
- **The old daemon is cleaned up.** `kinhin daemon uninstall` also removes the legacy
  `com.orchard.daemon` LaunchAgent; the installer's `--uninstall` removes a legacy
  `Orchard.app` and its symlinks.

## Manual cleanup (optional)

After a successful migration nothing of the old install remains except possibly:

```bash
~/Library/Application Support/Orchard/   # only if the automatic move failed
```

Remove it manually if you no longer need the fallback copy.
