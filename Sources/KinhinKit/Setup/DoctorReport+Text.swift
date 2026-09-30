import Foundation

// DoctorReport — the human rendering `kinhin doctor` prints. Built from the
// same report as `--json`, the app's Diagnostics and the Shortcuts intent,
// so every surface agrees on what is broken and how to fix it.
extension DoctorReport {
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
