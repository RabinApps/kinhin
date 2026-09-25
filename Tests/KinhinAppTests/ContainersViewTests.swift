import AppKit
import KinhinKit
import XCTest

@testable import kinhin_app

/// A tiny stateful Docker: enough to watch create/delete round-trip.
private final class FakeDocker: ShellRunning, @unchecked Sendable {
    private let lock = NSLock()
    var containers: [(id: String, image: String, state: String)] = [
        ("web", "nginx", "running"), ("kinhin-1", "runner", "exited"),
    ]
    var volumes = ["data"]
    var calls: [[String]] = []
    var failNext: String?

    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        lock.lock(); defer { lock.unlock() }
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
                stdout: volumes.map { "{\"Name\":\"\($0)\",\"Driver\":\"local\"}" }.joined(separator: "\n"), stderr: "")
        case _ where args.first == "start":
            if let i = containers.firstIndex(where: { $0.id == args[1] }) { containers[i].state = "running" }
        case _ where args.first == "stop":
            if let i = containers.firstIndex(where: { $0.id == args[1] }) { containers[i].state = "exited" }
        case _ where args.first == "restart":
            if let i = containers.firstIndex(where: { $0.id == args[1] }) { containers[i].state = "running" }
        case _ where args.first == "rm":
            containers.removeAll { $0.id == args.last }
        case _ where args.starts(with: ["volume", "rm"]):
            volumes.removeAll { $0 == args[2] }
        default: break
        }
        return ShellResult(exitCode: 0, stdout: "", stderr: "")
    }
}

@MainActor
final class ContainersViewTests: XCTestCase {
    private var docker: FakeDocker!
    private var controller: ContainersViewController!
    private var confirmations: [(title: String, message: String)] = []
    private var answer = true

    override func setUp() async throws {
        docker = FakeDocker()
        controller = ContainersViewController()
        controller.makeManager = { [docker] tool in
            ContainerManager(tool: tool, shell: docker!, binary: "/bin/\(tool.binaryName)")
        }
        controller.confirm = { [unowned self] title, message, _ in
            confirmations.append((title, message))
            return answer
        }
        _ = controller.view
        await controller.reloadAndWait()
    }

    func testListsContainersAndVolumes() {
        XCTAssertEqual(controller.containersForTesting.map(\.name), ["web", "kinhin-1"])
        XCTAssertEqual(controller.volumesForTesting.map(\.name), ["data"])
        let text = allText()
        XCTAssertTrue(text.contains("web"))
        XCTAssertTrue(text.contains("data"))
    }

    func testDeleteAsksForConfirmationThenDeletes() async {
        await controller.deleteContainer(id: "kinhin-1")?.value
        XCTAssertEqual(confirmations.count, 1)
        XCTAssertTrue(confirmations[0].message.contains("CI runner"), "kinhin runner containers get an extra warning")
        XCTAssertEqual(controller.containersForTesting.map(\.name), ["web"])
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
        XCTAssertEqual(controller.containersForTesting.count, 2)
        XCTAssertEqual(controller.volumesForTesting.count, 1)
    }

    func testDeleteVolumeConfirmsThenDeletes() async {
        await controller.deleteVolume(name: "data")?.value
        XCTAssertTrue(confirmations[0].message.contains("data stored"), confirmations[0].message)
        XCTAssertTrue(controller.volumesForTesting.isEmpty)
    }

    func testStartStopRestart() async {
        await controller.startContainer(id: "kinhin-1")?.value
        XCTAssertEqual(controller.containersForTesting.first { $0.id == "kinhin-1" }?.state, "running")
        XCTAssertTrue(confirmations.isEmpty, "starting never needs confirmation")

        await controller.stopContainer(id: "web")?.value
        XCTAssertEqual(controller.containersForTesting.first { $0.id == "web" }?.state, "exited")
        XCTAssertTrue(confirmations.isEmpty, "ordinary containers stop without a prompt")

        await controller.restartContainer(id: "kinhin-1")?.value
        XCTAssertEqual(confirmations.count, 1, "restarting a kinhin runner asks first")
        XCTAssertTrue(docker.calls.contains(["/bin/docker", "restart", "kinhin-1"]))
    }

    func testStoppingARunnerCanBeCancelled() async {
        await controller.startContainer(id: "kinhin-1")?.value
        answer = false
        XCTAssertNil(controller.stopContainer(id: "kinhin-1"))
        XCTAssertEqual(controller.containersForTesting.first { $0.id == "kinhin-1" }?.state, "running")
    }

    func testRowsShowTheRightLifecycleButtons() {
        let titles = allText().components(separatedBy: "\n")
        XCTAssertTrue(titles.contains("Stop"))  // web is running
        XCTAssertTrue(titles.contains("Restart"))
        XCTAssertTrue(titles.contains("Start"))  // kinhin-1 is exited
    }

    func testDeleteIsAcknowledged() async {
        await controller.deleteVolume(name: "data")?.value
        XCTAssertTrue(controller.statusTextForTesting.contains("Deleted volume"), controller.statusTextForTesting)
    }

    func testToolErrorsShowInline() async {
        docker.failNext = "volume is in use"
        await controller.deleteVolume(name: "data")?.value
        XCTAssertTrue(controller.statusTextForTesting.contains("in use"), controller.statusTextForTesting)
        XCTAssertEqual(controller.volumesForTesting.count, 1, "a failed delete leaves the volume listed")
    }

    func testThereAreNoCreateButtons() {
        let titles = allText().components(separatedBy: "\n")
        XCTAssertFalse(titles.contains { $0.hasPrefix("New ") }, "kinhin never creates containers or volumes by hand")
    }

    private func allText() -> String {
        var out: [String] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTextField { out.append(t.stringValue) }
            if let b = v as? NSButton { out.append(b.title) }
            v.subviews.forEach(walk)
        }
        walk(controller.view)
        return out.joined(separator: "\n")
    }
}
