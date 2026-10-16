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
        let file = root.appendingPathComponent(".kinhin/config.yml")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("go@1.22.5"))

        XCTAssertThrowsError(try ToolchainsDetectCommand.execute([root.path, "--write"]))
        // An older .kinhin.yml also blocks a plain --write.
        let legacy = try project()
        try Data("toolchains: {}\n".utf8).write(to: legacy.appendingPathComponent(".kinhin.yml"))
        XCTAssertThrowsError(try ToolchainsDetectCommand.execute([legacy.path, "--write"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent(".kinhin/config.yml").path))
        try Data("old".utf8).write(to: file)
        _ = try ToolchainsDetectCommand.execute([root.path, "--write", "--force"])
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("go@1.22.5"))
    }

    func testWriteWithNothingDetectedWritesNothing() throws {
        let root = try project(["README.md": "x"])
        XCTAssertThrowsError(try ToolchainsDetectCommand.execute([root.path, "--write"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".kinhin/config.yml").path))
    }

    func testDetectSkipsConfigAutoCreate() {
        XCTAssertFalse(CLICommand.shouldAutoCreateConfig(.toolchains, args: ["toolchains", "detect"]))
        XCTAssertTrue(CLICommand.shouldAutoCreateConfig(.toolchains, args: ["toolchains"]))
    }

    /// A tart listing that failed shows "size unknown", never "not on disk".
    func testImageSizeLabelDoesNotClaimAnUnlistedImageIsGone() {
        XCTAssertEqual(ToolchainsCommand.sizeLabel("img", sizes: nil), "size unknown")
        XCTAssertEqual(ToolchainsCommand.sizeLabel("img", sizes: [:]), "not on disk")
        XCTAssertEqual(ToolchainsCommand.sizeLabel("img", sizes: ["img": 12]), "12 GB disk")
    }

    /// A missing config is "no config"; a broken one throws instead of
    /// letting `toolchains prune` run on the default policy.
    func testConfigIfPresentThrowsForABrokenConfig() throws {
        let root = try project([:])
        let url = root.appendingPathComponent("config.yaml")
        XCTAssertNil(try loadConfigIfPresent(at: url))
        try "max_runners: [not a number".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try loadConfigIfPresent(at: url))
    }
}
