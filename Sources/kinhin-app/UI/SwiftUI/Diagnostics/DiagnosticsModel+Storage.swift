import Foundation
import KinhinKit

// MARK: - Storage and Docker Hub cache rows

extension DiagnosticsModel {
    /// One row per configured storage path (`tart_home`, `container_app_root`, `registry_cache_path`,
    /// `toolchain_cache_path`): where it is, the volume holding it, and for a failing path what is wrong and the fix.
    static func storageRows(_ storage: DoctorReport.StorageSection) -> [Row] {
        storage.paths.map { path in
            let title = String(
                localized: "Storage · \(path.key)", bundle: .l10n,
                comment: "Diagnostics row title; %@ is a config key such as tart_home that stays verbatim")
            let detail: String
            if path.ok {
                if let mount = path.mountPoint {
                    detail = String(
                        localized: "\(path.path) · on \(mount) ✓", bundle: .l10n,
                        comment:
                            "Diagnostics storage row; first %@ is a folder path, second is the volume's mount point")
                } else {
                    detail = String(
                        localized: "\(path.path) ✓", bundle: .l10n,
                        comment: "Diagnostics storage row; %@ is a folder path")
                }
            } else if let problem = path.problem, let fix = path.fix {
                detail = String(
                    localized: "\(path.path) — \(problem)\nFix: \(fix)", bundle: .l10n,
                    comment: "Diagnostics storage row; folder path, what is wrong, then the fix")
            } else if let problem = path.problem {
                detail = String(
                    localized: "\(path.path) — \(problem)", bundle: .l10n,
                    comment: "Diagnostics storage row; folder path, then what is wrong")
            } else {
                detail = String(
                    localized: "\(path.path) — not usable", bundle: .l10n,
                    comment: "Diagnostics storage row; %@ is a folder path")
            }
            return Row(title: title, detail: detail, ok: path.ok)
        }
    }

    /// The Docker Hub cache row: whether it runs and where, how much it holds, its TTL, and any broken entries (the
    /// next Docker runner deletes them, so they are fetched again). One line per fact, each a whole sentence.
    static func registryCacheRow(_ cache: DoctorReport.RegistryCacheStatus) -> Row {
        var lines: [String] = []
        if cache.running, let address = cache.address {
            lines.append(
                String(
                    localized: "running at \(address) ✓", bundle: .l10n,
                    comment: "Diagnostics Docker Hub cache row; %@ is the cache's host:port address"))
        } else if cache.running {
            lines.append(String(localized: "running ✓", bundle: .l10n, comment: "Diagnostics Docker Hub cache row"))
        } else if let problem = cache.problem {
            lines.append(
                String(
                    localized: "not running — \(problem)", bundle: .l10n,
                    comment: "Diagnostics Docker Hub cache row; %@ is the reason"))
        } else {
            lines.append(
                String(
                    localized: "not running — it starts with the first Docker runner", bundle: .l10n,
                    comment: "Diagnostics Docker Hub cache row"))
        }
        if let bytes = cache.dataBytes {
            lines.append(
                String(
                    localized: "\(AppFormat.bytes(bytes)) cached in \(cache.dataDirectory)", bundle: .l10n,
                    comment: "Diagnostics Docker Hub cache row; a formatted byte count, then a folder path"))
        } else {
            lines.append(
                String(
                    localized: "nothing cached in \(cache.dataDirectory)", bundle: .l10n,
                    comment: "Diagnostics Docker Hub cache row; %@ is a folder path"))
        }
        if let ttl = cache.ttl ?? cache.wantedTTL {
            if ttl == "0h" {
                lines.append(
                    String(
                        localized: "TTL off — nothing expires", bundle: .l10n,
                        comment: "Diagnostics Docker Hub cache row"))
            } else {
                lines.append(
                    String(
                        localized: "TTL \(ttl)", bundle: .l10n,
                        comment: "Diagnostics Docker Hub cache row; %@ is a duration such as 168h"))
            }
            if let wanted = cache.wantedTTL, let running = cache.ttl, wanted != running {
                lines.append(
                    String(
                        localized: "config.yaml says \(wanted); it applies at the cache's next start", bundle: .l10n,
                        comment: "Diagnostics Docker Hub cache row; %@ is a duration such as 168h"))
            }
        }
        if let broken = cache.brokenEntries, broken > 0 {
            let count = String(broken)
            lines.append(
                String(
                    localized:
                        "UNHEALTHY — broken entries: \(count). Pulls of them fail with unexpected EOF; the next Docker runner deletes them so they are fetched again.",
                    bundle: .l10n,
                    comment: "Diagnostics Docker Hub cache row; %@ is a count written as digits; EOF stays verbatim"))
            let shown = cache.brokenExamples ?? []
            if !shown.isEmpty {
                lines.append(
                    String(
                        localized: "e.g. \(shown.joined(separator: ", "))", bundle: .l10n,
                        comment: "Diagnostics Docker Hub cache row; %@ is a comma-separated list of cache file paths"))
            }
        } else if cache.brokenEntries != nil {
            lines.append(
                String(localized: "entries intact ✓", bundle: .l10n, comment: "Diagnostics Docker Hub cache row"))
        }
        return Row(
            title: String(localized: "Docker Hub cache", bundle: .l10n, comment: "Diagnostics row title"),
            detail: lines.joined(separator: "\n"), ok: cache.isHealthy)
    }
}
