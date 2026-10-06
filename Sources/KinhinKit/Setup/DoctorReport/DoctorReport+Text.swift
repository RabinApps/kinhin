import Foundation

// DoctorReport — the human rendering `kinhin doctor` prints. Built from the
// same report as `--json`, the app's Diagnostics and the Shortcuts intent,
// so every surface agrees on what is broken and how to fix it.
extension DoctorReport {
    /// The per-runtime image totals as one line — "tart 45 GB · container 4 GB
    /// · docker 65 GB" — in runtime order, with sub-GB totals reading "<1 GB".
    /// nil when no runtime reported a size (nothing to show). One
    /// implementation behind the human doctor's `images:` row and the app's
    /// Diagnostics tab, so the two surfaces cannot drift.
    public var imageTotalLine: String? {
        guard let imageTotalGB else { return nil }
        let parts = ["tart", "container", "docker"].compactMap { runtime -> String? in
            guard let total = imageTotalGB[runtime] else { return nil }
            return "\(runtime) \(total > 0 ? "\(total) GB" : "<1 GB")"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The prune suggestion as one line — "62 unused image(s) (~68 GB) —
    /// review with: kinhin image prune" — worded with `image prune`'s own
    /// report (the count and the `(~N GB)` estimate), so the advice and the
    /// command's output cannot contradict each other. nil when nothing is
    /// wasting disk. Shared by the human doctor's `prune:` row and the
    /// app's Diagnostics row.
    public var imagePruneLine: String? {
        guard let imagePrune else { return nil }
        var line = "\(imagePrune.count) unused image(s)"
        if let gb = imagePrune.reclaimGB {
            line += gb > 0 ? " (~\(gb) GB)" : " (<1 GB)"
        }
        return line + " — review with: \(imagePrune.command)"
    }

    /// The disk-pressure advisory as one line: the engine's guard numbers
    /// (free, per-instance footprint + reserve, the runtime planned next),
    /// then what the images hold and what a prune would give back. nil when
    /// free disk covers the next instance. Shared by the doctor's WARNING
    /// line and the app's Diagnostics row.
    public var diskPressureLine: String? {
        guard let diskPressure else { return nil }
        var line =
            "\(diskPressure.freeGB) GB free, a new \(diskPressure.runtime) instance needs "
            + "\(diskPressure.instanceDiskGB) GB + \(diskPressure.reserveGB) GB reserve — the fleet holds spawns"
        if let images = imageTotalGB?.values.reduce(0, +) {
            line += "; images hold \(images) GB"
        }
        if let reclaim = imagePrune?.reclaimGB, let command = imagePrune?.command {
            line += "; reclaim \(reclaim > 0 ? "\(reclaim) GB" : "<1 GB") with: \(command)"
        }
        return line
    }

    /// The report as aligned "label: value" lines (no trailing newline).
    public var plainText: String {
        var lines = ["kinhin doctor"]
        func row(_ label: String, _ value: String) {
            lines.append("  \((label + ":").padding(toLength: 11, withPad: " ", startingAt: 0)) \(value)")
        }
        func more(_ text: String) { lines.append("              \(text)") }

        row("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
        row("arch", host.arm64 ? "arm64 ✓" : "NOT arm64 — Tart requires Apple Silicon ✗")
        row("cores", "\(host.logicalCores)")
        row("memory", "\(host.memoryGB) GB")
        row("free disk", "\(host.freeDiskGB) GB")

        switch clt.state {
        case "ok": row("clt", "Command Line Tools \(clt.version ?? "") ✓")
        case "outdated": row("clt", "OUTDATED ✗ (\(clt.version ?? "?")) — Homebrew will refuse to build")
        case "missing": row("clt", "NOT INSTALLED ✗ — Homebrew needs it to build from source")
        default: row("clt", "xcode-select points nowhere ✗ — reinstall, then re-select")
        }
        if let fix = clt.fixCommand { row("clt fix", fix) }
        if let hint = clt.fixHint { more(hint) }

        switch tart.state {
        case "healthy": row("tart", "installed and launches ✓")
        case "missing": row("tart", "NOT FOUND — install with: \(tart.repairCommands.first ?? "brew install tart")")
        case "killedOnLaunch":
            row("tart", "INSTALLED BUT KILLED ON LAUNCH ✗ (Gatekeeper/notarization)")
        default: row("tart", "BROKEN ✗ (\(tart.reason ?? "unknown"))")
        }
        if !tart.ok, tart.state != "missing" {
            row("tart fix", "roll back to the notarized Cirrus Labs build:")
            tart.repairCommands.forEach(more)
        }

        if let container {
            row("container", container.ok ? "apple container ready ✓ (Linux microVM runners)" : container.fix ?? "✗")
            if container.ok {
                row(
                    "cont image",
                    container.imageFound
                        ? "\(container.image) ✓"
                        : "\(container.image) NOT LOCAL — prepare with: kinhin image prepare --container --target \(container.image)"
                )
            }
        }
        if let docker {
            row("docker", docker.ok ? "ready ✓ (\(docker.platform))" : docker.fix ?? "✗")
            if docker.ok {
                row(
                    "dock image",
                    docker.imageFound
                        ? "\(docker.image) ✓"
                        : "\(docker.image) NOT LOCAL — prepare with: kinhin image prepare --docker --target \(docker.image)"
                )
            }
            if let note = docker.note { more("⚠ \(note)") }
        }
        if let hostRuntime {
            row(
                "host",
                hostRuntime.ok
                    ? "runner agent installed ✓ (routes run UNISOLATED on this Mac)"
                    : "agent NOT INSTALLED ✗ — install with: kinhin setup repair host-agent")
        }

        // Image disk usage per runtime — the bloat number `kinhin image
        // list` prints under each section title, in the same runtime order.
        // A runtime whose sizes were not read has no total and is left out
        // (its own rows above already say whether it could be listed).
        if let usage = imageTotalLine { row("images", usage) }
        // …and the sweep that would give some of it back — only when there
        // is something to sweep (the plan's own selection, not a guess).
        if let prune = imagePruneLine { row("prune", prune) }

        if auth.accounts.isEmpty {
            row("token", "no accounts configured — add one: kinhin auth add NAME --github --scope OWNER/REPO")
        }
        for account in auth.accounts {
            row("tok \(account.name)", account.stored ? "stored ✓" : account.detail)
        }

        let cache = toolchainCache
        if cache.usable {
            let gb = Double(cache.totalBytes) / 1_073_741_824
            let detail = cache.ecosystems.map {
                "\($0.directory) \(String(format: "%.1f", Double($0.bytes) / 1_048_576)) MB"
            }.joined(separator: ", ")
            row(
                "cache",
                "\(String(format: "%.1f", gb)) GB at \(cache.root) ✓\(detail.isEmpty ? " (empty)" : " — \(detail)")")
        } else {
            row("cache", "NOT USABLE ✗ at \(cache.root) — the next prepare recreates it")
        }

        if let capacity {
            row("capacity", "up to \(capacity.maxConcurrent) concurrent VM(s) (binding: \(capacity.bindingConstraint))")
            row("job slots", "up to \(capacity.jobSlots) concurrent jobs")
            if !capacity.fits {
                lines.append("  WARNING: a single VM does not fit the host within reserved headroom")
            }
        }
        // The engine's disk guard, warned before the fleet hits it — the
        // same numbers as the spawn hold, plus the image totals and the
        // prune lever (the fleet can only hold spawns; freeing images is
        // what the user can actually do).
        if let pressure = diskPressureLine {
            lines.append("  WARNING: disk pressure — \(pressure)")
        }
        if let security {
            if security.softnetEnabled {
                row(
                    "softnet",
                    security.softnetInstalled
                        ? "on ✓ (runner VMs are isolated from each other and the LAN)"
                        : "ON but softnet is NOT INSTALLED ✗ — \(security.fix ?? "install softnet"); the fleet will not start"
                )
            } else {
                row("softnet", "off (runner VMs share one network)")
            }
            if security.warnings.isEmpty {
                row("security", "no advisories ✓")
            } else {
                for (index, warning) in security.warnings.enumerated() {
                    if index == 0 { row("security", "⚠ \(warning)") } else { more("⚠ \(warning)") }
                }
            }
        }
        if let base = tartBaseImage {
            switch base.state {
            case "known": row("base image", "\(base.reference) ✓ (\(base.pinned ? "pinned" : "pre-configured"))")
            case "local": row("base image", "\(base.reference) ✓ (local VM)")
            default:
                row("base image", "\(base.reference) NOT USABLE ✗")
                if let fix = base.fix { more(fix) }
            }
            if let warning = base.warning { more("⚠ \(warning)") }
        }
        return lines.joined(separator: "\n")
    }
}
