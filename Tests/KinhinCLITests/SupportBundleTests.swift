import XCTest

@testable import kinhin

final class SupportBundleTests: XCTestCase {
    func testBundleRedactsEverySectionAndKeepsTheStructure() {
        let text = SupportBundle.render(
            version: "0.1.0", system: "macOS 15", doctor: "token ghp_abcdefghijklmnopqrstuvwxyz0123456789 ok",
            config: "instance: https://user:hunter2hunter2@git.example/x",
            logTail: "Authorization: token s3cr3tvalue123")
        for secret in ["ghp_abcdefghijklmnopqrstuvwxyz0123456789", "hunter2hunter2", "s3cr3tvalue123"] {
            XCTAssertFalse(text.contains(secret), "leaked \(secret)")
        }
        for heading in ["===== kinhin =====", "===== doctor =====", "===== config.yaml =====", "===== log"] {
            XCTAssertTrue(text.contains(heading), heading)
        }
    }

    func testTailKeepsTheLastLinesAndToleratesAMissingFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kn-tail-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        try (1...10).map(String.init).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(SupportBundle.tail(of: file, lines: 3), "8\n9\n10")
        XCTAssertEqual(SupportBundle.tail(of: file.appendingPathExtension("missing"), lines: 3), "")
    }
}
