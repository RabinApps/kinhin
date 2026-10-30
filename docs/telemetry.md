# Telemetry (OpenTelemetry)

kinhin can export metrics, traces and logs about the fleet and the jobs it runs over [OTLP](https://opentelemetry.io/docs/specs/otlp/),
and serve the metrics on a local Prometheus endpoint. It is **off by default**: until you turn it on, kinhin starts no exporter, opens no
port and sends nothing anywhere.

The OpenTelemetry Swift SDK is pinned to an exact release. Upstream marks traces stable and metrics and logs as still in development, so
expect the odd rough edge in those two signals, and treat this feature as beta.

## Turn it on

```yaml
telemetry:
  enabled: true
  endpoint: http://localhost:4318   # your collector (Grafana Alloy, the OpenTelemetry Collector, …)
```

That exports all three signals over OTLP/HTTP every 60 seconds. Edit the file and the running daemon picks the change up in place: no
engine restart, no duplicate exporters, and a Prometheus port from the old settings is released first.

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `false` | Master switch. Nothing below does anything while it is false (except `log_format`). |
| `endpoint` | `http://localhost:4318` (`:4317` for gRPC) | Collector base URL, `http` or `https`. For HTTP/protobuf kinhin appends `/v1/metrics`, `/v1/traces` and `/v1/logs`. |
| `protocol` | `http/protobuf` | `http/protobuf` or `grpc`. |
| `export_interval` | `60` | Seconds between metric pushes and between span and log batches (1–3600). |
| `signals` | all three | Any subset of `metrics`, `traces`, `logs`. |
| `resource_attributes` | none | Extra resource attributes. `service.name`, `service.version` and `telemetry.sdk.*` belong to kinhin and are rejected here. |
| `prometheus_listen` | off | `host:port`, or a bare port, which binds `127.0.0.1`. Serves `GET /metrics`. Needs `metrics` in `signals`. |
| `log_format` | `text` | `json` writes one JSON object per line to `kinhin.log` and stderr. Independent of `enabled`. |

Credentials are never read from `config.yaml`. Put collector headers in `OTEL_EXPORTER_OTLP_HEADERS` in the environment of the process that
runs the engine (for the daemon, its LaunchAgent environment). kinhin never logs them, and registers their values with the log redactor.

## Environment variables

Standard `OTEL_*` variables take precedence over the matching config key. The SDK does not apply them uniformly across signals, so kinhin
reads these itself and honours exactly this list:

| Variable | Effect |
| --- | --- |
| `OTEL_SDK_DISABLED=true` | Telemetry stays off whatever the config says. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Overrides `endpoint`. |
| `OTEL_EXPORTER_OTLP_{TRACES,METRICS,LOGS}_ENDPOINT` | A full per-signal URL, used as given (no path appended). |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` or `grpc`. |
| `OTEL_EXPORTER_OTLP_HEADERS` | `key=value,key2=value2` request headers (credentials). |
| `OTEL_METRIC_EXPORT_INTERVAL` | Milliseconds (1000–3600000). |
| `OTEL_{METRICS,TRACES,LOGS}_EXPORTER=none` | Removes that signal. |
| `OTEL_RESOURCE_ATTRIBUTES` | `key=value,…`, merged over `resource_attributes`. |

The environment never turns telemetry **on**; only `telemetry.enabled: true` does. A value kinhin cannot use is ignored and logged as a warning.
`OTEL_SERVICE_NAME` is not honoured: the service is always `kinhin`, so dashboards keyed on it keep working.

### Resource attributes

Precedence, lowest to highest: host defaults (`host.name`, `host.arch`, `os.type`, `os.version`, `service.instance.id`), then
`resource_attributes`, then `OTEL_RESOURCE_ATTRIBUTES`, then kinhin's own identity (`service.name=kinhin`, `service.version`, and the SDK's
`telemetry.sdk.*`), which nothing can override.

## Metrics

Names use dots; Prometheus shows them with underscores (`kinhin_workers`). Durations are in seconds, sizes in bytes, utilisation is a ratio.

| Metric | Kind | Attributes |
| --- | --- | --- |
| `kinhin.workers` | gauge | `pool`, `image`, `labels` (sorted), `state` (the lifecycle phase) |
| `kinhin.queue.depth` | gauge | `account` |
| `kinhin.queue.age.max` | gauge | none. Only while the forge reports when jobs were queued |
| `kinhin.fleet.desired`, `.active`, `.paused`, `.running` | gauge | none |
| `kinhin.fleet.capacity` | gauge | `kind` (`vm` or `job`) |
| `kinhin.warm_pool.size` | gauge | `pool`, `image` |
| `kinhin.warm_pool.claims`, `.evictions` | counter | `pool`, `image`, `forge` |
| `kinhin.jobs.picked_up`, `kinhin.jobs.completed` | counter | `pool`, `image`, `forge` (+ `result` on completed) |
| `kinhin.jobs.active` | gauge | none |
| `kinhin.job.run.duration` | histogram | `pool`, `image`, `forge`, `result` |
| `kinhin.job.queue_wait.duration` | histogram | `pool`, `image`, `forge`. Only with provider timestamps |
| `kinhin.vm.phase.duration` | histogram | `pool`, `image`, `forge`, `phase` (`provision`, `boot_ready`, `registration`, `teardown`) |
| `kinhin.runner.cpu.utilization`, `.memory.usage`, `.memory.limit` | gauge | `pool`, `image`. Aggregated over runners |
| `kinhin.host.cpu.utilization`, `.memory.usage`, `.memory.limit`, `.disk.free` | gauge | none |
| `kinhin.process.cpu.utilization`, `.memory.usage` | gauge | none (the daemon process) |
| `kinhin.forge.requests` | counter | `forge`, `status_class` (`2xx`…`5xx`, `error`) |
| `kinhin.forge.rate_limit.remaining`, `.limit` | gauge | `forge`, `account` |
| `kinhin.healing.actions` | counter | `result` (`succeeded`, `failed`) |
| `kinhin.healing.awaiting_approval` | gauge | none |
| `kinhin.errors` | counter | `error_type`, `component` |

`error_type` is one of `clone_failure`, `boot_timeout`, `ssh_unreachable`, `registration_failure`, `runner_not_registered`,
`instance_lost`, `forge_api_failure`, `rate_limited`, `teardown_failure`, `unknown`; `component` is `lifecycle`, `forge`, … Never the error text.

**Unavailable is not zero.** When a runtime or forge cannot supply a value, that series is absent. Today that means: per-runner disk use (no
runtime exposes it), the `queue.age.max` gauge and the queue-wait histogram on forges that do not report queue timestamps (GitHub does, through
the job's `created_at`), and CPU on the first sample after a start. `SSH-ready` is not timed apart from `boot_ready` because the runtimes do not
separate them.

### Cardinality and privacy

VM names, job and run IDs and trace and span IDs are **never** metric attributes: they appear only on spans and log records. Metric attributes
come from small closed sets (pool, image, forge, account, phase, result, error type, component) and the sorted runner labels from your config.
Per-repository and per-workflow dimensions are deliberately not on any metric: in an org-scoped fleet they are unbounded, so use traces for
that. Runner CPU and memory are aggregated per pool and image, never one series per VM.

Logs pass through the same redaction as the local log before export; tokens and registration secrets cannot reach a collector or the JSON log.
Spans and logs do carry repository, workflow and job names and VM names, so only point `endpoint` at a collector you trust with them.

## Traces

One trace per instance, from spawn to teardown. The root span `kinhin.job` carries `kinhin.vm.id`, `kinhin.pool`, `kinhin.image`,
`kinhin.forge`, `kinhin.runner.labels` and the final `kinhin.result`. Children, each only where there is a real measurement:

- `provision`, `boot_ready`, `registration`, `run`, `teardown`: timed by kinhin with the monotonic clock.
- `queue_wait`: from the forge's queue timestamp to its start timestamp, only when the forge supplied both.
- `step`: provider-reported steps with their own start and finish times, when kinhin has them.

On GitHub Actions the root span also gets `cicd.pipeline.run.id`, `kinhin.run.attempt`, `kinhin.job.id`, `cicd.pipeline.name`,
`cicd.pipeline.task.name` and `vcs.repository.name` once the running job is seen. A job that starts and finishes between two polls is still
counted (the forge's completion signal is used), but it has no `run` span and no run duration, because nothing observed its start.

## Logs

With `logs` selected, every log line also becomes an OTLP log record with its severity, `kinhin.component`, the VM (`kinhin.vm.id`) and job
when known, and the trace and span of the lifecycle it came from. `log_format: json` writes the same context locally:

```json
{"component":"kinhin-1717000000-a1b2c3d4","level":"info","message":"booted at 192.168.64.5","span_id":"…","trace_id":"…","ts":"2026-10-29T18:00:00.000Z","vm":"kinhin-1717000000-a1b2c3d4"}
```

`kinhin logs` and the app read the in-memory log, which is unaffected; only the file and stderr change shape.

## Prometheus

```yaml
telemetry:
  enabled: true
  signals: [metrics]
  prometheus_listen: 127.0.0.1:9464
```

`GET /metrics` serves the current metrics, collected at scrape time. Nothing else is served. `prometheus_listen` binds exactly the address you
write: a bare port or `127.0.0.1` stays on this Mac. **Binding `0.0.0.0` or a LAN address lets anyone who can reach that port read your fleet
metrics (pool names, labels, queue and capacity numbers) with no authentication.** kinhin logs a warning when you do; put a firewall or an
authenticating proxy in front of it. If the port cannot be bound, telemetry stays off and the error is logged.

## Reaching the collector

The daemon runs on the Mac and sends to `endpoint`, so `localhost` means the Mac. That is the right address for a collector on the same host.
Runner VMs and containers are separate machines to the network: a loopback address is **not** reachable from them, which matters only if you
forward telemetry from inside a job yourself.

## Who exports

The process that hosts the engine owns the exporters: the daemon, foreground `kinhin start`, or the menu bar app when it runs its own engine
because no daemon is up. An app attached to a daemon exports nothing; the daemon already does. The daemon and `kinhin start` flush on SIGTERM
and Ctrl-C; the app exports on its interval and does not flush on quit, so its last interval can be lost.

## Limitations

- **Step-level trace propagation is not implemented.** kinhin does not pass `TRACEPARENT` or a collector address into workflow steps. It
  needs a per-job runner hook, proof that context cannot leak between reused runners, and an explicitly reachable collector. Daemon-side traces
  are complete without it.
- Job identifiers and provider timestamps come from GitHub Actions. Other forges get the lifecycle spans and timings kinhin measures itself.
- Metrics and logs in the upstream SDK are still in development; pin and test before relying on them.
- Prometheus histogram buckets come out of the upstream text writer as per-bucket counts rather than cumulative `le` counts; use the OTLP
  path where `histogram_quantile` accuracy matters.
