import Foundation
import KinhinKit

/// `kinhin doctor --bundle [FILE]` — one redacted text file to attach to a bug
/// report: versions, the doctor report, the config and the recent log.
enum SupportBundle {
    /// How much of the log tail goes in: enough for the failure, small enough to attach.
    static let logLines = 300

    static func render(
        version: String, system: String, doctor: String, config: String?, logTail: String, date: Date = Date()
    ) -> String {
        let sections: [(String, String)] = [
            ("kinhin", "version \(version)\n\(system)\ncreated \(ISO8601DateFormatter().string(from: date))"),
            ("doctor", doctor),
            ("config.yaml", config ?? "(no config file)"),
            ("log (last \(logLines) lines)", logTail.isEmpty ? "(no log file yet)" : logTail),
        ]
        let body = sections.map { "===== \($0.0) =====\n\($0.1)" }.joined(separator: "\n\n")
        // Every section goes through the redactor again: a bundle is meant to be posted publicly.
        return Log.redact(body) + "\n"
    }

    static func tail(of file: URL, lines: Int) -> String {
        // A log that is missing or unreadable just means an empty section.
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }

    static func run(args: [String]) async throws {
        let explicit = args.drop { $0 != "--bundle" }.dropFirst().first.flatMap { $0.hasPrefix("-") ? nil : $0 }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = URL(fileURLWithPath: explicit ?? "kinhin-support-\(stamp).txt")
        let system = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        let text = render(
            version: kinhinVersion.current, system: system, doctor: await DoctorReportBuilder().buildPlainText(),
            config: try? String(contentsOf: Paths.config, encoding: .utf8),  // missing config is reported in the bundle
            logTail: tail(of: Paths.logsDirectory.appendingPathComponent("kinhin.log"), lines: logLines))
        try text.write(to: destination, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        print("wrote \(destination.path) — review it, then attach it to your issue (tokens are redacted)")
    }
}
