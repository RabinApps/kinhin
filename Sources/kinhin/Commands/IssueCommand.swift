import Foundation
import KinhinKit

/// `kinhin issue`: opens GitHub's issue chooser (bug, feature, forge report) in
/// the browser. `--print` prints the URL instead (SSH, headless); `--json`
/// prints it as a JSON document.
enum IssueCommand {
    static func run(_ args: [String]) throws {
        let url = SupportLinks.reportAnIssue.url
        if args.contains("--json") {
            let data = try JSONSerialization.data(
                withJSONObject: ["url": url.absoluteString], options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else if args.contains("--print") {
            print(url.absoluteString)
        } else if !open(url) {
            // No browser to hand it to: fall back to the URL so it can be copied.
            print("Could not open a browser. Submit an issue at:\n\(url.absoluteString)")
        } else {
            print("Opened \(url.absoluteString)")
        }
    }

    private static func open(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
