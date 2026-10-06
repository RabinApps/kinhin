import Synchronization
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// A tiny stateful Docker: enough to watch create/delete round-trip. Lifecycle
/// verbs on a target it doesn't have fail with docker's own "No such …" stderr
/// instead of silently succeeding, so a stale list fails against the fake the
/// way it fails against the real CLI.
final class FakeDocker: ShellRunning, Sendable {
    private struct State: Sendable {
        var containers: [(id: String, image: String, state: String)] = [
            ("web", "nginx", "running"), ("kinhin-1", "runner", "exited"),
        ]
        var volumes = ["data"]
        var calls: [[String]] = []
        var failNext: String?

        mutating func handle(_ argv: [String]) -> ShellResult {
            calls.append(argv)
            let args = Array(argv.dropFirst())
            if let failure = failNext, args.first != "ps", args.first != "volume" || args[1] != "ls" {
                failNext = nil
                return ShellResult(exitCode: 1, stdout: "", stderr: failure)
            }
            switch args {
            case _ where args.first == "ps":
                let rows = containers.map {
                    "{\"ID\":\"\($0.id)\",\"Image\":\"\($0.image)\",\"Names\":\"\($0.id)\",\"State\":\"\($0.state)\",\"Status\":\"\($0.state)\"}"
                }
                return ShellResult(exitCode: 0, stdout: rows.joined(separator: "\n"), stderr: "")
            case ["volume", "ls", "--format", "{{json .}}"]:
                return ShellResult(
                    exitCode: 0,
                    stdout: volumes.map { "{\"Name\":\"\($0)\",\"Driver\":\"local\"}" }.joined(separator: "\n"),
                    stderr: "")
            case _ where ["start", "stop", "restart"].contains(args.first ?? ""):
                let target = args.dropFirst().first ?? ""
                guard let i = containers.firstIndex(where: { $0.id == target }) else {
                    return ShellResult(
                        exitCode: 1, stdout: "",
                        stderr: "Error response from daemon: No such container: \(target)\n")
                }
                containers[i].state = args.first == "stop" ? "exited" : "running"
            case _ where args.first == "rm":
                let target = args.last ?? ""
                guard containers.contains(where: { $0.id == target }) else {
                    return ShellResult(exitCode: 1, stdout: "", stderr: "Error: No such container: \(target)\n")
                }
                containers.removeAll { $0.id == target }
            case _ where args.starts(with: ["volume", "rm"]):
                let target = args.dropFirst(2).first ?? ""
                guard volumes.contains(target) else {
                    return ShellResult(
                        exitCode: 1, stdout: "",
                        stderr: "Error response from daemon: No such volume: \(target)\n")
                }
                volumes.removeAll { $0 == target }
            default: break
            }
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private let state = Mutex(State())

    var calls: [[String]] { state.withLock { $0.calls } }

    var failNext: String? {
        get { state.withLock { $0.failNext } }
        set { state.withLock { $0.failNext = newValue } }
    }

    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        state.withLock { $0.handle(argv) }
    }
}

@MainActor
final class ContainersModelTests: XCTestCase {
    private var docker: FakeDocker!
    private var controller: ContainersModel!
    private var confirmations: [(title: String, message: String)] = []
    private var answer = true

    override func setUp() async throws {
        docker = FakeDocker()
        controller = ContainersModel()
        controller.makeManager = { [docker] tool in
            ContainerManager(tool: tool, shell: docker!, binary: "/bin/\(tool.binaryName)")
        }
        controller.confirm = { [unowned self] title, message, _ in
            confirmations.append((title, message))
            return answer
        }
        await controller.reloadAndWait()
    }

    func testListsContainersAndVolumes() {
        XCTAssertEqual(controller.containers.map(\.name), ["web", "kinhin-1"])
        XCTAssertEqual(controller.volumes.map(\.name), ["data"])
    }

    func testDeleteAsksForConfirmationThenDeletes() async {
        await controller.deleteContainer(id: "kinhin-1")?.value
        XCTAssertEqual(confirmations.count, 1)
        XCTAssertTrue(confirmations[0].message.contains("CI runner"), "kinhin runner containers get an extra warning")
        XCTAssertEqual(controller.containers.map(\.name), ["web"])
    }

    func testDeletingARunningContainerWarnsAndForces() async {
        await controller.deleteContainer(id: "web")?.value
        XCTAssertTrue(confirmations[0].message.contains("running"))
        XCTAssertTrue(docker.calls.contains(["/bin/docker", "rm", "--force", "web"]))
    }

    func testCancellingTheConfirmationDeletesNothing() async {
        answer = false
        let task = controller.deleteContainer(id: "web")
        XCTAssertNil(task)
        XCTAssertNil(controller.deleteVolume(name: "data"))
        XCTAssertEqual(confirmations.count, 2, "both deletes asked first")
        XCTAssertFalse(docker.calls.contains { $0.contains("rm") })
        XCTAssertEqual(controller.containers.count, 2)
        XCTAssertEqual(controller.volumes.count, 1)
    }

    func testDeleteVolumeConfirmsThenDeletes() async {
        await controller.deleteVolume(name: "data")?.value
        XCTAssertTrue(confirmations[0].message.contains("data stored"), confirmations[0].message)
        XCTAssertTrue(controller.volumes.isEmpty)
    }

    func testStartStopRestart() async {
        await controller.startContainer(id: "kinhin-1")?.value
        XCTAssertEqual(controller.containers.first { $0.id == "kinhin-1" }?.state, "running")
        XCTAssertTrue(confirmations.isEmpty, "starting never needs confirmation")

        await controller.stopContainer(id: "web")?.value
        XCTAssertEqual(controller.containers.first { $0.id == "web" }?.state, "exited")
        XCTAssertTrue(confirmations.isEmpty, "ordinary containers stop without a prompt")

        await controller.restartContainer(id: "kinhin-1")?.value
        XCTAssertEqual(confirmations.count, 1, "restarting a kinhin runner asks first")
        XCTAssertTrue(docker.calls.contains(["/bin/docker", "restart", "kinhin-1"]))
    }

    func testStoppingARunnerCanBeCancelled() async {
        await controller.startContainer(id: "kinhin-1")?.value
        answer = false
        XCTAssertNil(controller.stopContainer(id: "kinhin-1"))
        XCTAssertEqual(controller.containers.first { $0.id == "kinhin-1" }?.state, "running")
    }

    func testRowsShowTheRightLifecycleButtons() {
        let web = controller.containers.first { $0.id == "web" }!  // running
        let runner = controller.containers.first { $0.id == "kinhin-1" }!  // exited
        XCTAssertEqual(controller.lifecycle(for: web), [.stop, .restart])
        XCTAssertEqual(controller.lifecycle(for: runner), [.start])
    }

    func testDeleteIsAcknowledged() async {
        await controller.deleteVolume(name: "data")?.value
        XCTAssertTrue(controller.status.text.contains("Deleted volume"), controller.status.text)
    }

    func testToolErrorsShowInline() async {
        docker.failNext = "volume is in use"
        await controller.deleteVolume(name: "data")?.value
        XCTAssertTrue(controller.status.text.contains("in use"), controller.status.text)
        XCTAssertEqual(controller.volumes.count, 1, "a failed delete leaves the volume listed")
    }
}
