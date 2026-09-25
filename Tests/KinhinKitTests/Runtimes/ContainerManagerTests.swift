import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ContainerManagerTests: XCTestCase {
    private func manager(_ tool: ContainerTool, _ shell: FakeShell) -> ContainerManager {
        ContainerManager(tool: tool, shell: shell, binary: "/bin/\(tool.binaryName)")
    }

    func testDeleteCommandsAreBuiltCorrectly() async throws {
        let docker = FakeShell()
        try await manager(.docker, docker).deleteContainer(id: "web", force: true)
        try await manager(.docker, docker).deleteContainer(id: "old", force: false)
        try await manager(.docker, docker).deleteVolume(name: "data")
        XCTAssertEqual(
            docker.calls,
            [
                ["/bin/docker", "rm", "--force", "web"],
                ["/bin/docker", "rm", "old"],
                ["/bin/docker", "volume", "rm", "data"],
            ])
        let apple = FakeShell()
        try await manager(.appleContainer, apple).deleteContainer(id: "web", force: true)
        try await manager(.appleContainer, apple).deleteVolume(name: "data")
        XCTAssertEqual(
            apple.calls,
            [
                ["/bin/container", "delete", "--force", "web"],
                ["/bin/container", "volume", "delete", "data"],
            ])
    }

    func testInvalidNamesNeverReachTheShell() async {
        let shell = FakeShell()
        let docker = manager(.docker, shell)
        for bad in ["", "-rf", "a b", "x;y", "--all"] {
            do { try await docker.deleteVolume(name: bad); XCTFail("accepted '\(bad)'") } catch {
                XCTAssertEqual(error as? ContainerManagerError, .invalidName(bad))
            }
        }
        XCTAssertTrue(shell.calls.isEmpty)
    }

    func testLifecycleCommands() async throws {
        let shell = FakeShell()
        try await manager(.docker, shell).startContainer(id: "a")
        try await manager(.docker, shell).stopContainer(id: "a")
        try await manager(.docker, shell).restartContainer(id: "a")
        let apple = FakeShell()
        try await manager(.appleContainer, apple).restartContainer(id: "a")
        XCTAssertEqual(
            shell.calls,
            [["/bin/docker", "start", "a"], ["/bin/docker", "stop", "a"], ["/bin/docker", "restart", "a"]])
        XCTAssertEqual(
            apple.calls, [["/bin/container", "stop", "a"], ["/bin/container", "start", "a"]],
            "Apple container has no restart: it is stop then start")
        do { try await manager(.docker, shell).stopContainer(id: "--all"); XCTFail() } catch {}
    }

    func testFailureSurfacesToolOutput() async {
        let shell = FakeShell()
        shell.responses = [ShellResult(exitCode: 1, stdout: "", stderr: "volume is in use")]
        do { try await manager(.docker, shell).deleteVolume(name: "data"); XCTFail() } catch {
            XCTAssertTrue(error.localizedDescription.contains("volume is in use"))
        }
    }

    func testMissingToolIsReported() async {
        let manager = ContainerManager(tool: .appleContainer, shell: FakeShell(), binary: nil)
        // binary lookup may find a real install on some hosts; force-missing via explicit nil path only when absent
        if manager.tool.isInstalled { return }
        do { _ = try await manager.containers(); XCTFail() } catch {
            XCTAssertEqual(error as? ContainerManagerError, .toolMissing(.appleContainer))
        }
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
        XCTAssertEqual(
            containers,
            [
                ManagedContainer(
                    id: "web", name: "web", image: "docker.io/library/alpine:latest", state: "running",
                    status: "running")
            ])
        XCTAssertEqual(ContainerManager.parseAppleVolumes("[{\"name\":\"data\"}]"), [ManagedVolume(name: "data")])
        XCTAssertTrue(ContainerManager.parseAppleContainers("").isEmpty)
        XCTAssertTrue(ContainerManager.parseDockerContainers("garbage\n").isEmpty)
    }
}
