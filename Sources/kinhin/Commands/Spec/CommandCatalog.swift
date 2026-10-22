import Foundation
import KinhinKit

// The CLI's command table. Every command, subcommand, alias and flag the
// binary accepts is declared here; anything not declared is a usage error.
// Keep one `name:` / `aliases:` per line: scripts/skills-lint.sh reads the
// command vocabulary out of this file with grep.

enum CommandCatalog {
    // MARK: - Shared flags

    static let jsonFlag = FlagSpec.bool("--json", "Machine-readable output on stdout")
    static let quietFlag = FlagSpec.bool("--quiet", aliases: ["-q"], "Print nothing; the exit code is the answer")
    static let yesFlag = FlagSpec.bool("--yes", "Carry it out (without it, only report what would happen)")

    /// `--github`, `--gitlab`, …: which forge's token a command targets.
    static func forgeFlags(_ summary: String = "Which forge's token (default: GitHub)") -> [FlagSpec] {
        ForgeID.allCases.map { FlagSpec.bool("--\($0.rawValue)", summary, group: "forge") }
    }

    static let accountFlag = FlagSpec.value("--account", "NAME", "Target a named account from the config")
    static let tokenStdinFlag = FlagSpec.bool(
        "--token-stdin", "Read the token from stdin (for scripts and password managers)")
    /// Still accepted for old scripts; the token lands in shell history, so it is not advertised.
    static let tokenFlag = FlagSpec.value("--token", "TOKEN", "Pass the token as an argument", hidden: true)

    // MARK: - The table

    static let all: [CommandSpec] = [
        // MARK: setup
        CommandSpec(
            name: "config",
            command: .configInit,
            group: .setup,
            summary: "Create and validate the config file",
            flags: [.bool("--force", "Overwrite an existing config", hidden: true)],
            subcommands: [
                CommandSpec(
                    name: "init",
                    command: .configInit,
                    summary: "Write a starter config file",
                    flags: [.bool("--force", "Overwrite an existing config")]),
                CommandSpec(
                    name: "validate",
                    command: .configInit,
                    summary: "Check the config without starting anything",
                    flags: [jsonFlag],
                    details: ["Exits 3 when the config is invalid."]),
                CommandSpec(
                    name: "migrate",
                    command: .configInit,
                    summary: "Translate removed config keys to the current schema",
                    flags: [.bool("--write", "Replace the config (the original is kept as config.yml.bak)")],
                    details: ["Handles repo:, gitea:, forgejo: and toolchains:. Output to stdout; notes to stderr."]),
                CommandSpec(
                    name: "export",
                    command: .configInit,
                    summary: "Write the config for another Mac (no tokens)",
                    positionals: "[FILE]",
                    flags: [.bool("--force", "Overwrite FILE if it exists")],
                    details: [
                        "To stdout without FILE (or with -). Tokens stay in this Mac's Keychain.",
                        "One step over SSH: kinhin config export | ssh other-mac kinhin config import - --yes",
                    ]),
                CommandSpec(
                    name: "import",
                    command: .configInit,
                    summary: "Use a config exported on another Mac",
                    positionals: "FILE",
                    flags: [yesFlag],
                    details: [
                        "Validates FILE (- reads stdin). With no config yet it is written; an existing one is only "
                            + "replaced with --yes and kept as config.yaml.bak. Lists the tokens to store here."
                    ]),
            ],
            defaultSubcommand: "init",
            docs: "website/guide/config.md"),
        CommandSpec(
            name: "auth",
            command: .auth,
            group: .setup,
            summary: "Store, check and remove forge tokens and accounts",
            subcommands: [
                CommandSpec(
                    name: "set",
                    command: .auth,
                    summary: "Store (or replace) a token in the Keychain",
                    flags: forgeFlags() + [accountFlag, tokenStdinFlag, tokenFlag],
                    details: [
                        "With no forge flag this is the GitHub PAT. Without --token-stdin the token is read from a "
                            + "hidden prompt, after a list of the permissions it needs."
                    ]),
                CommandSpec(
                    name: "add",
                    command: .auth,
                    summary: "Add an account to the config",
                    positionals: "NAME",
                    flags: forgeFlags("Which forge the account is for (exactly one)") + [
                        .value("--scope", "S", "Org or owner/name (required); the forge decides the form"),
                        .value("--instance", "URL", "Server URL for self-hosted forges"),
                        tokenStdinFlag, tokenFlag,
                    ],
                    details: [
                        "Pick exactly one forge flag. Store the token afterwards with `kinhin auth set --account NAME`."
                    ],
                    usage: ["auth add NAME --FORGE --scope S [--instance URL] [--token-stdin]"]),
                CommandSpec(
                    name: "list",
                    command: .auth,
                    summary: "List accounts and whether their tokens are stored"),
                CommandSpec(
                    name: "remove",
                    command: .auth,
                    summary: "Remove an account and delete its token",
                    positionals: "NAME"),
                CommandSpec(
                    name: "status",
                    command: .auth,
                    summary: "Check that stored tokens exist and work",
                    flags: forgeFlags() + [accountFlag, jsonFlag, quietFlag],
                    details: [
                        "With --json: the static report for every forge (no network probe). "
                            + "Exits 0 when every account has a token, 1 until then."
                    ]),
                CommandSpec(
                    name: "clear",
                    command: .auth,
                    summary: "Remove a stored token",
                    flags: forgeFlags() + [accountFlag]),
            ],
            defaultSubcommand: "set",
            docs: "docs/forges.md"),
        CommandSpec(
            name: "doctor",
            command: .doctor,
            group: .setup,
            summary: "Check prerequisites and the computed capacity",
            flags: [
                .bool("--json", "One merged machine-readable diagnostics document"),
                .optionalValue("--bundle", "FILE", "Write a redacted support bundle to attach to a bug report"),
                .bool("--check-tokens", "Verify every account's token against its forge (network)"),
                quietFlag,
            ],
            details: [
                "Offline by default: tokens are only checked as stored. --check-tokens probes each one.",
                "Exits 0 when everything is ready, 1 when something needs attention.",
            ]),
        CommandSpec(
            name: "setup",
            command: .setupRepair,
            group: .setup,
            summary: "First-run checklist and prerequisite installers",
            subcommands: [
                CommandSpec(
                    name: "status",
                    command: .setupStatus,
                    summary: "Show the first-run checklist",
                    flags: [jsonFlag, quietFlag],
                    details: ["Exits 0 when ready, 1 while something needs attention."]),
                CommandSpec(
                    name: "repair",
                    command: .setupRepair,
                    summary: "Install a missing prerequisite",
                    subcommands: [
                        CommandSpec(
                            name: "host-agent",
                            command: .setupRepair,
                            summary: "Install the runner agents for host runs",
                            details: [
                                "Host runs are unisolated, on this Mac. The GitLab, Buildkite, Azure Pipelines and "
                                    + "Bitbucket agents are added only when such an account is configured."
                            ]),
                        CommandSpec(
                            name: "docker",
                            command: .setupRepair,
                            summary: "Install Docker",
                            flags: [
                                .value(
                                    "--method", "desktop|orbstack|colima",
                                    "How to install (default: the first this Mac supports)")
                            ]),
                        CommandSpec(
                            name: "container",
                            command: .setupRepair,
                            summary: "Install Apple container and its service",
                            details: ["Needs Apple silicon and macOS 26 or later."]),
                        CommandSpec(
                            name: "tart",
                            command: .setupRepair,
                            summary: "Install tart for macOS VMs"),
                    ],
                    requiresSubcommand: true),
            ],
            requiresSubcommand: true),
        CommandSpec(
            name: "setup-status",
            command: .setupStatus,
            summary: "First-run checklist (same as `setup status`)",
            flags: [jsonFlag, quietFlag],
            hidden: true),
        CommandSpec(
            name: "runtimes",
            command: .runtimes,
            group: .setup,
            summary: "Pools, capacity, budget, health and routes",
            flags: [jsonFlag, .bool("--no-health", "Skip the runtime health probes")],
            subcommands: [
                CommandSpec(
                    name: "route",
                    command: .runtimes,
                    summary: "Edit the repo and workflow routes",
                    subcommands: [
                        CommandSpec(
                            name: "add",
                            command: .runtimes,
                            summary: "Route a repo or workflow to a runtime",
                            positionals: "<pattern> <runtime>",
                            flags: [.bool("--consent", "Required for host (jobs run unisolated on this Mac)")],
                            details: [
                                "<pattern> is a repo (owner/repo) or a workflow (owner/repo@Name); "
                                    + "<runtime> is tart, appleContainer, docker or host."
                            ]),
                        CommandSpec(
                            name: "remove",
                            command: .runtimes,
                            summary: "Delete a route",
                            positionals: "<pattern>"),
                    ],
                    details: ["A running daemon reloads route changes live."],
                    requiresSubcommand: true)
            ],
            docs: "docs/runtimes.md"),

        // MARK: images and toolchains
        CommandSpec(
            name: "image",
            command: .imagePrepare,
            group: .images,
            summary: "Build and manage runner images",
            subcommands: [
                CommandSpec(
                    name: "prepare",
                    command: .imagePrepare,
                    summary: "Build the runner base image (slow, once)",
                    flags: [
                        .value("--provision-script", "FILE", "Run this script in the VM after the agents install"),
                        .value("--image", "NAME", "Build one named image from the config's images: list"),
                        .bool("--all", "Build image: and every images: entry, one after another"),
                        .value("--project", "OWNER/NAME", "Bake that repo's toolchains into a derived image now"),
                        .value("--ref", "REF", "Branch or tag whose .kinhin.yml --project reads"),
                        .bool("--container", "Build the Linux image for apple container"),
                        .bool("--docker", "Build the Linux image for Docker"),
                        .value("--platform", "P", "Docker platform, e.g. linux/amd64 (runs under emulation)"),
                        .value("--container-image", "REF", "Base OCI image for --container"),
                        .value("--docker-image", "REF", "Base OCI image for --docker"),
                        .bool("--linux", "Create a Linux tart VM from scratch (needs --target)"),
                        .value("--target", "NAME", "Name of the image or VM to write"),
                        .value("--iso", "FILE", "arm64 install ISO to attach with --linux"),
                        .optionalValue("--from", "REF", "Start --linux from a pre-configured image (bare: menu)"),
                        .value("--runner-version", "V", "Pin the runner agent version"),
                        .value("--source", "NAME", "VM to bake the agents into", hidden: true),
                    ],
                    details: [
                        "Bakes the runner agents plus your provision script into the base image once, using the "
                            + "shared host download cache. Toolchains are per project (see --project).",
                        "--container and --docker bake agents only; jobs install toolchains with "
                            + "`kinhin-toolchain install`.",
                    ],
                    docs: "docs/toolchains.md"),
                CommandSpec(
                    name: "list",
                    aliases: ["ls"],
                    command: .imageList,
                    summary: "Show installed images, their size and who uses them",
                    flags: [
                        jsonFlag,
                        .value(
                            "--runtime", "tart|container|docker", "Only that runtime (repeatable)"),
                    ]),
                CommandSpec(
                    name: "delete",
                    aliases: ["rm"],
                    command: .imageDelete,
                    summary: "Delete installed images by name",
                    positionals: "<name>…",
                    flags: [yesFlag],
                    details: ["Refuses images runners are using; stop the fleet first."]),
                CommandSpec(
                    name: "prune",
                    command: .imagePrune,
                    summary: "Sweep stale records and delete unused local images",
                    flags: [yesFlag],
                    details: ["Configured images, the base_image and anything in use are never touched."]),
                CommandSpec(
                    name: "digest",
                    command: .imageDigest,
                    summary: "Print the digest a registry serves, to pin base_image",
                    positionals: "<registry>/<repo>:<tag>",
                    flags: [.value("--ref", "REF", "The image reference", hidden: true)]),
            ],
            defaultSubcommand: "prepare",
            docs: "docs/toolchains.md"),
        CommandSpec(
            name: "toolchains",
            command: .toolchains,
            group: .images,
            summary: "Toolchain catalog, project selections and cache state",
            flags: [
                jsonFlag,
                .value("--project", "OWNER/NAME", "Show what that repo's toolchains resolve to"),
                .value("--ref", "REF", "Branch or tag whose .kinhin.yml --project reads"),
            ],
            subcommands: [
                CommandSpec(
                    name: "detect",
                    command: .toolchains,
                    summary: "Scan a checkout for the toolchains it needs",
                    positionals: "[path]",
                    flags: [
                        jsonFlag,
                        .bool("--write", "Save the result as .kinhin/config.yml"),
                        .bool("--force", "Overwrite an existing .kinhin/config.yml (or .kinhin.yml)"),
                    ]),
                CommandSpec(
                    name: "list-images",
                    command: .toolchains,
                    summary: "Derived per-project images: size and last used"),
                CommandSpec(
                    name: "prune",
                    command: .toolchains,
                    summary: "Expire stale cache entries and unused derived images",
                    flags: [.bool("--dry-run", "Report without deleting")]),
                CommandSpec(
                    name: "helper",
                    command: .toolchains,
                    summary: "Print the per-job kinhin-toolchain helper script",
                    flags: [.bool("--linux", "The Linux variant")]),
            ],
            docs: "docs/toolchains.md"),

        CommandSpec(
            name: "mobile",
            command: .mobile,
            group: .images,
            summary: "Set up fastlane store releases for a mobile app",
            subcommands: [
                CommandSpec(
                    name: "init",
                    command: .mobile,
                    summary: "Add fastlane lanes and the CI release workflow",
                    positionals: "[DIR]",
                    flags: [
                        .value(
                            "--framework", "NAME",
                            "auto (default), ios, android, native, flutter, react-native, expo, capacitor, kmp or maui"
                        ),
                        .value(
                            "--ci", "SYSTEM",
                            "auto (default: the repository's), github, gitea, forgejo, gitlab, bitbucket, azure or buildkite"
                        ),
                        .bool("--force", "Overwrite files that already exist"),
                        .bool("--dry-run", "Print what would be written and write nothing"),
                    ],
                    docs: "docs/mobile-fastlane.md")
            ],
            docs: "docs/mobile-fastlane.md"),

        // MARK: running
        CommandSpec(
            name: "start",
            command: .start,
            group: .running,
            summary: "Start the fleet in this terminal (Ctrl-C to stop)"),
        CommandSpec(
            name: "daemon",
            command: .daemon,
            group: .running,
            summary: "Run the headless daemon in this terminal",
            subcommands: [
                CommandSpec(
                    name: "install",
                    command: .daemon,
                    summary: "Install and start a LaunchAgent daemon"),
                CommandSpec(
                    name: "uninstall",
                    command: .daemon,
                    summary: "Stop and remove the LaunchAgent"),
            ]),
        CommandSpec(
            name: "status",
            command: .status,
            group: .running,
            summary: "Show fleet status (attaches to the daemon)",
            flags: [jsonFlag, quietFlag],
            details: [
                "Exits 0 when a daemon is running, 1 when it is not. --json adds daemon, paused and autoResume fields."
            ]),
        CommandSpec(
            name: "pause",
            command: .pause,
            group: .running,
            summary: "Hold the fleet: no new runners start",
            flags: [jsonFlag, quietFlag],
            details: ["Exits 1 when no daemon is running."]),
        CommandSpec(
            name: "resume",
            command: .resume,
            group: .running,
            summary: "Let a paused fleet scale again",
            flags: [jsonFlag, quietFlag],
            details: ["Exits 1 when no daemon is running."]),
        CommandSpec(
            name: "stop",
            command: .stop,
            group: .running,
            summary: "Stop the fleet (works on a daemon)",
            flags: [jsonFlag, quietFlag],
            details: ["Exits 1 when no daemon is running (there was nothing to stop)."]),
        CommandSpec(
            name: "logs",
            command: .logs,
            group: .running,
            summary: "Show recent log lines",
            flags: [.value("-n", "N", "How many lines (default 50)")]),
        CommandSpec(
            name: "watch",
            command: .watch,
            group: .running,
            summary: "Live status view (refreshes every 2s)"),
        CommandSpec(
            name: "pipeline",
            aliases: ["pipelines"],
            command: .pipeline,
            group: .running,
            summary: "Live jobs and steps of the VMs that are busy",
            positionals: "[VM]",
            flags: [
                .value("--job", "NAME|ID", "Just that job"),
                .value("--step", "N|NAME", "Print one step's output"),
                .bool("--log", "Print the whole job's output"),
                .bool("--follow", aliases: ["-f"], "Keep streaming output until it finishes"),
                .bool("--watch", "Refresh the pipeline view"),
                jsonFlag,
            ],
            details: ["Needs a running daemon. With no VM, every busy VM is shown."]),
        CommandSpec(
            name: "requeue",
            command: .requeue,
            group: .running,
            summary: "Re-queue the fleet's queued jobs on a forge",
            positionals: "<forge>",
            flags: [yesFlag],
            docs: "docs/requeue-skip.md"),
        CommandSpec(
            name: "skip",
            command: .skip,
            group: .running,
            summary: "Mark the fleet's queued jobs as skipped on a forge",
            positionals: "<forge>",
            flags: [yesFlag],
            docs: "docs/requeue-skip.md"),
        CommandSpec(
            name: "heal",
            command: .heal,
            group: .running,
            summary: "What the healing agent fixed, and what waits on you",
            flags: [jsonFlag, quietFlag],
            subcommands: [
                CommandSpec(
                    name: "approve",
                    command: .heal,
                    summary: "Carry out a fix that waits for approval",
                    positionals: "ID"),
                CommandSpec(
                    name: "dismiss",
                    command: .heal,
                    summary: "Close a pending or surfaced entry",
                    positionals: "ID"),
            ],
            details: [
                "Safe fixes (a vanished warm VM, a full cache, a detached account) run on their own; destructive "
                    + "ones (pruning images, reinstalling a runtime) wait for heal approve. Exits 0 when nothing "
                    + "waits on you, 1 when something does or no daemon runs."
            ],
            docs: "docs/healing.md"),
        CommandSpec(
            name: "cleanup",
            command: .cleanup,
            group: .running,
            summary: "Reclaim disk: leftover VMs, the base image, the cache",
            flags: [
                .bool("--vms", "Leftover runner VMs"),
                .bool("--image", "The base image"),
                .bool("--cache", "The toolchain cache"),
                .bool("--all", "All of the above (the default)"),
                yesFlag,
                jsonFlag,
            ],
            details: ["Reports only unless --yes is given. Stop the fleet first. --json reports only."]),
        CommandSpec(
            name: "bench",
            command: .bench,
            group: .running,
            summary: "Benchmark runtimes, workloads and toolchains here",
            positionals: "[SUITE]…",
            flags: [
                .bool(
                    "--quick", "Small payloads, 1 iteration (default); thorough: larger, 3, cold installs",
                    group: "intensity"),
                .bool(
                    "--thorough", "Larger payloads, 3 iterations; toolchains time the cold install", group: "intensity"),
                .value("--iterations", "N", "Boot iterations (1 to 10)"),
                .value("--runtime", "tart|appleContainer|docker|host|all", "Only these runtimes (comma-separated)"),
                .value("--toolchains", "ID,…", "Scope the toolchains suite to these tools or stacks"),
                .bool("--all-toolchains", "Run the toolchains suite over the whole catalog"),
                .bool("--include-host", "Also benchmark the unisolated host runtime"),
                .value("--network", "URL", "Time a shallow git clone of this https, ssh or git URL"),
                .value("--project", "PATH", "Copy this checkout into the macOS guest and build it with Xcode"),
                .bool("--keep", "Keep the host scratch directory for debugging"),
                .bool("--force", "Do not wait for busy fleet VMs to finish"),
                .bool("--yes", "Agree to pause a running fleet without asking"),
                jsonFlag,
            ],
            details: [
                "SUITE is boot, casual, xcode, large, toolchains or video. Bare `kinhin bench` runs the first four; the "
                    + "toolchains suite takes 15 to 30 minutes when thorough and the video suite builds a short video in a "
                    + "container runtime, so both are opt-in. A running fleet is paused while the benchmark runs (--yes "
                    + "agrees to that without a prompt). Bench VMs and containers are named kinhin-bench-* and are "
                    + "deleted afterwards, also when the run fails or is cancelled.",
                "The JSON report is kept under Application Support/Kinhin/bench (the newest 20). Exits 1 when a "
                    + "suite or toolchain failed.",
            ],
            docs: "docs/benchmarks.md"),
        CommandSpec(
            name: "reset",
            command: .reset,
            group: .running,
            summary: "Reset config, the daemon install, or everything",
            flags: [
                .value("--scope", "config|daemon|all", "What to reset (asked interactively if omitted)"),
                .bool("--yes", "Skip the confirmation prompts"),
            ],
            details: ["Asks twice. There is no undo."]),

        // MARK: workflows
        CommandSpec(
            name: "video",
            command: .video,
            group: .other,
            summary: "Make a narrated video of your product from a config",
            subcommands: [
                CommandSpec(
                    name: "init",
                    command: .video,
                    summary: "Create a starter video in .kinhin/videos/",
                    positionals: "[name]",
                    flags: [
                        .value("--dir", "PATH", "The repository (default: the current directory)"),
                        .bool("--workflow", "Also write the CI pipeline that builds it on a kinhin runner"),
                        .value(
                            "--ci", "SYSTEM",
                            "auto (default: the repository's), github, gitea, forgejo, gitlab, bitbucket, azure or buildkite"
                        ),
                        .value(
                            "--runs-on", "LABELS",
                            "Runner labels for that pipeline (default: a self-hosted Linux runner, e.g. self-hosted,linux)"
                        ),
                        .value("--image", "REF", "The video image the workflow runs"),
                    ],
                    details: [
                        "With --workflow and no name, only the pipeline is written. Nothing is overwritten. "
                            + "GitHub's goes to .github/workflows/kinhin-video.yml, for --on-fleet; the other systems' are "
                            + "started by hand."
                    ]),
                CommandSpec(
                    name: "list",
                    command: .video,
                    summary: "List the videos in .kinhin/videos/",
                    flags: [
                        .value("--dir", "PATH", "The repository (default: the current directory)"),
                        jsonFlag,
                    ]),
                CommandSpec(
                    name: "build",
                    command: .video,
                    summary: "Build a video from its config",
                    positionals: "[name]",
                    flags: [
                        .value("--dir", "PATH", "The repository (default: the current directory)"),
                        .value("--theme", "NAME", "paper, clean, midnight, blueprint, chalk or your own"),
                        .value("--format", "RATIO", "16:9, 9:16, 4:5 or 1:1"),
                        .value("--captions", "on|off|all", "Burn captions into the picture"),
                        .value("--caption-style", "STYLE", "outline, box, shadow, bold, minimal or karaoke"),
                        .value("--music", "TRACK", "A catalog track, a file in the repository, or off"),
                        .bool("--fast", "A preview: quicker encode, no WebM"),
                        .value("--scene", "IDS", "Build only these scenes (comma-separated ids) as a quick preview"),
                        .bool("--watch", "Rebuild whenever the video's files change (Ctrl-C to stop)"),
                        .value("--quality", "draft|standard|high", "Encode quality (draft is --fast; high is slower)"),
                        .value("--fps", "24|30|60", "Frames per second (default 30)"),
                        .value("--runtime", "container|docker", "Which container runtime builds it"),
                        .value("--image", "REF", "Use this video image instead of the released one"),
                        .bool("--on-fleet", "Build on a runner via the repository's GitHub workflow (uses gh)"),
                        .value("--ref", "BRANCH", "Branch to run the workflow on (default: the current one)"),
                        .value("--ci", "SYSTEM", "With --on-fleet: the repository's CI system (default: detected)"),
                    ],
                    details: [
                        "Builds in a container with the video suite from a published image (pulled on first use), "
                            + "so there is nothing to copy into your repository. The repository is mounted read-only; "
                            + "the video and the render cache land in .kinhin/videos/out and .kinhin/videos/.cache. "
                            + "With one video in the folder the name may be left out."
                    ]),
                CommandSpec(
                    name: "validate",
                    command: .video,
                    summary: "Check a video's config without rendering it",
                    positionals: "[name]",
                    flags: [
                        .value("--dir", "PATH", "The repository (default: the current directory)"),
                        .bool("--all", "Check every video in the repository"),
                        .value("--runtime", "container|docker", "Which container runtime runs the check"),
                        .value("--image", "REF", "Use this video image instead of the released one"),
                    ],
                    details: [
                        "Runs the build's own checks (the config, theme, captions, music, text limits and claims) and "
                            + "that each device or terminal scene's clip is in its adapter. It renders nothing, so it is "
                            + "quick once the image is there. Exit 3 when a video has a problem."
                    ]),
                CommandSpec(
                    name: "theme",
                    command: .video,
                    summary: "List themes or start one of your own",
                    subcommands: [
                        CommandSpec(
                            name: "list",
                            command: .video,
                            summary: "List the built-in themes and yours",
                            flags: [
                                .value("--dir", "PATH", "The repository (default: the current directory)"),
                                jsonFlag,
                            ]),
                        CommandSpec(
                            name: "new",
                            command: .video,
                            summary: "Write a starter theme file",
                            positionals: "<name>",
                            flags: [
                                .value("--dir", "PATH", "The repository (default: the current directory)"),
                                .value("--from", "THEME", "Built-in theme to start from (default: paper)"),
                            ],
                            details: [
                                "Writes .kinhin/videos/themes/<name>.yml: it extends the built-in theme and lists the values most "
                                    + "people change, commented out with that theme's own values. Never overwrites."
                            ]),
                    ],
                    requiresSubcommand: true),
                CommandSpec(
                    name: "record",
                    command: .video,
                    summary: "Record one app window as a clip, without the mouse pointer",
                    positionals: "<app or title>",
                    flags: [
                        .value("--window", "ID", "Record this window id instead (see --list-windows)"),
                        .value("--seconds", "N", "How long to record (default 10, at most 600)"),
                        .value(
                            "--out", "PATH", "Where to write the .mov (default: the app's name in the current folder)"),
                        .value(
                            "--pointer", "PATH",
                            "Also write where the pointer was and where it clicked, as JSON, for a video's autoZoom"),
                        .bool("--list-windows", "List the windows that can be recorded, with their ids"),
                        jsonFlag,
                    ],
                    details: [
                        "Captures only that window's pixels, so the pointer and the windows over it stay out of the clip. "
                            + "The first run asks for Screen Recording permission for the app that runs kinhin (Terminal, iTerm or "
                            + "kinhin); allow it in System Settings and run the command again. Docs: video-adapters.md#recording-clips."
                    ]),
                CommandSpec(
                    name: "music",
                    command: .video,
                    summary: "Find music and add it to a video",
                    subcommands: [
                        CommandSpec(
                            name: "search",
                            command: .video,
                            summary: "Search openly licensed music",
                            positionals: "<words>",
                            flags: [
                                .value("--limit", "N", "How many results (default 10, at most 50)"),
                                .value(
                                    "--min-seconds", "N",
                                    "Shortest result (default 20; shorter ones are mostly sound effects)"),
                                .value("--max-seconds", "N", "Longest result"),
                                .value(
                                    "--license", "cc0|cc-by",
                                    "cc0 (default: CC0 and public domain) or cc-by (also CC BY, with credit)"),
                                jsonFlag,
                            ],
                            details: [
                                "Searches Openverse (Freesound, Wikimedia Commons and others) and the tracks built into the video image. "
                                    + "No account is needed (200 searches a day). The results are numbered for `add` and `preview`. "
                                    + "Licenses are as declared by each source; you are responsible for how you use a track."
                            ]),
                        CommandSpec(
                            name: "preview",
                            command: .video,
                            summary: "Listen to a search result",
                            positionals: "<number|id>"),
                        CommandSpec(
                            name: "add",
                            command: .video,
                            summary: "Download a track into the repository and use it",
                            positionals: "<number|id|name>",
                            flags: [
                                .value("--dir", "PATH", "The repository (default: the current directory)"),
                                .value("--video", "NAME", "The video to edit (default: the only one)"),
                                .value("--volume", "V", "Music volume, 0 to 1.5 (default 0.35)"),
                                .value(
                                    "--license", "cc0|cc-by",
                                    "Allow CC BY tracks too; the credit line is added to the config"),
                                .bool("--no-config", "Only download it and print the music: block"),
                            ],
                            details: [
                                "Saves the audio to .kinhin/videos/music/ with a .json file recording its source and license, then sets "
                                    + "music: in the video's YAML config, keeping the rest of the file as it is. A built-in track is "
                                    + "named in the config and downloads nothing."
                            ]),
                        CommandSpec(
                            name: "list",
                            command: .video,
                            summary: "Show the music each video uses",
                            flags: [
                                .value("--dir", "PATH", "The repository (default: the current directory)"),
                                jsonFlag,
                            ]),
                    ],
                    requiresSubcommand: true),
            ],
            defaultSubcommand: "build",
            details: [
                "A video is one YAML or JSON file in .kinhin/videos/: scenes, a voice-over, music, captions, a theme."
            ],
            docs: "docs/videos-for-your-project.md"),
        CommandSpec(
            name: "workflow",
            command: .workflow,
            group: .workflows,
            summary: "Run or route GitHub Actions workflows",
            subcommands: [
                CommandSpec(
                    name: "test",
                    command: .workflow,
                    summary: "Run a workflow locally on this Mac (host execution)",
                    positionals: "[FILE]",
                    flags: [
                        .value("--job", "NAME", "Run one job (its needs are not run)"),
                        .bool("--list", "Print the jobs and exit"),
                        .bool("--lenient", "Exit 0 on a partial result (skipped unsupported work)"),
                        jsonFlag,
                    ],
                    details: [
                        "No VM, token or config: the YAML is parsed and jobs run sequentially in `needs` order, "
                            + "each script step through bash directly on this Mac (not isolated). FILE defaults to "
                            + "the only workflow in .github/workflows.",
                        "Matrix jobs, other `uses:` actions and unsupported `if:` conditions are skipped and make "
                            + "the result partial: exit 1 unless --lenient. A failed job always exits 1.",
                    ],
                    docs: "docs/workflow-testing.md"),
                CommandSpec(
                    name: "route",
                    command: .workflow,
                    summary: "Route a workflow's jobs to a runtime",
                    positionals: "<FILE|name> <runtime>",
                    flags: [
                        .value("--job", "NAME", "Route one job instead of every job"),
                        .bool("--dry-run", "Print what would change; write nothing"),
                        jsonFlag,
                        .bool("--consent", "Required for host (jobs run unisolated on this Mac)"),
                    ],
                    details: [
                        "<runtime> is tart, appleContainer, docker or host. Edits the workflow's runs-on: labels "
                            + "(comment-preserving; ${{ }} and mapping forms are refused) and, when precedence "
                            + "needs it, adds an owner/repo@Workflow route to the config."
                    ],
                    docs: "docs/runtimes.md"),
            ],
            requiresSubcommand: true),

        // MARK: other
        CommandSpec(
            name: "support",
            aliases: ["sponsor"],
            command: .support,
            group: .other,
            summary: "Show ways to donate or sponsor kinhin"),
        CommandSpec(
            name: "issue",
            command: .issue,
            group: .other,
            summary: "Submit an issue on GitHub",
            flags: [
                .bool("--print", "Print the URL instead of opening a browser"),
                .bool("--json", "Print the URL as JSON"),
            ],
            details: [
                "Opens GitHub's issue chooser (bug report, feature request, forge report). "
                    + "Attach `kinhin doctor --bundle FILE` to a bug report."
            ]),
        CommandSpec(
            name: "mcp",
            command: .mcp,
            group: .other,
            summary: "Serve MCP over stdio for AI agents",
            details: [
                "Exposes status, doctor, setup status, auth status, runtimes, pipeline, logs and "
                    + "pause/resume/stop as JSON tools. stdout carries the protocol only; reset, "
                    + "`cleanup --yes` and token entry are never exposed."
            ]),
        CommandSpec(
            name: "version",
            aliases: ["--version", "-v"],
            command: .version,
            group: .other,
            summary: "Print the version"),
        CommandSpec(
            name: "help",
            aliases: ["--help", "-h"],
            command: .help,
            group: .other,
            summary: "Show this help, or `help <command>` for one command",
            positionals: "[command]"),
    ]

    // MARK: - Lookup

    /// The top-level spec a token names (a name or alias), if any.
    static func topLevel(_ token: String) -> CommandSpec? {
        all.first { $0.matches(token) }
    }
}
