import KinhinKit
import XCTest

@testable import kinhin

final class ToolchainsDetectCommandTests: XCTestCase {
    private func project(_ files: [String: String] = ["go.mod": "module x\n\ngo 1.22.5\n"]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-detect-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, content) in files { try Data(content.utf8).write(to: root.appendingPathComponent(name)) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }  // temp dir cleanup
        return root
    }

    func testStdoutIsYAMLAndEvidenceGoesToStderr() throws {
        let output = try ToolchainsDetectCommand.execute([try project().path])
        XCTAssertEqual(output.stdout, "toolchains:\n  specs: [\"go@1.22.5\"]\n")
        XCTAssertTrue(output.stderr.contains("go.mod"))
    }

    func testJSONIsParseableAndHasNoStderr() throws {
        let output = try ToolchainsDetectCommand.execute([try project().path, "--json"])
        let detection = try JSONDecoder().decode(ToolchainDetection.self, from: Data(output.stdout.utf8))
        XCTAssertEqual(detection.specs, ["go@1.22.5"])
        XCTAssertTrue(output.stderr.isEmpty)
    }

    func testWriteRefusesToOverwriteWithoutForce() throws {
        let root = try project()
        _ = try ToolchainsDetectCommand.execute([root.path, "--write"])
        let file = root.appendingPathComponent(".kinhin.yml")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("go@1.22.5"))

        XCTAssertThrowsError(try ToolchainsDetectCommand.execute([root.path, "--write"]))
        try Data("old".utf8).write(to: file)
        _ = try ToolchainsDetectCommand.execute([root.path, "--write", "--force"])
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("go@1.22.5"))
    }

    func testWriteWithNothingDetectedWritesNothing() throws {
        let root = try project(["README.md": "x"])
        XCTAssertThrowsError(try ToolchainsDetectCommand.execute([root.path, "--write"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".kinhin.yml").path))
    }

    func testDetectSkipsConfigAutoCreate() {
        XCTAssertFalse(CLICommand.shouldAutoCreateConfig(.toolchains, args: ["toolchains", "detect"]))
        XCTAssertTrue(CLICommand.shouldAutoCreateConfig(.toolchains, args: ["toolchains"]))
    }
}
