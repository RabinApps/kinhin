import XCTest

@testable import KinhinKit

final class MiscTests: XCTestCase {
    // MARK: tart list parsing

    func testTartListParsing() {
        let output = """
            tahoe-base\tghcr.io/cirruslabs/macos-tahoe-base:latest\trunning\t4\t8\t64
            kinhin-1717-abc\ttahoe-base\tsuspended\t2\t4\t64
            """
        let vms = TartController.parseList(output)
        XCTAssertEqual(vms.count, 2)
        XCTAssertEqual(vms[0].name, "tahoe-base")
        XCTAssertEqual(vms[0].status, "running")
        XCTAssertEqual(vms[0].cpu, 4)
        XCTAssertEqual(vms[1].memoryMB, 4096)
    }

    func testIPv4Validation() {
        XCTAssertTrue(TartController.isValidIPv4("192.168.64.3"))
        XCTAssertFalse(TartController.isValidIPv4("999.1.1.1"))
        XCTAssertFalse(TartController.isValidIPv4("abc"))
        XCTAssertFalse(TartController.isValidIPv4("1.2.3"))
    }

    // MARK: registration token cache

    func testTokenCacheFetchesOnceWhileFresh() async throws {
        let cache = RegistrationTokenCache(ttl: 3600, refreshMargin: 60)
        var fetches = 0
        _ = try await cache.token {
            fetches += 1
            return "t1"
        }
        _ = try await cache.token {
            fetches += 1
            return "t2"
        }
        XCTAssertEqual(fetches, 1)
    }

    func testTokenCacheRefetchesAfterInvalidation() async throws {
        let cache = RegistrationTokenCache(ttl: 3600, refreshMargin: 60)
        var fetches = 0
        _ = try await cache.token {
            fetches += 1; return "t1"
        }
        cache.invalidate()
        _ = try await cache.token {
            fetches += 1; return "t2"
        }
        XCTAssertEqual(fetches, 2)
    }

    // MARK: bootstrap scripts

    func testRegistrationScriptContainsEssentials() {
        let script = RunnerBootstrap.registrationScript(
            configureURL: "https://github.com/acme/widgets",
            token: "SECRET",
            labels: ["macos", "kinhin"],
            ephemeral: true,
            name: "kinhin-1"
        )
        XCTAssertTrue(script.contains("--url https://github.com/acme/widgets"))
        XCTAssertTrue(script.contains("SECRET"))
        XCTAssertTrue(script.contains("--labels 'macos,kinhin'"))
        XCTAssertTrue(script.contains("--name 'kinhin-1'"))
        XCTAssertTrue(script.contains("--ephemeral"))
        XCTAssertTrue(script.contains("./run.sh"))
    }

    func testNonEphemeralScriptOmitsFlag() {
        let script = RunnerBootstrap.registrationScript(
            configureURL: "https://github.com/a/b", token: "t", labels: ["x"], ephemeral: false, name: "n"
        )
        XCTAssertFalse(script.contains("--ephemeral"))
    }

    // MARK: many-to-one (runners_per_vm)

    func testMultiRunnerScriptRegistersNRunnersWithIndexedNames() {
        let script = RunnerBootstrap.registrationScript(
            configureURL: "https://github.com/acme/widgets",
            token: "SECRET",
            labels: ["macos"],
            ephemeral: true,
            name: "kinhin-9",
            runnerCount: 3
        )
        for index in 1...3 {
            XCTAssertTrue(script.contains("--name 'kinhin-9-r\(index)'"), "missing runner \(index) name")
            XCTAssertTrue(script.contains("cd ~/actions-runner-\(index)"), "missing runner \(index) dir")
            XCTAssertTrue(script.contains("--work _work-\(index)"), "missing runner \(index) work dir")
            XCTAssertTrue(script.contains("run-\(index).log"), "missing runner \(index) log")
        }
        // Three separate registrations (remove + register per runner), three
        // detached processes.
        XCTAssertEqual(script.components(separatedBy: "config.sh --url").count - 1, 3)
        XCTAssertEqual(script.components(separatedBy: "config.sh remove").count - 1, 3)
        XCTAssertEqual(script.components(separatedBy: "nohup ./run.sh").count - 1, 3)
        XCTAssertTrue(script.contains("3 runners started"))
        // Single-runner dir must NOT appear (it would collide with index 1's).
        XCTAssertTrue(script.contains("cd ~/actions-runner-1"))
        XCTAssertFalse(script.contains("cd ~/actions-runner\n"))
    }

    func testSingleRunnerScriptUnchangedByCountParameter() {
        let legacy = RunnerBootstrap.registrationScript(
            configureURL: "https://github.com/a/b", token: "t", labels: ["x"], ephemeral: true, name: "vm"
        )
        let explicit = RunnerBootstrap.registrationScript(
            configureURL: "https://github.com/a/b", token: "t", labels: ["x"], ephemeral: true, name: "vm",
            runnerCount: 1
        )
        XCTAssertEqual(legacy, explicit)
        XCTAssertFalse(legacy.contains("actions-runner-"))
    }

    func testInstallScriptPrecreatesAgentDirsForDensity() {
        let script = RunnerBootstrap.installScript(runnerVersion: "2.319.1", runnerCount: 2)
        XCTAssertTrue(script.contains("mkdir -p \"$HOME/actions-runner\""), "base agent dir")
        XCTAssertTrue(script.contains("mkdir -p \"$HOME/actions-runner-2\""), "second agent dir")
        XCTAssertEqual(script.components(separatedBy: "curl -sL").count - 1, 2, "one download per dir")
    }

    // MARK: RPC codec

    func testRPCRoundTrip() throws {
        let request = RPCRequest(id: 42, method: .status)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(RPCRequest.self, from: data)
        XCTAssertEqual(decoded, request)

        let response = RPCResponse(id: 42, ok: true, payload: Data("hi".utf8))
        let rdata = try JSONEncoder().encode(response)
        let rdecoded = try JSONDecoder().decode(RPCResponse.self, from: rdata)
        XCTAssertEqual(rdecoded, response)
    }

    // MARK: VM naming

    func testVMNamesAreUniqueAndPrefixed() {
        let names = Set((0..<50).map { _ in VMRecord.newName() })
        XCTAssertEqual(names.count, 50)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("kinhin-") })
    }
}
