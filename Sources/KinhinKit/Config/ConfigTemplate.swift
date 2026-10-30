import Foundation

extension ConfigLoader {
    /// The commented default template written by `kinhin config init`.
    public static func template() -> String {
        """
        # kinhin configuration
        # Location: ~/Library/Application Support/Kinhin/config.yaml

        # Config schema version (optional, absent = 1). Unknown keys are an
        # error at version 1 so a typo like `max_runner:` cannot pass silently.
        version: 1

        # The forges this fleet serves. Every entry is one account: a scope
        # on a forge with its own token (kinhin auth set --account NAME).
        #   "owner/name"  → a single repository
        #   "your-org"    → an entire organization (org-level runners serve
        #                   every repo's queued jobs; the PAT needs org
        #                   runner-management permissions)
        # The names "github" / "gitea" / "forgejo" are the primary accounts
        # (their tokens keep the original Keychain items); others are yours
        # to name. Uncomment the entry you need:
        # accounts:
        #   - name: github
        #     forge: github
        #     scope: "your-org/your-repo"   # or just "your-org"
        #   - name: gitea
        #     forge: gitea
        #     scope: "owner/name"           # or an org name
        #     instance: "https://gitea.example.com"
        #   - name: work                    # additional accounts: any name
        #     forge: gitlab
        #     scope: "group/project"

        # Labels jobs must request to be picked up by this fleet.
        labels: ["self-hosted", "macos", "arm64"]

        # Concurrency bounds. kinhin scales between these based on queued work.
        min_runners: 0
        max_runners: 2

        # Pre-warmed VMs: booted and SSH-ready but not yet registered, so a job
        # skips clone and boot. They take slots under max_runners and are
        # evicted when a job needs the slot. This covers the base image; each
        # images: entry has its own warm_pool. 0 = off.
        warm_pool: 0
        # Recycle a warm VM after this many minutes (>= 5).
        warm_max_age_minutes: 60

        # Runner processes per VM (many-to-one): each VM serves this many jobs
        # at once. 1 = one job per VM (default, most isolated). 2-3 works for
        # Xcode jobs on an 8 GB VM; higher densities suit lightweight jobs.
        runners_per_vm: 1

        # How often to ask GitHub about queued jobs (seconds, >= 5).
        poll_interval: 20

        # Unpause automatically once the queue is empty, so a deliberate
        # pause (e.g. a pause-first VM delete from Shortcuts) releases the
        # fleet on its own when there is nothing left to hold down.
        auto_resume: false

        # Per-VM resources. Keep total within your Mac's capacity — see
        # `kinhin doctor` for the computed budget.
        vm:
          cpu: 4          # vCPUs per runner VM
          memory_gb: 8    # RAM per runner VM
          ephemeral: true # fresh VM per job (recommended)

        # Tart image to clone. Prepare it first with: kinhin image prepare
        image: "tahoe-base"

        # Optional: what `image prepare` starts from — a pre-configured tart
        # image (ghcr.io/cirruslabs/macos-sequoia-base:latest and friends;
        # pick one in the app) instead of the default macOS base. A local VM
        # name (e.g. one made with `image prepare --linux`) also works.
        # A Linux image here turns the whole tart fleet into Tart Linux VMs —
        # when you use named images with distinct labels, Linux-named images
        # strip the fleet's `macos` label automatically (you do not need to
        # remove it from `labels:`); `image_labels:` (below) labels the
        # default image itself.
        # base_image: "ghcr.io/cirruslabs/macos-sequoia-base:latest"

        # Optional: runner labels for the top-level `image:` itself — the
        # named-image `labels:` rule applied to the default image, e.g. for a
        # Linux default base that should answer a `linux` label.
        # image_labels: [linux]

        # Extra named images beside image:, each baked on its own base (for
        # example one with full Xcode). Build one with
        # `kinhin image prepare --image <name>` (or --all), or in the app under
        # "More images". Names must not start with kinhin- or orchard-. A job
        # picks an image by requesting its labels in `runs-on` (GitHub, Buildkite).
        # images:
        #   - name: xcode
        #     base_image: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest"
        #     labels: [xcode]

        # Seconds a freshly booted VM has to register as a runner.
        vm_boot_timeout: 300

        # Host headroom kept free so your Mac stays responsive. The scaler
        # holds new VMs when free disk would dip below reserve.disk_gb plus
        # one VM's disk footprint (50 GB unless disk_gb is set).
        reserve:
          cpu: 2
          memory_gb: 4
          disk_gb: 10

        # Optional overrides:
        # disk_gb: 0           # extra scratch disk per VM (0 = none)
        # tart_path: /opt/homebrew/bin/tart
        # tart_softnet: true   # isolate runner VMs from each other and the LAN (needs softnet; see docs/runtimes.md)
        # Running PRs from outside contributors? Also keep projects[].share_cache off (docs/toolchains.md).
        # token_ttl: 3000      # seconds to cache the runner registration token

        # Optional: bake your own toolchains into the base image. The script
        # runs (verbatim, as the admin user) inside the VM during
        # `kinhin image prepare`, after the runner agents are installed;
        # every runner VM then boots with whatever it installs. The script is
        # the version pin — edit it and re-run prepare to change toolchains.
        # The base image ships Homebrew and mise, so either works:
        #   brew install wget go@1.23 temurin@21
        #   mise install go@1.23.4 rust@1.82 java@temurin-21
        # End the script with `go version && java -version` prints — their
        # output is logged, recording what went into the image.
        # provision_script: "~/kinhin/provision.sh"

        # Optional: per-project toolchains. Each repo gets the toolchains it
        # declares, baked into its own image (`kinhin image prepare --project
        # owner/name`); there is no global toolchain list. Either let the repo
        # declare them in a .kinhin.yml (repo_file: true), or declare them here.
        # Every entry installs exactly its own pieces; a stack that needs a
        # runtime (vercel needs node) is a validation error until you list it.
        # See `kinhin toolchains` for the curated catalog. Repos without
        # toolchains run on the plain base image and can install per job with
        # `run: kinhin-toolchain install node@22`. See docs/toolchains.md.
        # projects:
        #   - pattern: "owner/*"     # owner/name or owner/*
        #     repo_file: true        # honor the repo's .kinhin.yml (default false)
        #   - pattern: "owner/api"
        #     toolchains:
        #       specs: ["go@1.23.4", "node@22"]
        #       stacks: ["flutter@3.24.0"]
        #     share_cache: false     # mount the host download cache (opt-in)
        # max_project_images: 8      # cap on derived per-project images (LRU)
        # toolchain_cache:           # host-side cache auto-expiry (baked images are never touched)
        #   auto_prune: true         # sweep after each bake + daily while the fleet runs
        #   max_age_days: 30         # entries unused this long are deleted (0 = never)
        #   max_gb: 50               # LRU eviction beyond this size (0 = unlimited)

        # Optional: the healing agent fixes known problems on its own (a vanished
        # warm VM, a full cache, a detached account) and asks before anything
        # destructive. See `kinhin heal` and docs/healing.md.
        # healing:
        #   enabled: true            # false = only the engine's own retries
        #   auto: safe               # safe = reversible fixes run on their own; none = ask for every fix
        #   ai: auto                 # auto = on-device Apple Intelligence advises (macOS 26+); off = rules only
        #                            # ollama = a local Ollama decision model, then your LLM (see docs/healing.md)
        #   max_attempts: 3          # tries of one fix for one problem before it escalates
        #   ollama:                  # only with ai: ollama
        #     host: http://127.0.0.1:11434   # https required for any host other than this Mac
        #     model: my-llm          # the LLM, asked when the fast model is unsure or picks nothing
        #     fast_model: clef-flash # optional System 1 decision model, asked first
        #     keep_alive: 30m        # how long Ollama keeps the models loaded (0 = unload at once)

        # Optional: observability. Metrics, traces and logs over OTLP, plus an
        # optional local Prometheus /metrics endpoint. Off by default: nothing
        # is exported and no port opens until enabled. Standard OTEL_* variables
        # override these keys. Credentials never go in this file: use
        # OTEL_EXPORTER_OTLP_HEADERS or a Keychain item (headers_keychain).
        # See docs/telemetry.md.
        # telemetry:
        #   enabled: false
        #   endpoint: http://localhost:4318   # collector base URL (grpc default port is 4317)
        #   protocol: http/protobuf           # or grpc
        #   export_interval_seconds: 60       # seconds between metric pushes
        #   signals: [metrics, traces, logs]  # any subset
        #   resource_attributes:              # extra attributes; service.* is kinhin's own
        #     deployment.environment: home-lab
        #   prometheus_listen: 127.0.0.1:9464 # local scrape endpoint (a bare port binds loopback)
        #   log_format: text                  # json = one structured JSON object per log line
        #   job_attributes: []                # [repository, workflow] adds those to the job counters and histograms (cardinality!)
        #   sampling_ratio: 1                 # 0-1: share of job traces recorded (1 = all)
        #   log_level: info                   # debug|info|warn|error: lowest severity sent over OTLP (the local log is separate)
        #   headers_keychain: grafana-cloud   # Keychain item holding a collector token, sent as "Authorization: Bearer"
        #   ca_file: /etc/ssl/collector-ca.pem # PEM CA that signs the collector's https certificate
        #   persist: false                    # true = queue spans and logs on disk while the collector is down

        # Optional: serve more forges from the same fleet. Every accounts:
        # entry above is one forge; VMs are assigned to whichever forge has
        # the most pending work at spawn time. Manage accounts with
        # `kinhin auth add|list|remove` and `kinhin auth set --account NAME`.
        # Gitea-family labels let jobs opt in via runs-on: (e.g. macos:host).

        # Optional: route repos and workflows to different execution runtimes.
        # macOS jobs need Tart VMs; Linux jobs can run in Apple-container
        # microVMs, Docker containers, or full Tart Linux VMs. A tart fleet can
        # serve macOS and Linux VMs together when named images have distinct
        # labels (see docs/runtimes.md for the comparison). Each runtime's
        # runners carry distinct labels, so a workflow overrides its repo's
        # route per job via `runs-on:` (e.g. runs-on: [kinhin-container]).
        # Linux-guest runtimes (container, docker) never carry the fleet's
        # `macos` label — macOS jobs only land where it runs.
        # runtimes:
        #   default: tart                # runtime for repos with no route
        #   budget: {tart: 0.6, appleContainer: 0.4}   # host-budget split
        #   routes:
        #     - pattern: "acme/ios-app"
        #       runtime: tart
        #     - pattern: "acme/api"
        #       runtime: appleContainer
        #     - pattern: "acme/web@Linux-only checks"   # per-workflow route
        #       runtime: appleContainer

        # Optional: run Linux jobs in Apple `container` microVMs instead of
        # full VMs (github.com/apple/container — lightweight, one VM per
        # container, Apple silicon only). Cheaper per job for Linux workloads
        # than a full VM; macOS jobs still need Tart. Requires the container CLI
        # (kinhin setup repair container) and a Linux image baked with the
        # runner agents — prepare it with: kinhin image prepare --container-image <name>
        # container:
        #   image: "kinhin-ci-linux"
        #   base_image: "ubuntu:24.04"   # optional: what the image is built on (Debian/Ubuntu-based)
        #   cpus: 4
        #   memory_gb: 8
        #   labels: [docker, small]      # extra pool labels (optional)
        #   fleet_labels: false          # replace-not-add: drop the fleet labels entirely

        # Optional: run Linux jobs in Docker containers inside your Docker
        # provider's shared Linux VM (Docker Desktop, OrbStack, or colima).
        # kinhin delegates the VM to the provider — it only runs one runner
        # container per job slot. Requires Docker running and a Linux image
        # baked with the runner agents: kinhin image prepare --docker
        # docker:
        #   image: "kinhin-ci-linux"
        #   base_image: "ubuntu:24.04"   # optional: what the image is built on (Debian/Ubuntu-based)
        #   cpus: 2
        #   memory_gb: 4
        #   max_slots: 8   # hard cap on concurrent runner containers
        #   platform: "linux/arm64"   # native; "linux/amd64" runs x86_64 under emulation (slower, some gaps)
        #   fleet_labels: false   # pool labels = kinhin-docker (+x64) without the fleet labels
        """
    }
}
