import XCTest

@testable import KinhinKit
@testable import kinhin

final class ConfigValidateTests: XCTestCase {
    private var scratch: URL!
    private var configURL: URL { scratch.appendingPathComponent("config.yaml") }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-validate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testValidConfigPrintsASummaryAndWritesNothing() throws {
        try """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: [self-hosted, macos]
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: configURL)
        let summary = try ConfigCommands.validate(configURL: configURL)
        XCTAssertTrue(summary.contains("config OK"), summary)
        XCTAssertTrue(summary.contains("github (github, acme/widgets)"), summary)
        XCTAssertEqual(try Data(contentsOf: configURL), before)
    }

    func testInvalidConfigThrowsTheLoadersError() throws {
        try "poll_interval: 1\n".write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfigCommands.validate(configURL: configURL)) { error in
            XCTAssertTrue(error is ConfigError, "\(error)")
        }
    }

    func testMissingFileAndStarterTemplateAreErrors() throws {
        XCTAssertThrowsError(try ConfigCommands.validate(configURL: configURL))
        try ConfigCommands.configInit([], configURL: configURL)
        XCTAssertThrowsError(try ConfigCommands.validate(configURL: configURL)) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("no accounts"), "\(error)")
        }
    }

    // MARK: - the --json document

    func testValidationDocumentReportsTheParsedFacts() throws {
        try """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: [self-hosted, macos]
        runtimes:
          routes:
            - pattern: acme/widgets
              runtime: tart
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let document = ConfigCommands.validationDocument(configURL: configURL)
        XCTAssertEqual(
            document,
            .init(
                valid: true, path: configURL.path, error: nil,
                accounts: [.init(name: "github", forge: "github", scope: "acme/widgets")],
                labels: ["self-hosted", "macos"], runtimeRoutes: 1)
        )
    }

    func testValidationDocumentReportsFailuresInsteadOfThrowing() throws {
        try "poll_interval: 1\n".write(to: configURL, atomically: true, encoding: .utf8)
        let document = ConfigCommands.validationDocument(configURL: configURL)
        XCTAssertFalse(document.valid)
        XCTAssertFalse(document.error?.isEmpty ?? true, "the failure must say why")
        XCTAssertTrue(document.accounts.isEmpty)
        // The prose path classifies the same failure as a config error (exit 3).
        XCTAssertThrowsError(try ConfigCommands.validate(configURL: configURL)) { error in
            XCTAssertTrue(error is ConfigError, "\(error)")
        }
    }

    func testValidationDocumentEncodesTheMachineContract() throws {
        try "poll_interval: 1\n".write(to: configURL, atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let object = try JSONSerialization.jsonObject(
            with: try encoder.encode(ConfigCommands.validationDocument(configURL: configURL)))
        let document = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(document["valid"] as? Bool, false)
        XCTAssertEqual(document["path"] as? String, configURL.path)
        XCTAssertFalse((document["error"] as? String ?? "").isEmpty)
    }

    // MARK: - the FILE positional

    func testRunValidateValidatesThePositionalFileInsteadOfTheDefaultOne() throws {
        // The summary names the file: a wrong positional would have validated
        // this Mac's (possibly absent) default config instead.
        try """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let prose = try captureStdout { try ConfigCommands.runValidate([configURL.path]) }
        XCTAssertTrue(prose.contains("config OK: \(configURL.path)"), prose)

        let json = try captureStdout { try ConfigCommands.runValidate([configURL.path, "--json"]) }
        let document = try JSONDecoder().decode(ConfigCommands.ValidationDocument.self, from: Data(json.utf8))
        XCTAssertTrue(document.valid, "\(document.error ?? "no error")")
        XCTAssertEqual(document.path, configURL.path)
    }

    func testRunValidateHonorsTheEndOfOptionsMarkerAndRejectsSurplusOperands() throws {
        try """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        """.write(to: configURL, atomically: true, encoding: .utf8)

        // `--` ends the flags: the operand after it is the FILE, even one
        // whose name starts with `-`.
        let dashFile = scratch.appendingPathComponent("-breaky.yaml")
        try """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        """.write(to: dashFile, atomically: true, encoding: .utf8)
        let prose = try captureStdout { try ConfigCommands.runValidate(["--", dashFile.path]) }
        XCTAssertTrue(prose.contains("config OK: \(dashFile.path)"), prose)

        // More than one FILE operand is a usage error, not a silent pick of
        // the first.
        XCTAssertThrowsError(try ConfigCommands.runValidate([configURL.path, dashFile.path])) { error in
            guard let cliError = error as? CLIError else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(cliError.message.contains("at most one config"), cliError.message)
            XCTAssertEqual(cliError.exit, .usage)
        }
    }

    func testRunValidateStillThrowsTheLoadersErrorForAnInvalidPositionalFile() throws {
        try "poll_interval: 1\n".write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfigCommands.runValidate([configURL.path])) { error in
            XCTAssertTrue(error is ConfigError, "\(error)")
        }
        // The --json path exits 3 (by design: the same exit code as the default file's), so
        // the process-exiting variant is not called here.
    }

    /// Runs `body` with stdout redirected to a scratch file and returns what it
    /// printed. A pipe would deadlock here: fd 1 stays a live write end after
    /// `dup2`, so `readDataToEndOfFile` can be waiting for an EOF only the
    /// post-read `defer` can deliver.
    private func captureStdout(_ body: () throws -> Void) throws -> String {
        let file = scratch.appendingPathComponent("capture-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let out = FileHandle(forWritingAtPath: file.path) else {
            throw NSError(
                domain: "captureStdout", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "no write handle on \(file.path)"])
        }
        let fd = FileHandle.standardOutput.fileDescriptor
        let saved = Darwin.dup(fd)
        Darwin.fflush(stdout)
        Darwin.dup2(out.fileDescriptor, fd)
        defer {
            Darwin.fflush(stdout)
            Darwin.dup2(saved, fd)
            Darwin.close(saved)
            try? out.close()
        }
        try body()
        Darwin.fflush(stdout)
        return try String(contentsOf: file, encoding: .utf8)
    }
}
