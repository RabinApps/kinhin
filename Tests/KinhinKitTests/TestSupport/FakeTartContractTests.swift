import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Contract for `FakeTart` as a `TartControlling`: for every case the fleet
/// tests rely on it must behave like the real `TartController` — the same
/// `TartError.commandFailed` failures, `list()` rows in exactly the shape the
/// real parser produces, mount pass-through, IPv4 answers the real controller
/// would accept, and tart's own state model (clone adds a VM, delete removes
/// it, and a missing VM says "does not exist" so `TartRuntime.vmIsGone`
/// classifies it). The real side runs `TartController` against a scripted
/// `FakeShell`; no tart binary or VM is ever launched.
final class FakeTartContractTests: XCTestCase {
    /// A real controller that never launches tart: `/bin/sh` satisfies the
    /// executable probe and the scripted shell answers every command.
    private func makeReal(_ shell: FakeShell) throws -> TartController {
        try TartController(configuredPath: "/bin/sh", shell: shell, softnet: false)
    }

    /// Asserts `op` fails with `TartError.commandFailed` — the case the engine
    /// classifies and `TartRuntime.vmIsGone` matches on.
    private func assertCommandFailed(
        _ op: () async throws -> Void, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await op()
            XCTFail(message, file: file, line: line)
        } catch let error as TartError {
            guard case .commandFailed = error else {
                XCTFail("expected TartError.commandFailed, got \(error)", file: file, line: line)
                return
            }
        } catch {
            XCTFail("expected a TartError, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Failures

    func testFailedCloneThrowsTheSameErrorTheRealControllerThrows() async throws {
        let realShell = FakeShell()
        realShell.failOn = "clone"
        let real = try makeReal(realShell)
        let fake = FakeTart()

        await assertCommandFailed(
            { try await real.clone(source: "base", to: "vm-1") },
            "the real controller reports a failing tart clone as TartError.commandFailed")
        fake.failNextClone = true
        await assertCommandFailed(
            { try await fake.clone(source: "base", to: "vm-1") },
            "the fake must throw the same error case the engine classifies")

        // Neither side stays poisoned: a clone tart accepts succeeds again, and
        // only the successful clone is recorded (`cloneCalls.count` is asserted
        // throughout the fleet tests).
        realShell.failOn = nil
        try await real.clone(source: "base", to: "vm-2")
        try await fake.clone(source: "base", to: "vm-2")
        XCTAssertEqual(fake.cloneCalls.count, 1)
        XCTAssertNotNil(fake.vms["vm-2"])
    }

    func testFailedListThrowsTheSameErrorTheRealControllerThrows() async throws {
        let realShell = FakeShell()
        realShell.failAll = "tart list exploded"
        let real = try makeReal(realShell)
        let fake = FakeTart()
        fake.failList = true

        await assertCommandFailed(
            { _ = try await real.list() },
            "a tart that cannot be asked for its VMs fails loudly on the real side")
        await assertCommandFailed(
            { _ = try await fake.list() },
            "failList must produce the same error — a failed list must never read as \"no VMs\"")

        fake.failList = false
        let rows = try await fake.list()
        XCTAssertEqual(rows, [], "without the failure the fleet lists empty")
    }

    // MARK: - list()

    func testListRowsMatchWhatTheRealParserProduces() async throws {
        let realShell = FakeShell()
        realShell.scriptedResponses = [
            ScriptedResponse(
                whenContainsAll: ["list", "--format"],
                ShellResult(
                    exitCode: 0,
                    stdout: #"[{"Name":"tahoe-1","Source":"base/image","State":"stopped","Disk":50,"Size":30}]"#,
                    stderr: ""))
        ]
        let real = try makeReal(realShell)
        let fake = FakeTart()
        fake.vms = ["tahoe-1": TartVM(name: "tahoe-1", source: "base/image", status: "stopped", diskGB: 30)]

        let realRows = try await real.list()
        let fakeRows = try await fake.list()

        XCTAssertEqual(
            fakeRows, realRows,
            "tests read name/source/status off list(); the fake reports them exactly like the parsed tart output")
        XCTAssertEqual(realRows.first?.diskGB, 30)
    }

    func testCloneAndDeleteKeepTheListInSyncLikeTartDoes() async throws {
        let realShell = FakeShell()
        func scriptList(_ json: String) {
            realShell.scriptedResponses = [
                ScriptedResponse(
                    whenContainsAll: ["list", "--format"],
                    ShellResult(exitCode: 0, stdout: json, stderr: ""))
            ]
        }
        // Tart's state model: clone makes the VM visible to `list`, delete takes
        // it away. The real side is scripted to answer with that model; the fake
        // must derive the same answers from its own state.
        scriptList(#"[{"Name":"vm-1","Source":"base","State":"running"}]"#)
        let real = try makeReal(realShell)
        let fake = FakeTart()

        try await real.clone(source: "base", to: "vm-1")
        try await fake.clone(source: "base", to: "vm-1")
        let realAfterClone = try await real.list()
        let fakeAfterClone = try await fake.list()
        XCTAssertEqual(fakeAfterClone, realAfterClone)

        scriptList("[]")
        try await real.delete(name: "vm-1")
        try await fake.delete(name: "vm-1")
        let realAfterDelete = try await real.list()
        let fakeAfterDelete = try await fake.list()
        XCTAssertEqual(fakeAfterDelete, realAfterDelete)
        XCTAssertEqual(fakeAfterDelete, [], "delete must take the VM out of the next list")
    }

    // MARK: - stop / ip / run

    func testStopOfAMissingVMFailsWithTartsDoesNotExistError() async throws {
        let realShell = FakeShell()
        realShell.scriptedResponses = [
            ScriptedResponse(
                whenContains: "stop",
                ShellResult(exitCode: 1, stdout: "", stderr: "the VM gone does not exist"))
        ]
        let real = try makeReal(realShell)
        let fake = FakeTart()
        fake.strictMissing = true

        // The wording matters: `TartRuntime.vmIsGone` classifies teardown by it.
        do {
            try await real.stop(name: "gone")
            XCTFail("the real controller must fail when tart reports a missing VM")
        } catch let error as TartError {
            guard case .commandFailed(_, let stderr) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(stderr.contains("does not exist"), stderr)
        }
        do {
            try await fake.stop(name: "gone")
            XCTFail("strictMissing must fail like tart, not record a stop that never happened")
        } catch let error as TartError {
            guard case .commandFailed(_, let stderr) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(stderr.contains("does not exist"), stderr)
        }
        XCTAssertEqual(fake.stopCalls, [])
    }

    func testIPPassesTheValidityCheckTheRealControllerApplies() async throws {
        let ip = try await FakeTart().ip(of: "vm-1", timeout: 1)
        XCTAssertTrue(
            TartController.isValidIPv4(ip),
            "the real controller only ever returns addresses that pass isValidIPv4; tests hand this IP to SSH")
    }

    func testRunRecordsExactlyTheMountsTheRealRunArgumentsShare() async throws {
        // Real side: every mount spec becomes tart's `--dir` argument unchanged.
        let args = TartController.runArguments(name: "vm-1", mounts: ["docs:/srv/docs"], softnet: false)
        XCTAssertEqual(Array(args.suffix(3)), ["--dir", "docs:/srv/docs", "vm-1"])

        let fake = FakeTart()
        try await fake.run(name: "vm-1", mounts: ["docs:/srv/docs"])
        try await fake.run(name: "vm-1")
        XCTAssertEqual(
            fake.runMounts, [["docs:/srv/docs"], []],
            "run(name:) must record the empty mount list the real default passes to run(name:mounts:)")
    }

    // MARK: - Guest-agent operations

    func testGuestExecFailuresThrowTheSameErrorTheRealControllerThrows() async throws {
        let realShell = FakeShell()
        realShell.failOn = "exec"
        let real = try makeReal(realShell)
        let fake = FakeTart()

        await assertCommandFailed(
            { try await real.hardenGuestSSH(vm: "vm-1") },
            "a failing `tart exec` surfaces as TartError.commandFailed on the real side")
        fake.failNext("harden", stderr: "refused")
        await assertCommandFailed(
            { try await fake.hardenGuestSSH(vm: "vm-1") },
            "the fake's fail hook must produce the same error case")
    }
}
