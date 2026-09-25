import XCTest

@testable import KinhinKit

final class SubsystemTests: XCTestCase {
    // MARK: SSHExecutor argv shaping

    func testSSHArgvCarriesBase64ScriptAndTarget() async throws {
        let shell = RecordingShell()
        let ssh = SSHExecutor(shell: shell, user: "admin")
        let script = "echo hello && uname -m"
        _ = try await ssh.exec(vm: "kinhin-x", user: "admin", ip: "192.168.64.5", script: script, timeout: 60)

        let argv = try XCTUnwrap(shell.argvs.first)
        XCTAssertEqual(argv.first, "ssh")
        XCTAssertTrue(argv.contains("-o"), "ssh hardening options must be present")
        XCTAssertTrue(argv.contains("StrictHostKeyChecking=no"))
        XCTAssertTrue(argv.contains("BatchMode=yes"))
        // Target is user@ip as the second-to-last element; the remote command is last.
        XCTAssertEqual(argv[argv.count - 2], "admin@192.168.64.5")
        let remote = try XCTUnwrap(argv.last)
        XCTAssertTrue(remote.contains("| base64 --decode | bash -s"))
        // The embedded base64 payload must decode back to the exact script.
        let parts = remote.split(separator: " ")
        let b64 = try XCTUnwrap(parts.dropFirst().first)
        let decoded = String(decoding: try XCTUnwrap(Data(base64Encoded: String(b64))), as: UTF8.self)
        XCTAssertEqual(decoded, script)
    }

    // MARK: ImagePreparer pipeline

    func testImagePrepareHappyPath() async throws {
        let tart = FakeTart()
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        var options = ImagePreparer.Options(hasGitHubToken: true, hasGiteaToken: false)
        options.source = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
        options.target = "tahoe-base"

        try await preparer.run(options)

        XCTAssertEqual(tart.pullCalls, ["ghcr.io/cirruslabs/macos-tahoe-base:latest"])
        // First clone: source -> scratch; last clone: scratch -> target.
        XCTAssertEqual(tart.cloneCalls.first?.source, options.source)
        XCTAssertEqual(tart.cloneCalls.last?.name, options.target)
        let scratch = try XCTUnwrap(tart.cloneCalls.first?.name)
        XCTAssertNotEqual(scratch, options.target, "scratch VM must differ from the target")
        // The final clone sources from the scratch VM.
        XCTAssertEqual(tart.cloneCalls.last?.source, scratch)
        XCTAssertEqual(tart.vms[options.target]?.source, scratch)
    }

    func testImagePrepareReplacesExistingTarget() async throws {
        let tart = FakeTart()
        tart.vms["tahoe-base"] = TartVM(name: "tahoe-base", source: "old-source", status: "stopped")
        let preparer = ImagePreparer(tart: tart, ssh: FakeSSH())
        var options = ImagePreparer.Options(hasGitHubToken: true, hasGiteaToken: false)
        options.target = "tahoe-base"

        try await preparer.run(options)

        XCTAssertTrue(tart.deleteCalls.contains("tahoe-base"), "old image is deleted before the new one lands")
        // The final clone targeted the same name and sourced from the scratch VM.
        XCTAssertEqual(tart.cloneCalls.last?.name, "tahoe-base")
        let scratch = try XCTUnwrap(tart.cloneCalls.first?.name)
        XCTAssertEqual(tart.vms["tahoe-base"]?.source, scratch, "target now sources from the fresh scratch clone")
    }

    func testImagePrepareProvisioningFailureLeavesTargetUntouched() async throws {
        let tart = FakeTart()
        let ssh = FakeSSH()
        ssh.failWith = "sudo: a password is required"
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        var options = ImagePreparer.Options(hasGitHubToken: true, hasGiteaToken: false)
        options.target = "tahoe-base"

        do {
            try await preparer.run(options)
            XCTFail("expected provisioning failure")
        } catch let error as ImageError {
            guard case .provisioningFailed(let why) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(why.contains("password"))
        }
        // The target must NOT have been created from the failed scratch VM.
        XCTAssertNil(tart.vms["tahoe-base"])
        XCTAssertFalse(tart.deleteCalls.contains("tahoe-base"))
        XCTAssertFalse(tart.cloneCalls.contains { $0.name == "tahoe-base" })
    }

    // MARK: Daemon RPC dispatch

    func makeEngine(tart: FakeTart, github: FakeGitHub, ssh: FakeSSH) -> FleetEngine {
        FleetEngine(
            config: makeTestConfig(),
            github: github,
            tart: tart,
            store: makeTestStore(),
            ssh: ssh,
            host: testHost
        )
    }

    func testDaemonPingAndStatus() async throws {
        let engine = makeEngine(tart: FakeTart(), github: FakeGitHub(), ssh: FakeSSH())
        let ping = await Daemon.handle(RPCRequest(id: 1, method: .ping), engine: engine)
        XCTAssertTrue(ping.ok)
        let pong = try JSONDecoder().decode([String: Bool].self, from: XCTUnwrap(ping.payload))
        XCTAssertEqual(pong["pong"], true)

        let status = await Daemon.handle(RPCRequest(id: 2, method: .status), engine: engine)
        XCTAssertTrue(status.ok)
        let fleet = try JSONDecoder().decode(FleetStatus.self, from: XCTUnwrap(status.payload))
        XCTAssertEqual(fleet.desired, 0)
        XCTAssertFalse(fleet.running)
    }

    func testDaemonDeleteVMRemovesRecordAndTartVM() async throws {
        let tart = FakeTart()
        let engine = makeEngine(tart: tart, github: FakeGitHub(), ssh: FakeSSH())
        engine.store.upsert(VMRecord(id: "kinhin-die", phase: .ready))
        tart.vms["kinhin-die"] = TartVM(name: "kinhin-die", source: "tahoe-base", status: "running")

        let payload = try JSONEncoder().encode(Daemon.VMDeleteRequest(id: "kinhin-die"))
        let response = await Daemon.handle(RPCRequest(id: 3, method: .deleteVM, payload: payload), engine: engine)
        XCTAssertTrue(response.ok)

        let status = await engine.status()
        XCTAssertTrue(status.records.isEmpty)
        XCTAssertTrue(tart.deleteCalls.contains("kinhin-die"))
    }

    func testDaemonDeleteVMBadPayloadIsRejected() async throws {
        let engine = makeEngine(tart: FakeTart(), github: FakeGitHub(), ssh: FakeSSH())
        let bad = try JSONEncoder().encode(["wrong": "shape"])
        let response = await Daemon.handle(RPCRequest(id: 4, method: .deleteVM, payload: bad), engine: engine)
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("expected") == true)
    }

    func testDaemonPauseResumeRoundTrip() async throws {
        let engine = makeEngine(tart: FakeTart(), github: FakeGitHub(), ssh: FakeSSH())
        let pauseResponse = await Daemon.handle(RPCRequest(id: 5, method: .pause), engine: engine)
        XCTAssertTrue(pauseResponse.ok)
        var status = await engine.status()
        XCTAssertTrue(status.paused)
        let resumeResponse = await Daemon.handle(RPCRequest(id: 6, method: .resume), engine: engine)
        XCTAssertTrue(resumeResponse.ok)
        status = await engine.status()
        XCTAssertFalse(status.paused)
    }

    // MARK: RPC wire framing (real socketpair, no network stack)

    func testRequestResponseFramingOverSocketpair() async throws {
        var fds: [Int32] = [0, 0]
        let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        XCTAssertEqual(rc, 0, "socketpair must succeed")
        // handleConnection closes its own fd (fds[1]) on return; only close ours.
        defer { close(fds[0]) }

        // Write a request line to one end.
        let request = RPCRequest(id: 7, method: .ping)
        var line = try JSONEncoder().encode(request)
        line.append(0x0A)
        let writer = FileHandle(fileDescriptor: fds[0], closeOnDealloc: false)
        try writer.write(contentsOf: line)

        // Serve it on the other end (blocking, returns after responding).
        RPCServer.handleConnection(fd: fds[1]) { req in
            RPCResponse(id: req.id, ok: true, payload: try! JSONEncoder().encode(["pong": true]))
        }

        // Read the framed response back.
        let reader = FileHandle(fileDescriptor: fds[0], closeOnDealloc: false)
        var buffer = Data()
        while buffer.last != 0x0A {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        let response = try JSONDecoder().decode(RPCResponse.self, from: buffer)
        XCTAssertEqual(response.id, 7)
        XCTAssertTrue(response.ok)
        let pong = try JSONDecoder().decode([String: Bool].self, from: XCTUnwrap(response.payload))
        XCTAssertEqual(pong["pong"], true)
    }

    func testResponseLineIsNewlineFramedJSON() throws {
        let data = RPCServer.responseLine(RPCResponse(id: 9, ok: false, error: "boom"))
        XCTAssertEqual(data.last, 0x0A)
        let decoded = try JSONDecoder().decode(RPCResponse.self, from: data.dropLast())
        XCTAssertEqual(decoded.error, "boom")
        XCTAssertFalse(decoded.ok)
    }

    // MARK: Shell (real subprocess behavior)

    func testShellCapturesStdout() async throws {
        let result = try await Shell().run(["/bin/echo", "kinhin-test-123"], cwd: nil, timeout: 10)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("kinhin-test-123"))
    }

    func testShellCapturesStderrAndExitCode() async throws {
        let result = try await Shell().run(["/bin/sh", "-c", "echo oops >&2; exit 3"], cwd: nil, timeout: 10)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.stderr.contains("oops"))
    }

    func testShellTimeoutReturns124() async throws {
        let result = try await Shell().run(["/bin/sleep", "5"], cwd: nil, timeout: 0.5)
        XCTAssertEqual(result.exitCode, 124, "watchdog must mark timed-out processes")
    }

    func testShellLaunchFailureThrows() async {
        do {
            _ = try await Shell().run(["/nonexistent/binary-xyz"], cwd: nil, timeout: 5)
            XCTFail("expected launch failure")
        } catch let error as ShellError {
            guard case .launchFailed = error else { return XCTFail("wrong error") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: ResourceProbe sanity (live host)

    func testResourceProbeReturnsSaneHostData() {
        let host = ResourceProbe().snapshot()
        XCTAssertGreaterThan(host.logicalCores, 0)
        XCTAssertGreaterThan(host.memoryGB, 0)
        XCTAssertGreaterThanOrEqual(host.freeDiskGB, 0)
        #if arch(arm64)
            XCTAssertTrue(host.arm64)
        #endif
    }
}
