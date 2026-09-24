import XCTest
@testable import KinhinKit

private final class ContainerFakeShell: ShellRunning, @unchecked Sendable {
    var calls: [[String]] = []
    var results: [ShellResult] = []
    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        calls.append(argv)
        return results.isEmpty ? ShellResult(exitCode: 0, stdout: "", stderr: "") : results.removeFirst()
    }
}

final class ContainerManagerTests: XCTestCase {
    private func manager(_ tool: ContainerTool, _ shell: ContainerFakeShell) -> ContainerManager {
        ContainerManager(tool: tool, shell: shell, binary: "/bin/\(tool.binaryName)")
    }

    func testDockerCommandsAreBuiltCorrectly() async throws {
        let shell = ContainerFakeShell()
        let docker = manager(.docker, shell)
        try await docker.createContainer(name: "web", image: "nginx:latest")
        try await docker.createVolume(name: "data")
        try await docker.deleteContainer(id: "web", force: true)
        try await docker.deleteContainer(id: "old", force: false)
        try await docker.deleteVolume(name: "data")
        XCTAssertEqual(shell.calls, [
            ["/bin/docker", "create", "--name", "web", "nginx:latest"],
            ["/bin/docker", "volume", "create", "data"],
            ["/bin/docker", "rm", "--force", "web"],
            ["/bin/docker", "rm", "old"],
            ["/bin/docker", "volume", "rm", "data"],
        ])
    }

    func testAppleContainerCommandsAreBuiltCorrectly() async throws {
        let shell = ContainerFakeShell()
        let apple = manager(.appleContainer, shell)
        try await apple.createContainer(name: "web", image: "alpine")
        try await apple.createVolume(name: "data")
        try await apple.deleteContainer(id: "web", force: true)
        try await apple.deleteVolume(name: "data")
        XCTAssertEqual(shell.calls, [
            ["/bin/container", "create", "--name", "web", "alpine"],
            ["/bin/container", "volume", "create", "data"],
            ["/bin/container", "delete", "--force", "web"],
            ["/bin/container", "volume", "delete", "data"],
        ])
    }

    func testLifecycleCommands() async throws {
        let shell = ContainerFakeShell()
        try await manager(.docker, shell).startContainer(id: "a")
        try await manager(.docker, shell).stopContainer(id: "a")
        try await manager(.docker, shell).restartContainer(id: "a")
        let apple = ContainerFakeShell()
        try await manager(.appleContainer, apple).restartContainer(id: "a")
        XCTAssertEqual(shell.calls, [["/bin/docker", "start", "a"], ["/bin/docker", "stop", "a"], ["/bin/docker", "restart", "a"]])
        XCTAssertEqual(apple.calls, [["/bin/container", "stop", "a"], ["/bin/container", "start", "a"]],
                       "Apple container has no restart: it is stop then start")
        do { try await manager(.docker, shell).stopContainer(id: "--all"); XCTFail() } catch {}
    }

    func testInvalidNamesAndImagesNeverReachTheShell() async {
        let shell = ContainerFakeShell()
        let docker = manager(.docker, shell)
        for bad in ["", "-rf", "a b", "x;y", "--all"] {
            do { try await docker.createVolume(name: bad); XCTFail("accepted '\(bad)'") }
            catch { XCTAssertEqual(error as? ContainerManagerError, .invalidName(bad)) }
        }
        do { try await docker.createContainer(name: "ok", image: "--privileged"); XCTFail() }
        catch { XCTAssertEqual(error as? ContainerManagerError, .invalidImage("--privileged")) }
        XCTAssertTrue(shell.calls.isEmpty)
    }

    func testFailureSurfacesToolOutput() async {
        let shell = ContainerFakeShell()
        shell.results = [ShellResult(exitCode: 1, stdout: "", stderr: "volume is in use")]
        do { try await manager(.docker, shell).deleteVolume(name: "data"); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("volume is in use")) }
    }

    func testMissingToolIsReported() async {
        let manager = ContainerManager(tool: .appleContainer, shell: ContainerFakeShell(), binary: nil)
        // binary lookup may find a real install on some hosts; force-missing via explicit nil path only when absent
        if manager.tool.isInstalled { return }
        do { _ = try await manager.containers(); XCTFail() }
        catch { XCTAssertEqual(error as? ContainerManagerError, .toolMissing(.appleContainer)) }
    }

    func testParseDockerOutput() {
        let ps = """
        {"ID":"abc123","Image":"nginx:latest","Names":"web","State":"running","Status":"Up 2 hours"}
        {"ID":"def456","Image":"alpine","Names":"kinhin-1","State":"exited","Status":"Exited (0) 1 hour ago"}
        """
        let containers = ContainerManager.parseDockerContainers(ps)
        XCTAssertEqual(containers.map(\.name), ["web", "kinhin-1"])
        XCTAssertTrue(containers[0].isRunning)
        XCTAssertFalse(containers[1].isRunning)
        XCTAssertTrue(containers[1].isKinhinRunner)
        XCTAssertFalse(containers[0].isKinhinRunner)

        let volumes = ContainerManager.parseDockerVolumes("{\"Driver\":\"local\",\"Name\":\"data\"}\n")
        XCTAssertEqual(volumes, [ManagedVolume(name: "data", driver: "local")])
    }

    func testParseAppleOutputInBothStatusShapes() {
        // Newer releases: nested status object (apple/container ManagedContainer).
        let newer = """
        [{"id":"web","configuration":{"id":"web","image":{"reference":"alpine:3"}},"status":{"state":"running","networks":[]}}]
        """
        XCTAssertEqual(ContainerManager.parseAppleContainers(newer).first?.state, "running")
        XCTAssertEqual(ContainerManager.parseAppleContainers(newer).first?.image, "alpine:3")
        // Older releases: ContainerSnapshot with a plain status string.
        let older = """
        [{"configuration":{"id":"db","image":{"reference":"pg"}},"status":"stopped","networks":[]}]
        """
        XCTAssertEqual(ContainerManager.parseAppleContainers(older).first?.state, "stopped")
    }

    func testParseAppleVolumeShape() {
        let json = """
        [{"id":"pgdata","configuration":{"name":"pgdata","driver":"local","format":"ext4","labels":{}}}]
        """
        XCTAssertEqual(ContainerManager.parseAppleVolumes(json), [ManagedVolume(name: "pgdata", driver: "local")])
    }

    func testParseAppleOutputAndEmptyDocuments() {
        let json = """
        [{"status":"running","configuration":{"id":"web","image":{"reference":"docker.io/library/alpine:latest"}}}]
        """
        let containers = ContainerManager.parseAppleContainers(json)
        XCTAssertEqual(containers, [ManagedContainer(id: "web", name: "web", image: "docker.io/library/alpine:latest", state: "running", status: "running")])
        XCTAssertEqual(ContainerManager.parseAppleVolumes("[{\"name\":\"data\"}]"), [ManagedVolume(name: "data")])
        XCTAssertTrue(ContainerManager.parseAppleContainers("").isEmpty)
        XCTAssertTrue(ContainerManager.parseDockerContainers("garbage\n").isEmpty)
    }
}
