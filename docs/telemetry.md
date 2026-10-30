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
| `export_interval_seconds` | `60` | Seconds between metric pushes and between span and log batches (1–3600). `export_interval` is accepted as an alias. |
| `signals` | all three | Any subset of `metrics`, `traces`, `logs`. |
| `resource_attributes` | none | Extra resource attributes. `service.name`, `service.version` and `telemetry.sdk.*` belong to kinhin and are rejected here. |
| `prometheus_listen` | off | `host:port`, or a bare port, which binds `127.0.0.1`. Serves `GET /metrics`. Needs `metrics` in `signals`. |
| `log_format` | `text` | `json` writes one JSON object per line to `kinhin.log` and stderr. Independent of `enabled`. |
| `job_attributes` | none | `[repository, workflow]` adds those dimensions to the job counters and histograms. See [Cardinality](#cardinality-and-privacy). |

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

Names use dots; Prometheus shows them with underscores (`cicd_worker_count`). Durations are in seconds, sizes in bytes, utilisation is a ratio.
Names and attributes follow the [OpenTelemetry CI/CD semantic conventions](https://opentelemetry.io/docs/specs/semconv/cicd/) where one
exists (`cicd.worker.*`, `cicd.pipeline.*`, `cicd.system.*`, `error.type`) and are `kinhin.`-prefixed otherwise.

| Metric | Kind | Attributes |
| --- | --- | --- |
| `cicd.worker.count` | gauge | `kinhin.pool`, `kinhin.image`, `kinhin.runner.labels` (sorted), `cicd.worker.state` (the lifecycle phase) |
| `kinhin.queue.depth` | gauge | `kinhin.account` |
| `kinhin.queue.pool.depth` | gauge | `kinhin.pool` |
| `kinhin.queue.age` | gauge | none. The oldest queued job; only while the forge reports when jobs were queued |
| `kinhin.fleet.desired`, `.active`, `.paused`, `.running` | gauge | none |
| `kinhin.pool.capacity` | gauge | `kinhin.pool` |
| `kinhin.warm_pool.size` | gauge | `kinhin.pool`, `kinhin.image` |
| `kinhin.warm_pool.claims`, `.evictions` | counter | `kinhin.pool`, `kinhin.image`, `kinhin.forge` |
| `kinhin.jobs.picked_up` | counter | `kinhin.pool`, `kinhin.image`, `kinhin.forge` |
| `kinhin.jobs.completed` | counter | the same, plus `cicd.pipeline.result` (+ `job_attributes`) |
| `cicd.pipeline.run.active` | gauge | none |
| `cicd.pipeline.run.duration` | histogram | `kinhin.pool`, `kinhin.image`, `kinhin.forge`, `cicd.pipeline.result` (+ `job_attributes`) |
| `kinhin.job.queue_wait.duration` | histogram | `kinhin.pool`, `kinhin.image`, `kinhin.forge` (+ `job_attributes`). Only with provider timestamps |
| `kinhin.runner.provision.duration` | histogram | the pool attributes plus `kinhin.runner.phase` (`clone`, `boot`, `register`) |
| `kinhin.runner.teardown.duration` | histogram | `kinhin.pool`, `kinhin.image`, `kinhin.forge` |
| `kinhin.runner.cpu.utilization`, `.memory.usage`, `.memory.limit` | gauge | `kinhin.pool`, `kinhin.image`. Aggregated over runners |
| `kinhin.host.cpu.utilization`, `.memory.usage`, `.memory.limit`, `.disk.free` | gauge | none |
| `process.cpu.utilization`, `process.memory.usage` | gauge | none (the daemon process) |
| `kinhin.forge.api.requests` | counter | `kinhin.forge`, `http.response.status_class` (`2xx`…`5xx`, `error`) |
| `kinhin.forge.rate_limit.remaining`, `.limit` | gauge | `kinhin.forge`, `kinhin.account` |
| `kinhin.healing.actions` | counter | `kinhin.healing.result` (`succeeded`, `failed`) |
| `kinhin.healing.awaiting_approval` | gauge | none |
| `kinhin.build.info` | gauge | `service.version` (value 1) |
| `kinhin.daemon.uptime` | gauge | none (seconds since the engine started) |
| `kinhin.reconcile.duration` | histogram | none (one control-loop pass) |
| `kinhin.reconcile.last_success` | gauge | none (Unix time of the last completed pass; alert on `time()` minus it) |
| `kinhin.reconcile.errors` | counter | none |
| `kinhin.spawn.failures` | counter | `kinhin.pool` |
| `kinhin.spawn.held` | gauge | `kinhin.pool`, `kinhin.spawn.hold_reason` (`backoff`, `disk_pressure`); absent when nothing is held |
| `kinhin.telemetry.export.failures` | counter | none |
| `cicd.system.errors` | counter | `error.type`, `cicd.system.component` (`lifecycle`, `forge`) |

`error.type` is one of `clone_failed`, `boot_timeout`, `ssh_unreachable`, `registration_failed`, `runner_not_registered`, `instance_lost`,
`forge_api`, `rate_limited`, `teardown_failed`, `unknown`. Never the error text.

**The job result is the forge's, or `unknown`.** When a job ends kinhin asks the forge, once, what happened. GitHub, GitLab and
Buildkite answer with the job's verdict and its own start and end times (GitHub also with its steps): `cicd.pipeline.result` is then
`success`, `failure`, `cancellation`, `timeout` or `skip`, the run duration uses the forge's times, and on GitHub the trace gets one span per
step. The other forges, a job the forge has not yet marked finished after a few short retries, and a job kinhin never saw running read
`unknown`. kinhin never guesses a verdict. The read happens while the instance is torn down, so it adds no delay. To learn which job a runner
took, kinhin asks the forge for the running jobs as soon as the runner turns busy; a job that finishes in about a second can still outrun
that and read `unknown`. `kinhin.errors` counts kinhin's own failures, not failing workflows.

**Unavailable is not zero.** When a runtime or forge cannot supply a value, that series is absent. Today that means: per-runner disk use (no
runtime exposes it), `kinhin.queue.age` and the queue-wait histogram on forges that do not report queue timestamps (GitHub does, through
the job's `created_at`), and CPU on the first sample after a start. SSH-ready is not timed apart from boot because the runtimes do not
separate them: `boot` covers both.

### Cardinality and privacy

VM names, job and run IDs and trace and span IDs are **never** metric attributes: they appear only on spans and log records. Metric attributes
come from small closed sets (pool, image, forge, account, phase, result, error type, component) and the sorted runner labels from your config.
Per-repository and per-workflow dimensions are off by default: in an org-scoped fleet they are unbounded, and each combination is a series
in Prometheus or Mimir. `job_attributes: [repository, workflow]` adds them (as `vcs.repository.name` and `cicd.pipeline.name`) to
`kinhin.jobs.completed`, `cicd.pipeline.run.duration` and the queue-wait histogram only, and only where the forge supplied the value. Turn them
on for a fleet with a known, small set of repositories; otherwise use traces, which carry them for free. Runner CPU and memory are aggregated per pool and image, never one series per VM.

Logs pass through the same redaction as the local log before export; tokens and registration secrets cannot reach a collector or the JSON log.
Spans and logs do carry repository, workflow and job names and VM names, so only point `endpoint` at a collector you trust with them.

## Traces

One trace per instance, from spawn to teardown. The root span `kinhin.job` carries `kinhin.vm.id`, `kinhin.runner.name`, `kinhin.pool`, `kinhin.image`,
`kinhin.forge`, `kinhin.runner.labels`, the forge's `cicd.pipeline.result` and the final `kinhin.result`. Children, each only where there is a real measurement:

- `provision`, `boot_ready`, `registration`, `run`, `teardown`: timed by kinhin with the monotonic clock.
- `queue_wait`: from the forge's queue timestamp to its start timestamp, only when the forge supplied both.
- `step`: one per step the forge reports for the finished job, with the forge's own start and finish times (GitHub).

On GitHub Actions the root span also gets `cicd.pipeline.run.id`, `kinhin.run.attempt`, `kinhin.job.id`, `cicd.pipeline.name`,
`cicd.pipeline.task.name` and `vcs.repository.name` once the running job is seen. A job that starts and finishes between two polls is still
counted (the forge's completion signal is used), but it has no `run` span and no run duration, because nothing observed its start.

With `runners_per_vm` above 1 an instance runs several jobs: the root keeps the first job's identifiers, and each further job is a child
`job` span with its own, so nothing is overwritten. `kinhin.jobs.picked_up` still counts the instance once.

## Logs

With `logs` selected, every log line also becomes an OTLP log record with its severity, `kinhin.component`, the VM (`kinhin.vm.id`) and job
(`kinhin.job.name`, `kinhin.job.id`) when known, and the trace and span of the lifecycle it came from. `log_format: json` writes the same context locally:

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

## Checking it works

`kinhin telemetry status` (add `--json` for scripts) asks the daemon what the pipeline is doing: which signals, where each goes
(credentials and query strings removed), the bound Prometheus address, and the last export problem. The SDK never throws export
errors, so kinhin reports them itself: each distinct problem is logged at most once a minute as `export problem: …`, counted in
`kinhin.telemetry.export.failures`, and shown by `status`. It exits 1 when exports failed in the last five minutes, or when the config
enables telemetry and no daemon runs.

## Grafana Alloy, dashboards and alerts

A collector on the same Mac, forwarding to Grafana Cloud (Mimir for metrics, Loki for logs, Tempo for traces):

```alloy
otelcol.receiver.otlp "kinhin" {
  http { endpoint = "127.0.0.1:4318" }
  grpc { endpoint = "127.0.0.1:4317" }
  output {
    metrics = [otelcol.processor.batch.default.input]
    logs    = [otelcol.processor.batch.default.input]
    traces  = [otelcol.processor.batch.default.input]
  }
}

otelcol.processor.batch "default" {
  output {
    metrics = [otelcol.exporter.otlphttp.cloud.input]
    logs    = [otelcol.exporter.otlphttp.cloud.input]
    traces  = [otelcol.exporter.otlphttp.cloud.input]
  }
}

otelcol.auth.basic "cloud" {
  client_auth {
    username = sys.env("GRAFANA_CLOUD_INSTANCE_ID")
    password = sys.env("GRAFANA_CLOUD_TOKEN")
  }
}

otelcol.exporter.otlphttp "cloud" {
  client {
    endpoint = sys.env("GRAFANA_CLOUD_OTLP_ENDPOINT")
    auth     = otelcol.auth.basic.cloud.handler
  }
}
```

and in `config.yaml`:

```yaml
telemetry:
  enabled: true
  endpoint: http://127.0.0.1:4318
  resource_attributes: {deployment.environment: home}
```

To scrape metrics instead of pushing them, set `prometheus_listen: 127.0.0.1:9469` and add
`prometheus.scrape "kinhin" { targets = [{__address__ = "127.0.0.1:9469"}]  forward_to = [prometheus.remote_write.cloud.receiver]  job_name = "kinhin" }`.

Ready-made files live in the repository: [`docs/telemetry/kinhin-dashboard.json`](https://github.com/RabinApps/kinhin/blob/main/docs/telemetry/kinhin-dashboard.json)
(import it in Grafana and pick your Prometheus data source) and [`docs/telemetry/kinhin-alerts.yml`](https://github.com/RabinApps/kinhin/blob/main/docs/telemetry/kinhin-alerts.yml)
(queue stuck, fleet below desired, errors, forge rate limit, host disk, export failing, paused). Both use the names OTLP ingestion produces,
where counters end in `_total`; kinhin's own `/metrics` endpoint exposes counters without it. A test keeps every metric name in these files
in step with the catalog above.

## Who exports

The process that hosts the engine owns the exporters: the daemon, foreground `kinhin start`, or the menu bar app when it runs its own engine
because no daemon is up. An app attached to a daemon exports nothing; the daemon already does. The daemon and `kinhin start` flush on SIGTERM
and Ctrl-C; the app exports on its interval and does not flush on quit, so its last interval can be lost.

## Limitations

- **Step-level trace propagation is not implemented.** kinhin does not pass `TRACEPARENT` or a collector address into workflow steps. It
  needs a per-job runner hook, proof that context cannot leak between reused runners, and an explicitly reachable collector. Daemon-side traces
  are complete without it.
- Job metrics (`picked_up`, `completed`, the run duration and the `run` span) need ephemeral or scale-set runners, the ones kinhin watches
  until their job ends. A classic persistent runner (`vm.ephemeral: false`) has lifecycle timings but no job counters.
- Job identifiers, queue times and a verdict come from GitHub Actions, GitLab and Buildkite. Other forges get the lifecycle spans and
  timings kinhin measures itself, and a result of `unknown`. Step spans exist for GitHub only (the others have no step list).
- Metrics and logs in the upstream SDK are still in development; pin and test before relying on them.
- Prometheus histogram buckets come out of the upstream text writer as per-bucket counts rather than cumulative `le` counts; use the OTLP
  path where `histogram_quantile` accuracy matters.
