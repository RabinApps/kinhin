import Foundation
import KinhinKit

enum SetupStatusCommand {
    static func run(_ args: [String]) async throws {
        Paths.ensureSupportDirectories()
        let setup = await SetupStatusComputer().compute()
        if args.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(setup)
            print(String(decoding: data, as: UTF8.self))
        } else {
            for check in setup.checks {
                let mark = check.ok ? "✓" : "✗"
                let act = check.action.map { "  → \(SetupAction.title(for: $0))" } ?? ""
                print("  [\(mark)] \(check.title): \(check.detail)\(act)")
            }
            print("ready: \(setup.ready ? "yes — kinhin start when you're ready" : "no")")
        }
    }
}
