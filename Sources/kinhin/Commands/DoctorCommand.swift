import Foundation
import KinhinKit

enum DoctorCommand {
    /// Builds and prints the machine-readable diagnostics document, returning
    /// exactly the data it printed so tests can decode the emitted contract.
    /// `builder` is injectable: the live default probes the real machine,
    /// tests pass a fully-fixture builder (no Keychain, subprocess, network).
    static func emitJSON(builder: DoctorReportBuilder = DoctorReportBuilder()) async throws -> (
        report: DoctorReport, data: Data
    ) {
        let report = await builder.build()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        print(String(decoding: data, as: UTF8.self))
        return (report, data)
    }

    static func run(_ args: [String]) async throws {
        Paths.ensureSupportDirectories()
        // Machine output first: the whole point is a one-shot diagnostics
        // document for scripts — nothing else is printed in this mode.
        if args.contains("--json") {
            _ = try await Self.emitJSON()
            return
        }
        let report = await DoctorReportBuilder().build()
        print(report.plainText)
        // A missing or unparseable config simply has no config-specific lines
        // below; the report above already flags it in its checks.
        let cfg = try? ConfigLoader.load()
        let configExists = FileManager.default.fileExists(atPath: Paths.config.path)
        print("  config:     \(configExists ? Paths.config.path : "missing — run: kinhin config init")")
        if let cfg {
            print("  image:      \(cfg.image)")
            if let shareCache = cfg.toolchains?.shareCache, !shareCache {
                print(
                    "  cache note: share_cache is off — per-job `kinhin-toolchain install` steps download from scratch every job"
                )
            }
            await printOrgPermissions(cfg)
        }
    }

    /// Org scopes: what the token needs, then an active check — mint (and
    /// discard) a registration token, the exact call the fleet depends on.
    private static func printOrgPermissions(_ cfg: KinhinConfig) async {
        guard let account = cfg.primaryGitHub, !account.scope.isEmpty, !account.scope.contains("/") else { return }
        let org = account.scope
        print("  scope:      organization '\(org)' — runners serve every repo")
        print(
            TokenRequirements.github(scope: org).plainText
                .split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
        do {
            if let token = try KeychainTokenStore.load(forge: .github, name: account.name) {
                let report = await TokenHealthCheck.github(token: token, scope: org)
                print("  org perms:  \(report.message)")
            } else {
                print("  org perms:  cannot verify — no token stored (run: kinhin auth set --account \(account.name))")
            }
        } catch {
            print("  org perms:  cannot verify — \(error.localizedDescription)")
        }
    }
}
