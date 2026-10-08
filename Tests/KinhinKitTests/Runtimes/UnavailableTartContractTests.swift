import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Contract for `UnavailableTart`, the stand-in a Linux-only fleet gets
/// instead of a tart controller: `list()` must read like an installed tart
/// with no VMs (so recovery enumerates nothing), and every operational call
/// must fail with the same `TartError.missingBinary` the real setup throws
/// when tart is absent — never a silent success that would let macOS work
/// route into a backend that cannot run it. The real side is
/// `KinhinConfig.makeTartControlling()` and a `TartController` against a
/// scripted `FakeShell`.
final class UnavailableTartContractTests: XCTestCase {
    // MARK: - Missing-binary parity

    func testTheErrorMatchesWhatTheRealSetupThrowsWhenTartIsAbsent() async {
        var cfg = makeTestConfig()
        XCTAssertFalse(cfg.hasLinuxRuntime, "this config must take the tart path, not the Linux stand-in")
        cfg.tartPath = "/no/such/tart"  // authoritative: the host's tart can't answer this probe
        var realError: Error?
        do {
            _ = try cfg.makeTartControlling()
        } catch {
            realError = error
        }

        var fakeError: Error?
        do {
            try await UnavailableTart().clone(source: "base", to: "vm-1")
        } catch {
            fakeError = error
        }

        guard let real = realError as? TartError, case .missingBinary = real else {
            return XCTFail(
                "the real setup must fail with TartError.missingBinary, got \(String(describing: realError))")
        }
        guard let fake = fakeError as? TartError, case .missingBinary = fake else {
            return XCTFail("the stand-in must fail with TartError.missingBinary, got \(String(describing: fakeError))")
        }
        // Same case and the same user-facing message family: to a user or the
        // CLI's error classifier, the stand-in's failure is the real "tart is
        // not installed" failure. (The paths differ — the stand-in has no
        // configured path — which is why only the message family is compared.)
        let realDescription = real.errorDescription ?? ""
        let fakeDescription = fake.errorDescription ?? ""
        XCTAssertTrue(realDescription.contains("tart not found"), realDescription)
        XCTAssertTrue(fakeDescription.contains("tart not found"), fakeDescription)
        XCTAssertTrue(fakeDescription.contains(TartHealthProbe.installCommand), fakeDescription)
    }

    func testALinuxOnlyConfigurationHandsOutTheStandIn() throws {
        var cfg = try ConfigLoader.parse(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: [a]
            docker:
              image: "kinhin-ci-linux"
            """)
        cfg.tartPath = "/no/such/tart"
        let tart = try cfg.makeTartControlling()
        XCTAssertTrue(
            tart is UnavailableTart,
            "the real selection path must produce the stand-in when tart is absent and a Linux runtime exists")
    }

    // MARK: - list()

    func testListReadsAsAnEmptyFleetLikeAnInstalledTartWithNoVMs() async throws {
        // Real side: an installed tart reporting no VMs parses to [].
        let shell = FakeShell()
        shell.scriptedResponses = [
            ScriptedResponse(
                whenContainsAll: ["list", "--format"],
                ShellResult(exitCode: 0, stdout: "[]", stderr: ""))
        ]
        let real = try TartController(configuredPath: "/bin/sh", shell: shell, softnet: false)
        let realRows = try await real.list()

        let standInRows = try await UnavailableTart().list()

        XCTAssertEqual(realRows, [], "no VMs is an empty list, not an error")
        XCTAssertEqual(standInRows, realRows, "recovery enumerates the stand-in exactly like an empty tart fleet")
    }

    // MARK: - Everything else

    func testEveryOperationalCallFailsWithTheMissingBinaryError() async {
        let tart = UnavailableTart()
        let operations: [(String, () async throws -> Void)] = [
            ("clone", { try await tart.clone(source: "base", to: "vm-1") }),
            ("run", { try await tart.run(name: "vm-1") }),
            ("run with mounts", { try await tart.run(name: "vm-1", mounts: ["docs:/srv/docs"]) }),
            ("ip", { _ = try await tart.ip(of: "vm-1", timeout: 1) }),
            ("stop", { try await tart.stop(name: "vm-1") }),
            ("delete", { try await tart.delete(name: "vm-1") }),
            ("pull", { try await tart.pull(image: "base") }),
            ("createLinux", { try await tart.createLinux(name: "vm-1") }),
            ("runWithDisk", { try await tart.runWithDisk(name: "vm-1", isoPath: "/tmp/install.iso") }),
        ]
        for (name, op) in operations {
            do {
                try await op()
                XCTFail("\(name) must fail like a missing tart binary, not answer as \"no VMs\"")
            } catch let error as TartError {
                guard case .missingBinary = error else {
                    XCTFail("\(name) threw the wrong TartError: \(error)")
                    continue
                }
            } catch {
                XCTFail("\(name) threw a non-TartError: \(error)")
            }
        }
    }
}
