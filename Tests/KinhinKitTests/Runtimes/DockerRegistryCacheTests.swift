import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The Docker Hub cache container: a running one is adopted, a stopped one started, a missing one created with its
/// data bind-mounted, concurrent callers share one start, and `container inspect` is read the way the CLI prints it.
final class DockerRegistryCacheTests: XCTestCase {
    private let bin = "/usr/local/bin/container"
    private var dataDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("registry-cache-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        dataDirectory = dir.appendingPathComponent("registry-cache", isDirectory: true)
    }

    private func cache(_ shell: ShellRunning, polls: Int = 5) -> DockerRegistryCache {
        DockerRegistryCache(
            shell: shell, binPath: bin, dataDirectory: dataDirectory, addressPolls: polls,
            pollInterval: .milliseconds(1))
    }

    private static func inspected(_ state: String, address: String? = nil) -> ShellResult {
        let networks = address.map { #"[{"ipv4Address":"\#($0)/24","network":"default"}]"# } ?? "[]"
        let json = #"[{"id":"registry-cache-kinhin","status":{"state":"\#(state)","networks":\#(networks)}}]"#
        return ShellResult(exitCode: 0, stdout: json, stderr: "")
    }

    private static let notFound = ShellResult(
        exitCode: 1, stdout: "", stderr: "Error: container not found: registry-cache-kinhin")
    private static let ok = ShellResult(exitCode: 0, stdout: "", stderr: "")

    private func verbs(_ shell: FakeShell) -> [String] {
        shell.calls.compactMap { $0.dropFirst().first }
    }

    // MARK: - Adopting, starting, creating

    func testARunningCacheIsAdoptedAsItIs() async throws {
        let shell = FakeShell()
        shell.responses = [Self.inspected("running", address: "192.168.64.7")]
        let address = try await cache(shell).address()
        XCTAssertEqual(address, "192.168.64.7")
        XCTAssertEqual(shell.calls, [[bin, "inspect", "registry-cache-kinhin"]], "nothing is started or replaced")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataDirectory.path), "an adopted cache keeps its mount")
    }

    func testAStoppedCacheIsStartedAndAskedForItsNewAddress() async throws {
        let shell = FakeShell()
        shell.responses = [Self.inspected("stopped"), Self.ok, Self.inspected("running", address: "192.168.64.9")]
        let address = try await cache(shell).address()
        XCTAssertEqual(address, "192.168.64.9")
        XCTAssertEqual(verbs(shell), ["inspect", "start", "inspect"])
        XCTAssertEqual(shell.calls[1], [bin, "start", "registry-cache-kinhin"])
    }

    func testAMissingCacheIsCreatedWithItsDataDirectory() async throws {
        let shell = FakeShell()
        shell.responses = [Self.notFound, Self.ok, Self.inspected("running", address: "192.168.64.4")]
        let address = try await cache(shell).address()
        XCTAssertEqual(address, "192.168.64.4")
        XCTAssertEqual(verbs(shell), ["inspect", "run", "inspect"])
        XCTAssertEqual(shell.calls[1], DockerRegistryCache.runArguments(bin: bin, dataDirectory: dataDirectory))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "the bind mount's host side exists before the run")
    }

    func testTheRunArgumentsMakeAPullThroughCacheOfDockerHub() {
        let data = URL(fileURLWithPath: "/Users/me/Library/Application Support/Kinhin/registry-cache")
        XCTAssertEqual(
            DockerRegistryCache.runArguments(bin: bin, dataDirectory: data),
            [
                bin, "run", "--detach", "--name", "registry-cache-kinhin", "--cpus", "1", "--memory", "1024M",
                "--volume", "/Users/me/Library/Application Support/Kinhin/registry-cache:/var/lib/registry",
                "--env", "REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io",
                "--env", "REGISTRY_PROXY_TTL=336h",
                "registry:3",
            ])
        XCTAssertFalse(
            DockerRegistryCache.runArguments(bin: bin, dataDirectory: data).contains("--rm"),
            "a cache stopped with the host keeps its container, to be started again")
    }

    func testTheDefaultDataDirectoryIsInTheSupportDirectory() {
        // Paths, not URLs: a URL to a directory that exists on this Mac gains a trailing slash.
        XCTAssertEqual(
            DockerRegistryCache.defaultDataDirectory.path,
            Paths.appSupport.appendingPathComponent("registry-cache").path)
    }

    func testACacheSomeoneElseCreatedFirstIsAdopted() async throws {
        let shell = FakeShell()
        shell.responses = [
            Self.notFound, ShellResult(exitCode: 1, stdout: "", stderr: "container already exists"),
        ]
        shell.scriptedResponses = [
            ScriptedResponse(whenContains: "inspect", Self.inspected("running", address: "192.168.64.5"))
        ]
        let address = try await cache(shell).address()
        XCTAssertEqual(address, "192.168.64.5")
        XCTAssertFalse(verbs(shell).contains("start"), "it was running, so it is only adopted")
    }

    func testAStartedCacheIsAskedAgainUntilItHasAnAddress() async throws {
        let shell = FakeShell()
        shell.responses = [Self.notFound, Self.ok, Self.inspected("running"), Self.inspected("running")]
        shell.scriptedResponses = [
            ScriptedResponse(whenContains: "inspect", Self.inspected("running", address: "192.168.64.6"))
        ]
        let address = try await cache(shell).address()
        XCTAssertEqual(address, "192.168.64.6")
        XCTAssertEqual(verbs(shell), ["inspect", "run", "inspect", "inspect", "inspect"])
    }

    func testACacheThatNeverGetsAnAddressThrows() async {
        let shell = FakeShell()
        shell.responses = [Self.notFound, Self.ok]
        shell.scriptedResponses = [ScriptedResponse(whenContains: "inspect", Self.inspected("running"))]
        do {
            _ = try await cache(shell, polls: 3).address()
            XCTFail("expected an error")
        } catch let error as ContainerManagerError {
            XCTAssertEqual(error, .registryCache("it has no IPv4 address"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAFailedRunThrows() async {
        let shell = FakeShell()
        shell.responses = [Self.notFound, ShellResult(exitCode: 1, stdout: "", stderr: "pull access denied")]
        shell.scriptedResponses = [ScriptedResponse(whenContains: "inspect", Self.notFound)]
        do {
            _ = try await cache(shell).address()
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("pull access denied"), error.localizedDescription)
        }
    }

    func testAFailedInspectThrowsInsteadOfStartingASecondCache() async {
        let shell = FakeShell()
        shell.responses = [ShellResult(exitCode: 1, stdout: "", stderr: "XPC connection error")]
        do {
            _ = try await cache(shell).address()
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("XPC connection error"), error.localizedDescription)
        }
        XCTAssertEqual(verbs(shell), ["inspect"], "an unknown state is never read as missing")
    }

    func testConcurrentCallersShareOneStart() async throws {
        let shell = ContainerFakingShell()
        let cache = cache(shell)
        let addresses = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await cache.address() } }
            var all: [String] = []
            for try await address in group { all.append(address) }
            return all
        }
        XCTAssertEqual(Set(addresses), ["192.168.64.2"])
        let runs = shell.argvSnapshot().filter { $0.dropFirst().first == "run" }
        XCTAssertEqual(runs.count, 1, "one cache container, however many runners asked at once: \(runs)")
    }

    // MARK: - A deadline for registration

    func testAStartWithinTheDeadlineAnswers() async throws {
        let address = try await cache(ContainerFakingShell()).address(waitingAtMost: .seconds(30))
        XCTAssertEqual(address, "192.168.64.2")
    }

    func testASlowStartIsLeftAtTheDeadlineAndFinishesForTheNextCaller() async throws {
        let gate = RunGate()
        let shell = GatedRunShell(gate: gate)
        let cache = cache(shell)
        let first = try await cache.address(waitingAtMost: .milliseconds(50))
        XCTAssertNil(first, "the runner registers without the cache instead of waiting for the pull")
        await gate.open()
        let later = try await cache.address()
        XCTAssertEqual(later, "192.168.64.2", "the start went on in the background")
        let runs = shell.inner.argvSnapshot().filter { $0.dropFirst().first == "run" }
        XCTAssertEqual(runs.count, 1, "the later caller joined the same start: \(runs)")
    }

    func testAStartThatFailsWithinTheDeadlineStillThrows() async {
        let shell = FakeShell()
        shell.responses = [Self.notFound, ShellResult(exitCode: 1, stdout: "", stderr: "pull access denied")]
        shell.scriptedResponses = [ScriptedResponse(whenContains: "inspect", Self.notFound)]
        do {
            _ = try await cache(shell).address(waitingAtMost: .seconds(30))
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("pull access denied"), error.localizedDescription)
        }
    }

    func testTheMirrorURLUsesTheRegistryPort() {
        XCTAssertEqual(DockerRegistryCache.mirrorURL(address: "192.168.64.3"), "http://192.168.64.3:5000")
    }

    // MARK: - Reading `container inspect`

    func testInspectionReadsTheCLIsJSON() throws {
        // Trimmed from `container inspect` (Apple container 1.6.1).
        let text = """
            [{"configuration":{"id":"registry-cache-kinhin","image":{"reference":"docker.io/library/registry:3"}},
              "id":"registry-cache-kinhin",
              "status":{"networks":[{"hostname":"registry-cache-kinhin","ipv4Address":"192.168.64.3/24",
                "ipv4Gateway":"192.168.64.1","network":"default"}],"startedDate":"2026-11-02T00:42:08Z",
                "state":"running"}}]
            """
        let inspection = try XCTUnwrap(DockerRegistryCache.parseInspection(text))
        XCTAssertEqual(inspection, .init(state: "running", address: "192.168.64.3"))
        XCTAssertTrue(inspection.isRunning)
    }

    func testAStoppedContainerHasNoAddress() throws {
        let stopped = try XCTUnwrap(
            DockerRegistryCache.parseInspection(#"[{"status":{"state":"stopped","networks":[]}}]"#))
        XCTAssertEqual(stopped, .init(state: "stopped", address: nil))
        let bare = try XCTUnwrap(DockerRegistryCache.parseInspection(#"[{"status":{"state":"stopped"}}]"#))
        XCTAssertNil(bare.address)
    }

    func testAnEmptyListIsNoContainer() throws {
        XCTAssertNil(try DockerRegistryCache.parseInspection("[]"))
    }

    func testUnreadableOutputThrows() {
        for text in ["", "not json", #"{"status":{}}"#, #"[{"id":"x"}]"#] {
            XCTAssertThrowsError(try DockerRegistryCache.parseInspection(text), text)
        }
    }

    func testAMissingContainerReadsAsNone() async throws {
        let shell = FakeShell()
        shell.responses = [Self.notFound]
        let inspection = try await cache(shell).inspect()
        XCTAssertNil(inspection)
    }

    // MARK: - Status (doctor)

    func testStatusReportsARunningCacheWithoutStartingAnything() async throws {
        try FileManager.default.createDirectory(
            at: dataDirectory.appendingPathComponent("docker/registry", isDirectory: true),
            withIntermediateDirectories: true)
        try Data(repeating: 7, count: 10_000).write(to: dataDirectory.appendingPathComponent("docker/registry/blob"))
        let shell = FakeShell()
        shell.responses = [Self.inspected("running", address: "192.168.64.3")]
        let status = await cache(shell).status()
        XCTAssertTrue(status.exists)
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.address, "192.168.64.3:5000")
        XCTAssertGreaterThanOrEqual(status.dataBytes ?? 0, 10_000)
        XCTAssertEqual(status.dataDirectory, dataDirectory.path)
        XCTAssertNil(status.problem)
        XCTAssertEqual(verbs(shell), ["inspect"])
    }

    func testStatusOfAMissingOrStoppedCache() async {
        let missing = FakeShell()
        missing.responses = [Self.notFound]
        let none = await cache(missing).status()
        XCTAssertFalse(none.exists)
        XCTAssertFalse(none.running)
        XCTAssertNil(none.dataBytes, "no data directory yet")
        XCTAssertEqual(missing.calls.count, 1, "status never starts the cache")

        let stopped = FakeShell()
        stopped.responses = [Self.inspected("stopped")]
        let down = await cache(stopped).status()
        XCTAssertTrue(down.exists)
        XCTAssertFalse(down.running)
        XCTAssertNil(down.address)
    }

    func testStatusSaysWhyTheCacheCouldNotBeRead() async {
        let shell = FakeShell()
        shell.responses = [ShellResult(exitCode: 1, stdout: "", stderr: "XPC connection error")]
        let status = await cache(shell).status()
        XCTAssertFalse(status.running)
        XCTAssertTrue(status.problem?.contains("XPC connection error") == true, status.problem ?? "")
    }
}

/// Holds `container run` (the cache's first start) until the test opens it.
private actor RunGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// A `ContainerFakingShell` whose `container run` waits at `gate`, like a first pull of `registry:3`.
private final class GatedRunShell: ShellRunning, Sendable {
    let inner = ContainerFakingShell()
    let gate: RunGate

    init(gate: RunGate) { self.gate = gate }

    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        if argv.dropFirst().first == "run" { await gate.wait() }
        return try await inner.run(argv, cwd: cwd, timeout: timeout)
    }

    func run(_ argv: [String], input: Data, cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        try await inner.run(argv, input: input, cwd: cwd, timeout: timeout)
    }
}
