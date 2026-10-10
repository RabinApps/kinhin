import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The user provision-script hook: `kinhin image prepare` runs a host-local
/// script inside the scratch VM (after the runner agents install) so
/// toolchains are baked into the base image once. Covers the pipeline shape,
/// early validation, failure isolation, and the config key.
final class ImageProvisionScriptTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-provision-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Writes content to a unique temp file and returns its path.
    private func writeScript(_ content: String) throws -> String {
        let url = scratch.appendingPathComponent("provision-\(UUID().uuidString).sh")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// Pulls the base64 payload out of the wrapper script's decode line.
    private func embeddedPayload(in script: String) throws -> String {
        for line in script.split(separator: "\n") where line.hasPrefix("echo ") && line.contains("base64 --decode") {
            for token in line.split(separator: " ") where token != "echo" {
                if let data = Data(base64Encoded: String(token)), let text = String(data: data, encoding: .utf8) {
                    return text
                }
            }
        }
        return ""
    }

    // MARK: - Pipeline shape

    func testProvisionScriptRunsAsSecondSSHExecAfterAgents() async throws {
        let content = """
            #!/bin/bash
            mise install go@1.23.4 java@temurin-21
            go version
            """
        let path = try writeScript(content)
        let tart = FakeTart()
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        var options = ImagePreparer.Options(
            storedTokens: [.github])
        options.provisionScriptPath = path

        try await preparer.run(options)

        // Probe (guest OS), agent install, user script, then the disk flush before the commit.
        XCTAssertEqual(ssh.scripts.count, 4, "guest probe, agent install, user script second, flush")
        XCTAssertEqual(ssh.scripts[3], "sync")
        XCTAssertTrue(ssh.scripts[0].contains("uname -s"), "first exec detects the guest OS")
        XCTAssertTrue(ssh.scripts[1].contains("actions-runner-osx-arm64"), "second exec bakes the GitHub agent")
        XCTAssertTrue(ssh.scripts[2].contains("bash /tmp/kinhin-provision.sh"), "third exec runs the user script")
        // The user script travels base64-embedded and must decode back exactly.
        let decoded = try embeddedPayload(in: ssh.scripts[2])
        XCTAssertEqual(decoded, content, "script content must reach the VM verbatim")
        // The user script gets its own (longer) timeout budget.
        XCTAssertEqual(ssh.timeouts[0], 60, "the guest probe is quick")
        XCTAssertEqual(ssh.timeouts[1], 900, "agent install keeps its 900 s budget")
        XCTAssertEqual(ssh.timeouts[2], 1800, "provision script defaults to a 1800 s budget")
    }

    func testProvisionTimeoutOptionIsHonored() async throws {
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: FakeTart(), ssh: ssh)
        var options = ImagePreparer.Options(
            storedTokens: [.github])
        options.provisionScriptPath = try writeScript("brew install wget")
        options.provisionTimeout = 60

        try await preparer.run(options)

        XCTAssertEqual(ssh.timeouts[2], 60)
    }

    func testNoProvisionScriptMeansSingleExec() async throws {
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: FakeTart(), ssh: ssh)
        _ = try await preparer.run(
            ImagePreparer.Options(
                storedTokens: [.github]))

        XCTAssertEqual(ssh.scripts.count, 3, "guest probe + agent install + disk flush")
        XCTAssertFalse(ssh.scripts[1].contains("kinhin-provision.sh"))
    }

    // MARK: - Early validation (before the multi-GB pull)

    func testMissingProvisionScriptFailsBeforeAnyTartWork() async {
        let tart = FakeTart()
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        var options = ImagePreparer.Options(
            storedTokens: [.github])
        options.provisionScriptPath = scratch.appendingPathComponent("does-not-exist.sh").path

        do {
            try await preparer.run(options)
            XCTFail("expected an unreadable-script error")
        } catch let error as ImageError {
            guard case .provisionScriptUnreadable(let path, let reason) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(path.hasSuffix("does-not-exist.sh"))
            XCTAssertFalse(reason.isEmpty, "the read failure's own cause is reported")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        // Nothing slow may have happened: no image pull, no clones, no SSH.
        XCTAssertTrue(tart.pullCalls.isEmpty)
        XCTAssertTrue(tart.cloneCalls.isEmpty)
        XCTAssertTrue(ssh.scripts.isEmpty)
    }

    func testWhitespaceOnlyProvisionScriptFailsBeforeAnyTartWork() async throws {
        let tart = FakeTart()
        let preparer = ImagePreparer(tart: tart, ssh: FakeSSH())
        var options = ImagePreparer.Options(
            storedTokens: [.github])
        options.provisionScriptPath = try writeScript("   \n\t\n")

        do {
            try await preparer.run(options)
            XCTFail("expected an empty-script error")
        } catch let error as ImageError {
            guard case .provisionScriptUnreadable(_, let reason) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(reason, "script is empty")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertTrue(tart.pullCalls.isEmpty)
    }

    // MARK: - Failure isolation

    func testFailingProvisionScriptAbortsBeforeTargetIsReplaced() async throws {
        let tart = FakeTart()
        tart.vms["tahoe-base"] = TartVM(name: "tahoe-base", source: "old-source", status: "stopped")
        let ssh = FakeSSH()
        ssh.failOnCall = 2  // the third exec: the user provision script (0 is the guest probe)
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        var options = ImagePreparer.Options(
            storedTokens: [.github])
        options.target = "tahoe-base"
        options.provisionScriptPath = try writeScript("exit 3")

        do {
            try await preparer.run(options)
            XCTFail("expected the prepare to fail")
        } catch let error as ImageError {
            guard case .provisioningFailed(let why) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(why.contains("user provision script failed"), "\(why)")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        // The previous image must be untouched: not deleted, not re-cloned.
        XCTAssertEqual(tart.vms["tahoe-base"]?.source, "old-source")
        XCTAssertFalse(tart.deleteCalls.contains("tahoe-base"))
        XCTAssertFalse(tart.cloneCalls.contains { $0.name == "tahoe-base" })
    }

    // MARK: - Helpers

    func testWrapperScriptDecodesRunsAndCleansUp() throws {
        let content = "echo baked"
        let wrapper = ImagePreparer.provisionWrapperScript(contentBase64: Data(content.utf8).base64EncodedString())
        XCTAssertTrue(wrapper.contains("set -euo pipefail"), "script failures must propagate")
        XCTAssertTrue(wrapper.contains("> /tmp/kinhin-provision.sh"))
        XCTAssertTrue(wrapper.contains("bash /tmp/kinhin-provision.sh"))
        XCTAssertTrue(wrapper.contains("rm -f /tmp/kinhin-provision.sh"), "temp file must not survive in the image")
        XCTAssertEqual(try embeddedPayload(in: wrapper), content)
    }

    func testTildeExpansion() {
        XCTAssertEqual(
            ImagePreparer.expandingTilde(in: "/absolute/path.sh"), "/absolute/path.sh", "plain paths pass through")
        XCTAssertEqual(ImagePreparer.expandingTilde(in: "relative.sh"), "relative.sh")
        let expanded = ImagePreparer.expandingTilde(in: "~/kinhin/provision.sh")
        XCTAssertNotEqual(expanded, "~/kinhin/provision.sh", "leading ~ must be expanded")
        XCTAssertTrue(expanded.hasSuffix("/kinhin/provision.sh"))
        XCTAssertEqual(ImagePreparer.expandingTilde(in: "~"), NSHomeDirectory())
    }

    func testResolveReturnsNilWithoutAPath() {
        XCTAssertNil(try? ImagePreparer.resolveProvisionScript(nil))
        XCTAssertNil(try? ImagePreparer.resolveProvisionScript("   "))
    }

    // MARK: - Config key

    func testConfigParsesProvisionScript() throws {
        let cfg = try ConfigLoader.parse(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["self-hosted"]
            provision_script: "~/kinhin/provision.sh"
            """)
        XCTAssertEqual(cfg.provisionScript, "~/kinhin/provision.sh")
    }

    func testConfigRejectsEmptyProvisionScript() {
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                accounts:
                  - name: github
                    forge: github
                    scope: "acme/widgets"
                labels: ["self-hosted"]
                provision_script: ""
                """), "an empty path must be rejected")
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                accounts:
                  - name: github
                    forge: github
                    scope: "acme/widgets"
                labels: ["self-hosted"]
                provision_script: "   "
                """), "a whitespace path must be rejected")
    }

    func testTemplateHasNoProvisionScript() throws {
        let cfg = try ConfigLoader.parse(ConfigLoader.template())
        XCTAssertNil(cfg.provisionScript, "the starter config must not bake a user script by default")
    }
}
