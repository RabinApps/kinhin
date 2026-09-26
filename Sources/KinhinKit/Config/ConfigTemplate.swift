import Foundation

extension ConfigLoader {
    /// The commented default template written by `kinhin config init`.
    public static func template() -> String {
        """
        # kinhin configuration
        # Location: ~/Library/Application Support/Kinhin/config.yaml
        # (Upgrading from the pre-rename Orchard build? Your config, logs,
        # and Keychain tokens migrate automatically on first launch.)

        # GitHub scope to serve (required). Jobs whose `runs-on:` matches
        # (subset of) `labels` below will be run here.
        #   "RabinApps/name"  → a single repository
        #   "your-org"    → an entire organization (org-level runners serve
        #                   every repo's queued jobs; the PAT needs org
        #                   runner-management permissions)
        repo: "your-org/your-repo"

        # Labels jobs must request to be picked up by this fleet.
        labels: ["self-hosted", "macos", "arm64"]

        # Concurrency bounds. kinhin scales between these based on queued work.
        min_runners: 0
        max_runners: 2

        # Runner processes per VM (many-to-one): each VM serves this many jobs
        # at once. 1 = one job per VM (default, most isolated). 2-3 works for
        # Xcode jobs on an 8 GB VM; higher densities suit lightweight jobs.
        runners_per_vm: 1

        # How often to ask GitHub about queued jobs (seconds, >= 5).
        poll_interval: 20

        # Per-VM resources. Keep total within your Mac's capacity — see
        # `kinhin doctor` for the computed budget.
        vm:
          cpu: 4          # vCPUs per runner VM
          memory_gb: 8    # RAM per runner VM
          ephemeral: true # fresh VM per job (recommended)

        # Tart image to clone. Prepare it first with: kinhin image prepare
        image: "tahoe-base"

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

        # Optional: managed toolchains — kinhin installs and pins the
        # runtimes below into the base image (no script to write), with
        # version prints logged as the audit trail. Every entry installs
        # exactly its own pieces; a stack that needs a runtime (vercel needs
        # node) is a validation error until you list that runtime too.
        # Unknown specs pass through to mise, unknown brew entries to brew —
        # see `kinhin toolchains` for the curated catalog.
        # toolchains:
        #   specs: ["go@1.23.4", "node@22", "bun@1.1.27", "deno@2", "java@temurin-17", "dotnet", "uv"]
        #   brew: ["wget", "cmake", "yamllint"]
        #   stacks: ["flutter@3.24.0", "expo", "react-native", "vercel", "cloudflare"]
        #   share_cache: false   # mount the host download cache into runner VMs (opt-in)
        #   cache:               # host-side cache auto-expiry (baked images are never touched)
        #     auto_prune: true   # sweep after each prepare + daily while the fleet runs
        #     max_age_days: 30   # entries unused this long are deleted (0 = never)
        #     max_gb: 50         # LRU eviction beyond this size (0 = unlimited)

        # Optional: also serve Gitea Actions from the same fleet. VMs are
        # assigned to whichever forge (GitHub or Gitea) has the most pending
        # work at spawn time. Requires a Gitea access token (kinhin auth set
        # --gitea) with runner-management rights on the scope below.
        # gitea:
        #   instance: "https://gitea.example.com"
        #   scope: "RabinApps/name"        # or an org name
        #   labels: ["macos:host"]     # jobs opt in via runs-on: macos:host

        # Optional: serve more accounts. `repo:` and `gitea:` above are the
        # built-in accounts "github" and "gitea"; each entry here is another
        # GitHub org/repo or Gitea instance with its own token. Manage them
        # with `kinhin auth add|list|remove` and `kinhin auth set --account NAME`.
        # accounts:
        #   - name: work
        #     forge: github
        #     scope: "bigco"             # org, or owner/name
        #   - name: home-gitea
        #     forge: gitea
        #     scope: "me/repo"
        #     instance: "https://git.home.lan"

        # Optional: route repos and workflows to different execution runtimes.
        # macOS jobs need Tart VMs; Linux jobs can run in Apple-container
        # microVMs (cheaper per job). Each runtime's runners carry distinct
        # labels, so a workflow overrides its repo's route per job via
        # `runs-on:` (e.g. runs-on: [kinhin-container]).
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
        # full Tart VMs (github.com/apple/container — lightweight, one VM per
        # container, Apple silicon only). Much cheaper per job for Linux
        # workloads; macOS jobs still need Tart. Requires the container CLI
        # (brew install container) and a Linux image baked with the
        # runner agents — prepare it with: kinhin image prepare --container-image <name>
        # container:
        #   image: "kinhin-ci-linux"
        #   base_image: "ubuntu:24.04"   # optional: what the image is built on (Debian/Ubuntu-based)
        #   cpus: 4
        #   memory_gb: 8

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
        """
    }
}
