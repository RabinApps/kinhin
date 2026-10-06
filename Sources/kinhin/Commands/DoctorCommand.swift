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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (report, try encoder.encode(report))
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

    static func run(_ args: [String]) async throws {
        Paths.ensureSupportDirectories()
        // Machine output first: the whole point is a one-shot diagnostics
        // document for scripts — nothing else is printed in this mode.
        if args.contains("--bundle") {
            try await SupportBundle.run(args: args)
            return
        }
        if args.contains("--json") {
            _ = try await Self.emitJSON()
            return
        }
        print(await DoctorReportBuilder().buildPlainText())
    }
}
