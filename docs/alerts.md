# Alerts

kinhin can push a message to one or more webhooks when something is wrong, so a closed menu bar app or a headless host still
reaches you. The macOS notification the app posts is separate and unchanged.

The daemon compares the fleet's active problems (the same ones `kinhin status` and the app show) every 15 seconds. A
problem that appears is sent once; while it stays raised it is sent again only after `cooldown_seconds`; when it
clears, a `resolved` message follows. A dead endpoint is logged and never becomes a fleet problem itself.

## Configure

```yaml
alerts:
  enabled: true
  cooldown_seconds: 3600
  min_severity: warning        # default for every webhook
  notify_on_resolve: true      # default for every webhook
  webhooks:
    - name: ops-slack
      url: https://hooks.slack.com/services/T000/B000/XXXX
      format: slack
      headers_keychain: ops-slack
      min_severity: critical
      events: [disk, credentials, queue, startup]
    - name: phone
      url: https://ntfy.sh/my-kinhin-topic
      format: ntfy
      notify_on_resolve: false   # every event type: `events` is omitted
```

Each entry of `webhooks` is one destination, and every webhook gets its own delivery record, cooldown and retries, so a
dead endpoint never holds back another.

- `name` is required and unique (letters, digits, `.`, `_`, `-`). It names the webhook in `kinhin alerts test --webhook`,
  `kinhin doctor` and the log, and is the default Keychain item name when the app stores a token.
- `url` must be `https`; plain `http` is accepted only for `localhost`, `127.0.0.1` and `::1`.
- `format` shapes the body: `generic` (the event as JSON), `slack`, `discord`, or `ntfy` (plain text with a
  title). A helpdesk or paging service that accepts a webhook works through `generic`.
- `headers_keychain` names a Keychain item holding a bearer token, sent as `Authorization: Bearer <token>`. The
  token is never in `config.yaml`, and the log redactor masks it.
- `events` picks the event types the webhook receives (below). Omitted means all of them, including problems outside
  the catalog (listed below); an empty list is an error.
- `min_severity` and `notify_on_resolve` override the `alerts:` values of the same name for this webhook.
  `critical` skips the engine's own retries (spawn backoff, orphan sweeps).
- `cooldown_seconds` is shared: how long a still-raised problem stays quiet before it is sent again.

`alerts.enabled: true` needs at least one webhook.

### Event types

| Event type      | Raised when                                                                  | Severity |
| --------------- | ---------------------------------------------------------------------------- | -------- |
| `disk`          | free disk is too low for the next instance plus the reserve                  | critical |
| `credentials`   | a forge token is rejected or expired                                         | critical |
| `queue`         | a forge's queue cannot be read (one alert per account)                        | critical |
| `spawn-backoff` | spawning keeps failing and the engine is backing off                          | warning  |
| `orphans`       | leftover VMs or containers of this fleet were found and are being swept      | warning  |
| `startup`       | the fleet could not start at all (no forge's token verifies)                 | critical |
| `test`          | the message `kinhin alerts test` sends (never filtered; not selectable)       | warning  |

The other problems the fleet reports (an adoption hold, a failed reconcile pass, one account's problem, a damaged state
file, the healing agent) belong to no event type, so only a webhook without an `events` list receives them.

### From a single webhook

The old form still works and is read as one webhook named `default`:

```yaml
alerts:
  enabled: true
  webhook:
    url: https://ntfy.sh/my-kinhin-topic
    format: ntfy
```

Use either `webhook` or `webhooks`, not both. The app's Alerts card rewrites the old form into `webhooks:` the first
time you change a webhook there.

The daemon reads the config when it starts or rebuilds. A bad webhook or a missing Keychain item is logged and leaves
that webhook off; it never stops the fleet or the other webhooks. The daemon tries again every minute, so a token stored
with `alerts set-token` takes effect without a restart. An alert that could not be delivered is sent again a minute later
(a problem that cleared, too), and redirects from the endpoint count as failures.
When the fleet cannot start at all (no forge's token verifies), the daemon sends one `startup` alert to every webhook
that wants that event type, since the usual loop only runs for a started fleet.

## In the app

**Advanced → App → Alerts** (under Telemetry) has the **Send alerts** switch and the list of webhooks. **Add webhook**
opens a sheet for the name, URL, format, an optional token (stored in the Keychain, never in the file), the minimum
severity and the event types; **Edit** changes them (leave the URL empty to keep it), **Test** sends the test message
through that webhook, **Remove** deletes it. The card shows each URL as `scheme://host` only. It edits `alerts.enabled`
and the `webhooks:` list of `config.yaml` and leaves the rest of the file alone (comments inside the `webhooks:` list
are not kept); alert delivery restarts with the new list.

## Store the token and test it

```bash
printf %s "$TOKEN" | kinhin alerts set-token ops-alerts --token-stdin
kinhin alerts test
kinhin alerts test --webhook ops-slack
```

`set-token NAME` stores the bearer token under the `headers_keychain` name (without `--token-stdin` it asks at a hidden
prompt). `alerts test` sends a test message through every configured webhook (or only `--webhook NAME`), even before
`enabled` is true and whatever the webhook's `events` say, and prints one line per webhook with only `scheme://host` of
the endpoint. It exits 3 when no webhook is configured or the name is unknown, and 4 when an endpoint does not accept the
message (every webhook is still tried).

`kinhin doctor` has an `alerts` row once alerts are enabled, with one line per webhook (its endpoint, format and event
types). A webhook is a failure, and `ready` turns false, when the Keychain item named by its `headers_keychain` is
missing, because the daemon would leave that webhook off.

## Generic payload

```json
{"host":"mini","message":"disk is full","severity":"critical","source":"disk","state":"firing","timestamp":"2026-11-11T19:33:25Z"}
```

`source` is the subsystem that raised the problem and is the key for deduplication.

## Not yet

Email and vendor ticket APIs are not part of this version; each would be another sink next to the webhook. Routing is
by event type, not by account or pool.
