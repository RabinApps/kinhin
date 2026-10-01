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
        print(await DoctorReportBuilder().buildPlainText())
    }
}
