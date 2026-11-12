# Alerts

kinhin can push a message to a webhook when something is wrong, so a closed menu bar app or a headless host still
reaches you. The macOS notification the app posts is separate and unchanged.

The daemon compares the fleet's active problems (the same ones `kinhin status` and the app show) every 15 seconds. A
problem that appears is sent once; while it stays raised it is sent again only after `cooldown_seconds`; when it
clears, a `resolved` message follows. A dead endpoint is logged and never becomes a fleet problem itself.

## Configure

```yaml
alerts:
  enabled: true
  webhook:
    url: https://ntfy.sh/my-kinhin-topic
    format: ntfy
    headers_keychain: ops-alerts
  min_severity: warning
  cooldown_seconds: 3600
  notify_on_resolve: true
```

- `webhook.url` must be `https`; plain `http` is accepted only for `localhost`, `127.0.0.1` and `::1`.
- `webhook.format` shapes the body: `generic` (the event as JSON), `slack`, `discord`, or `ntfy` (plain text with a
  title). A helpdesk or paging service that accepts a webhook works through `generic`.
- `webhook.headers_keychain` names a Keychain item holding a bearer token, sent as `Authorization: Bearer <token>`. The
  token is never in `config.yaml`, and the log redactor masks it.
- `min_severity`: `critical` skips the engine's own retries (spawn backoff, orphan sweeps).

The daemon reads the config when it starts or rebuilds. A bad webhook or a missing Keychain item is logged and leaves
alerting off; it never stops the fleet.

## Store the token and test it

```bash
printf %s "$TOKEN" | kinhin alerts set-token ops-alerts --token-stdin
kinhin alerts test
```

`set-token NAME` stores the bearer token under the `headers_keychain` name (without `--token-stdin` it asks at a hidden
prompt). `alerts test` sends a test message through the configured webhook, even before `enabled` is true, and prints
only `scheme://host` of the endpoint. It exits 3 when `webhook.url` is not set and 4 when the endpoint does not accept
the message.

`kinhin doctor` has an `alerts` row once alerts are enabled. It is a failure, and `ready` turns false, when the
Keychain item named by `headers_keychain` is missing, because the daemon would leave alerting off.

## Generic payload

```json
{"host":"mini","message":"disk is full","severity":"critical","source":"disk","state":"firing","timestamp":"2026-11-11T19:33:25Z"}
```

`source` is the subsystem that raised the problem and is the key for deduplication.

## Not yet

Email, vendor ticket APIs and per-source routing are not part of this first version; each would be another sink next to
the webhook.
