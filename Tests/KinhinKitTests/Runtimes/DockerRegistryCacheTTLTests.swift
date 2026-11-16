import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The Docker Hub cache's proxy TTL (`container.registry_cache_ttl_hours`): created with the configured value, read
/// back from `container inspect`, a stopped cache with another TTL recreated, and a running one left alone until it
/// next starts.
final class DockerRegistryCacheTTLTests: XCTestCase {
    private let bin = "/usr/local/bin/container"
    private var dataDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("registry-ttl-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        dataDirectory = dir.appendingPathComponent("registry-cache", isDirectory: true)
    }

    private func cache(_ shell: ShellRunning, ttlHours: Int) -> DockerRegistryCache {
        DockerRegistryCache(
            shell: shell, binPath: bin, dataDirectory: dataDirectory, ttlHours: ttlHours, addressPolls: 3,
            pollInterval: .milliseconds(1))
    }

    /// `container inspect` as Apple container 1.6.1 prints it, trimmed, with the TTL the cache was created with.
    private static func inspected(_ state: String, ttl: String, address: String? = nil) -> ShellResult {
        let networks = address.map { #"[{"ipv4Address":"\#($0)/24","network":"default"}]"# } ?? "[]"
        let json = """
            [{"configuration":{"id":"registry-cache-kinhin","initProcess":{"executable":"/entrypoint.sh",
              "environment":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io","REGISTRY_PROXY_TTL=\(ttl)",
                "OTEL_TRACES_EXPORTER=none"]}},
              "id":"registry-cache-kinhin","status":{"state":"\(state)","networks":\(networks)}}]
            """
        return ShellResult(exitCode: 0, stdout: json, stderr: "")
    }

    private static let ok = ShellResult(exitCode: 0, stdout: "", stderr: "")

    private func verbs(_ shell: FakeShell) -> [String] {
        shell.calls.compactMap { $0.dropFirst().first }
    }

    func testTheTTLValueIsAGoDurationInHours() {
        XCTAssertEqual(DockerRegistryCache.ttlValue(hours: 336), "336h")
        XCTAssertEqual(DockerRegistryCache.ttlValue(hours: 0), "0h", "0 turns expiry off in registry:3")
        XCTAssertEqual(DockerRegistryCache.defaultTTLHours, 336)
    }

    func testTheRunArgumentsCarryTheConfiguredTTL() {
        let argv = DockerRegistryCache.runArguments(bin: bin, dataDirectory: dataDirectory, ttlHours: 0)
        XCTAssertTrue(argv.contains("REGISTRY_PROXY_TTL=0h"), "\(argv)")
        XCTAssertFalse(argv.contains("REGISTRY_PROXY_TTL=336h"))
    }

    func testInspectionReadsTheTTLFromTheInitProcess() throws {
        let inspection = try XCTUnwrap(
            DockerRegistryCache.parseInspection(Self.inspected("running", ttl: "336h", address: "192.168.64.3").stdout))
        XCTAssertEqual(inspection, .init(state: "running", address: "192.168.64.3", ttl: "336h"))
    }

    func testAMissingCacheIsCreatedWithTheConfiguredTTL() async throws {
        let shell = FakeShell()
        shell.responses = [
            ShellResult(exitCode: 1, stdout: "", stderr: "Error: container not found: registry-cache-kinhin"),
            Self.ok, Self.inspected("running", ttl: "720h", address: "192.168.64.4"),
        ]
        _ = try await cache(shell, ttlHours: 720).address()
        XCTAssertEqual(verbs(shell), ["inspect", "run", "inspect"])
        XCTAssertTrue(shell.calls[1].contains("REGISTRY_PROXY_TTL=720h"), "\(shell.calls[1])")
    }

    func testARunningCacheWithAnotherTTLIsAdoptedNotReplaced() async throws {
        // Replacing it would cut off pulls in flight on other runners; the change waits for the next start.
        let shell = FakeShell()
        shell.responses = [Self.inspected("running", ttl: "336h", address: "192.168.64.7")]
        let address = try await cache(shell, ttlHours: 0).address()
        XCTAssertEqual(address, "192.168.64.7")
        XCTAssertEqual(verbs(shell), ["inspect"])
    }

    func testAStoppedCacheWithAnotherTTLIsRecreated() async throws {
        let shell = FakeShell()
        shell.responses = [
            Self.inspected("stopped", ttl: "336h"), Self.ok, Self.ok,
            Self.inspected("running", ttl: "0h", address: "192.168.64.9"),
        ]
        let address = try await cache(shell, ttlHours: 0).address()
        XCTAssertEqual(address, "192.168.64.9")
        XCTAssertEqual(verbs(shell), ["inspect", "delete", "run", "inspect"])
        XCTAssertEqual(shell.calls[1], [bin, "delete", "registry-cache-kinhin"])
        XCTAssertTrue(shell.calls[2].contains("REGISTRY_PROXY_TTL=0h"))
    }

    func testAStoppedCacheWithTheSameTTLIsOnlyStarted() async throws {
        let shell = FakeShell()
        shell.responses = [
            Self.inspected("stopped", ttl: "336h"), Self.ok,
            Self.inspected("running", ttl: "336h", address: "10.0.0.2"),
        ]
        _ = try await cache(shell, ttlHours: 336).address()
        XCTAssertEqual(verbs(shell), ["inspect", "start", "inspect"])
    }

    func testACacheThatShowsNoEnvironmentIsAdoptedAsItIs() async throws {
        let shell = FakeShell()
        shell.responses = [
            ShellResult(exitCode: 0, stdout: #"[{"status":{"state":"stopped","networks":[]}}]"#, stderr: ""),
            Self.ok, Self.inspected("running", ttl: "336h", address: "10.0.0.3"),
        ]
        _ = try await cache(shell, ttlHours: 0).address()
        XCTAssertEqual(verbs(shell), ["inspect", "start", "inspect"], "an unknown TTL is no reason to recreate")
    }

    func testStatusShowsTheRunningAndTheConfiguredTTL() async {
        let shell = FakeShell()
        shell.responses = [Self.inspected("running", ttl: "336h", address: "192.168.64.3")]
        let status = await cache(shell, ttlHours: 0).status()
        XCTAssertEqual(status.ttl, "336h")
        XCTAssertEqual(status.wantedTTL, "0h")
    }
}
