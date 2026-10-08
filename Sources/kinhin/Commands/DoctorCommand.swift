import Foundation
import KinhinKit

enum DoctorCommand {
    /// Builds the machine-readable diagnostics document without printing it —
    /// shared by `emitJSON` and the MCP `doctor` tool. `builder` is
    /// injectable: the live default probes the real machine, tests pass a
    /// fully-fixture builder (no Keychain, subprocess, network).
    static func document(builder: DoctorReportBuilder = DoctorReportBuilder()) async throws -> (
        report: DoctorReport, data: Data
    ) {
        let report = await builder.build()
        return (report, try CLIJSON.data(report))
    }

    /// Builds and prints the machine-readable diagnostics document, returning
    /// exactly the data it printed so tests can decode the emitted contract.
    static func emitJSON(builder: DoctorReportBuilder = DoctorReportBuilder()) async throws -> (
        report: DoctorReport, data: Data
    ) {
        let built = try await document(builder: builder)
        print(String(decoding: built.data, as: UTF8.self))
        return built
    }

    /// `kinhin doctor`: exits 0 when everything is ready, 1 when something
    /// needs attention (the report's `ready`). `--quiet` prints nothing.
    static func run(_ args: [String], builder: DoctorReportBuilder = DoctorReportBuilder()) async throws {
        Paths.ensureSupportDirectories()
        // Machine output first: the whole point is a one-shot diagnostics
        // document for scripts — nothing else is printed in this mode.
        if args.contains("--bundle") {
            try await SupportBundle.run(args: args)
            return
        }
        let quiet = args.contains("--quiet") || args.contains("-q")
        var builder = builder
        // Network probe of every account's token; doctor is offline without it.
        if args.contains("--check-tokens") { builder.checkTokens = true }
        let ready: Bool
        if quiet {
            ready = await builder.build().ready
        } else if args.contains("--json") {
            ready = try await Self.emitJSON(builder: builder).report.ready
        } else {
            let report = await builder.build()
            print(await builder.plainText(for: report))
            ready = report.ready
        }
        ExitRule.finish(healthy: ready)
    }
}
