import Foundation
import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// A fleet that records what a benchmark does to it.
final class RecordingFleet: BenchmarkFleetControlling, Sendable {
    private struct State: Sendable {
        var impact: BenchmarkFleetImpact
        var pauses: [Bool] = []
        /// Busy counts to report on successive `impact()` calls before the steady one.
        var busyScript: [Int] = []
        var failPause = false
    }

    private let state: Mutex<State>

    init(active: Int = 0, busy: Int = 0, running: Bool = true, paused: Bool = false) {
        state = Mutex(State(impact: BenchmarkFleetImpact(active: active, busy: busy, running: running, paused: paused)))
    }

    var pauses: [Bool] { state.withLock { $0.pauses } }
    func scriptBusy(_ counts: [Int]) { state.withLock { $0.busyScript = counts } }

    func impact() async throws -> BenchmarkFleetImpact {
        state.withLock { state in
            var impact = state.impact
            if !state.busyScript.isEmpty { impact.busy = state.busyScript.removeFirst() }
            return impact
        }
    }

    func setPaused(_ paused: Bool) async throws {
        state.withLock { state in
            state.pauses.append(paused)
            state.impact.paused = paused
        }
    }
}

/// An environment over the shared fakes: tart, ssh, a docker-faking shell, a container-faking shell and a host
/// runtime on a temporary directory. Nothing touches the machine.
struct BenchHarness {
    let tart = FakeTart()
    let ssh = FakeSSH()
    let docker = DockerFakingShell()
    let container = ContainerFakingShell()
    let root: URL
    var config: KinhinConfig
    var unready: [RuntimeID: RuntimeHealth] = [:]
    var missingImages: Set<RuntimeID> = []

    init(softnet: Bool = false) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-bench-tests-\(UUID().uuidString)", isDirectory: true)
        var config = makeTestConfig()
        config.container = .init(image: "kinhin-ci-linux")
        config.docker = .init(image: "kinhin-ci-linux")
        config.tartSoftnet = softnet
        self.config = config
    }

    func makeEnvironment(fleet: BenchmarkFleetControlling? = nil, freeDiskGB: Int = 500) -> BenchmarkEnvironment {
        var env = BenchmarkEnvironment(
            config: config, tart: tart, ssh: ssh, shell: FakeShell(), root: root, fleet: fleet)
        let tart = self.tart
        let ssh = self.ssh
        let docker = self.docker
        let container = self.container
        let config = self.config
        let hostDirectory = root.appendingPathComponent("host-agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
        env.makeRuntime = { id, platform in
            switch id {
            case .tart:
                return TartRuntime(
                    tart: tart, bootTimeout: { config.vmBootTimeout }, ssh: ssh, sshReadyWindow: 2,
                    sshRetryInterval: .milliseconds(5), sshProbeInterval: .milliseconds(5), hostKeyWindow: 0,
                    hostKeyInterval: .milliseconds(5))
            case .docker:
                return DockerRuntime(
                    shell: docker, image: "kinhin-ci-linux", platform: platform ?? .arm64,
                    binPath: "/usr/local/bin/docker", exists: { _ in true })
            case .appleContainer:
                return AppleContainerRuntime(
                    shell: container, image: "kinhin-ci-linux", binPath: "/usr/local/bin/container",
                    exists: { _ in true })
            case .host:
                return HostRuntime(shell: FakeShell(), agentDir: hostDirectory)
            }
        }
        let unready = self.unready
        env.health = { id, _ in unready[id] ?? .ready }
        let missing = self.missingImages
        env.localImages = { id in
            if missing.contains(id) { return [] }
            return id == .tart ? [config.image] : ["kinhin-ci-linux:latest"]
        }
        env.hostResources = { HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: freeDiskGB, arm64: true) }
        env.hostInfo = { ("Test Chip", "Test OS") }
        env.probeInterval = .milliseconds(1)
        return env
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Bench instance names the fakes saw created.
    var clonedNames: [String] { tart.cloneCalls.map(\.name) }
}

extension BenchmarkReport {
    func suite(_ name: String, runtime: RuntimeID) -> BenchmarkSuiteResult? {
        suites.first { $0.name == name && $0.runtime == runtime.rawValue }
    }
}
