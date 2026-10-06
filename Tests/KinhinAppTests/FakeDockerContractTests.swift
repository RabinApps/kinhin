import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Contract for `FakeDocker` as a `ShellRunning`: the docker output it fakes
/// must read like the real `docker ps --format {{json .}}` /
/// `docker volume ls --format {{json .}}` rows the real `ContainerManager`
/// parses (same ids, names, images and lifecycle states from byte-identical
/// JSON delivered through the real `Shell`), every lifecycle verb the real
/// manager issues (`start`/`stop`/`restart`/`rm [--force]`/`volume rm`) must
/// change the fake's state the way the real CLI would — including refusing
/// a target the fake doesn't have with docker's own `No such …` stderr
/// instead of succeeding — a failing command must surface as the same
/// `ContainerManagerError.commandFailed` the real shell produces, and name
/// validation must reject before any argv reaches the shell. No docker
/// tooling is installed or launched.
final class FakeDockerContractTests: XCTestCase {
    private let bin = "/bin/docker"

    /// The rows real docker prints for this suite's fixtures (the fields
    /// `ContainerManager.parseDockerContainers` reads; `Status` carries the
    /// human text the fake abbreviates to its state).
    private let psFixture = """
        {"ID":"web","Image":"nginx","Names":"web","State":"running","Status":"Up 2 hours"}
        {"ID":"kinhin-1","Image":"runner","Names":"kinhin-1","State":"exited","Status":"Exited (0) 3 minutes ago"}
        """

    /// The stand-in `docker` modes: the fixtures the read-shape test parses, a
    /// command that always fails, and one that refuses targets it doesn't
    /// have the way the real CLI does.
    private enum RealDocker { case fixtures, alwaysFails, refusesMissing }

    /// Writes a stand-in `docker` for the given mode — the real `Shell` runs
    /// it as a real child, so the fake's bytes and the real child's bytes go
    /// through the identical parse.
    private func makeRealShell(_ mode: RealDocker = .fixtures) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-fakedocker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script: String
        switch mode {
        case .alwaysFails:
            script = """
                #!/bin/sh
                echo "volume is in use" >&2
                exit 1
                """
        case .refusesMissing:
            script = """
                #!/bin/sh
                for target in "$@"; do :; done
                case "$1" in
                  ps)
                    printf '%s\\n' '{"ID":"web","Image":"nginx","Names":"web","State":"running","Status":"Up 2 hours"}'
                    printf '%s\\n' '{"ID":"kinhin-1","Image":"runner","Names":"kinhin-1","State":"exited","Status":"Exited (0) 3 minutes ago"}'
                    ;;
                  volume)
                    if [ "$2" = "rm" ] && [ "$target" = "ghost" ]; then
                      echo "Error response from daemon: No such volume: ghost" >&2
                      exit 1
                    fi
                    printf '%s\\n' '{"Name":"data","Driver":"local"}'
                    ;;
                  rm)
                    if [ "$target" = "ghost" ]; then
                      echo "Error: No such container: ghost" >&2
                      exit 1
                    fi
                    ;;
                  start|stop|restart)
                    if [ "$target" = "ghost" ]; then
                      echo "Error response from daemon: No such container: ghost" >&2
                      exit 1
                    fi
                    ;;
                esac
                exit 0
                """
        case .fixtures:
            script = """
                #!/bin/sh
                case "$1" in
                  ps) printf '%s\\n' \\
                    '{"ID":"web","Image":"nginx","Names":"web","State":"running","Status":"Up 2 hours"}' \\
                    '{"ID":"kinhin-1","Image":"runner","Names":"kinhin-1","State":"exited","Status":"Exited (0) 3 minutes ago"}' ;;
                  volume) printf '%s\\n' '{"Name":"data","Driver":"local"}' ;;
                  *) exit 0 ;;
                esac
                """
        }
        let path = dir.appendingPathComponent("docker")
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    /// The manager as the Containers tab builds it, over the given shell.
    private func makeManager(shell: ShellRunning, binary: String? = nil) -> ContainerManager {
        ContainerManager(tool: .docker, shell: shell, binary: binary ?? bin)
    }

    // MARK: - Read shape

    func testRowsParseToTheSameContainersAsARealChildPrintingDockerJson() async throws {
        let realBinary = try makeRealShell()
        defer { try? FileManager.default.removeItem(at: realBinary.deletingLastPathComponent()) }
        let realManager = makeManager(shell: Shell(), binary: realBinary.path)
        let realContainers = try await realManager.containers()
        let realVolumes = try await realManager.volumes()

        let fake = FakeDocker()
        let fakeManager = makeManager(shell: fake)
        let fakeContainers = try await fakeManager.containers()
        let fakeVolumes = try await fakeManager.volumes()

        // The fields every consumer branches on parse identically on both sides…
        for (real, fakeRow) in zip(realContainers, fakeContainers) {
            XCTAssertEqual(fakeRow.id, real.id)
            XCTAssertEqual(fakeRow.name, real.name, "Names is what the model lists and deletes by")
            XCTAssertEqual(fakeRow.image, real.image)
            XCTAssertEqual(fakeRow.state, real.state, "the lifecycle state the buttons branch on")
        }
        XCTAssertEqual(fakeVolumes, realVolumes, "volume rows parse byte-for-byte the same")
        XCTAssertEqual(fakeVolumes.first?.name, "data")

        // …and pin the fake to the expectations hard-coded from real docker.
        XCTAssertEqual(
            fakeContainers.map(\.id), ["web", "kinhin-1"],
            "one row per line, in order — a renamed JSON key here shows up as an empty id")
        XCTAssertEqual(fakeContainers.map(\.state), ["running", "exited"])
        XCTAssertTrue(fakeContainers.allSatisfy { !$0.status.isEmpty }, "status text feeds the list view")
        XCTAssertEqual(fakeContainers.first?.isRunning, true)
        XCTAssertEqual(fakeContainers.last?.isKinhinRunner, true, "the runner warning keys on the name")
    }

    // MARK: - Lifecycle verbs

    func testEveryLifecycleVerbTheRealManagerIssuesChangesTheFakesState() async throws {
        let fake = FakeDocker()
        let manager = makeManager(shell: fake)

        try await manager.startContainer(id: "kinhin-1")
        var containers = try await manager.containers()
        XCTAssertEqual(
            containers.first { $0.id == "kinhin-1" }?.state, "running",
            "`docker start` flips the state the real manager then re-reads")

        try await manager.stopContainer(id: "web")
        containers = try await manager.containers()
        XCTAssertEqual(containers.first { $0.id == "web" }?.state, "exited")

        try await manager.restartContainer(id: "kinhin-1")
        containers = try await manager.containers()
        XCTAssertEqual(containers.first { $0.id == "kinhin-1" }?.state, "running")

        try await manager.deleteContainer(id: "kinhin-1", force: true)
        containers = try await manager.containers()
        XCTAssertNil(containers.first { $0.id == "kinhin-1" }, "`docker rm --force` removes it from the next list")

        try await manager.deleteVolume(name: "data")
        let volumes = try await manager.volumes()
        XCTAssertEqual(volumes, [], "`docker volume rm` removes it from the next list")

        let listArgv = [bin, "ps", "--all", "--no-trunc", "--format", "{{json .}}"]
        XCTAssertEqual(
            fake.calls,
            [
                [bin, "start", "kinhin-1"], listArgv,
                [bin, "stop", "web"], listArgv,
                [bin, "restart", "kinhin-1"], listArgv,
                [bin, "rm", "--force", "kinhin-1"], listArgv,
                [bin, "volume", "rm", "data"],
                [bin, "volume", "ls", "--format", "{{json .}}"],
            ], "the fake must interpret exactly the argv the real manager sends, in order")
    }

    // MARK: - Failures

    func testAFailingCommandSurfacesTheSameErrorOnBothSides() async throws {
        // Real: a docker that printed the failure to stderr and exited 1.
        let realBinary = try makeRealShell(.alwaysFails)
        defer { try? FileManager.default.removeItem(at: realBinary.deletingLastPathComponent()) }
        let realManager = makeManager(shell: Shell(), binary: realBinary.path)
        // Fake: the same failure on the same argv.
        let fake = FakeDocker()
        fake.failNext = "volume is in use\n"
        let fakeManager = makeManager(shell: fake)

        var realError: Error?
        do { try await realManager.deleteContainer(id: "web", force: true) } catch { realError = error }
        var fakeError: Error?
        do { try await fakeManager.deleteContainer(id: "web", force: true) } catch { fakeError = error }

        let expected = ContainerManagerError.commandFailed(
            what: "deleting container 'web'", stderr: "volume is in use\n")
        XCTAssertEqual(realError as? ContainerManagerError, expected, "the real shell's stderr is the error")
        XCTAssertEqual(
            fakeError as? ContainerManagerError, expected,
            "the fake must fail with the identical error — the model shows its stderr verbatim")

        // After the failure the fleet still reads: the fake falls back to
        // normal answers, like a fresh docker invocation.
        let containers = try await fakeManager.containers()
        XCTAssertEqual(containers.count, 2, "a failed delete leaves the containers listed")
    }

    func testMissingTargetsFailLikeTheRealCliInsteadOfSilentlySucceeding() async throws {
        /// The first `ContainerManagerError` the call throws (nil when it succeeds).
        func failure(_ op: () async throws -> Void) async -> ContainerManagerError? {
            do {
                try await op()
                return nil
            } catch {
                return error as? ContainerManagerError
            }
        }

        // Real: a stand-in docker that refuses targets it doesn't have, with
        // the messages the real CLI prints (what a stale list meets).
        let realBinary = try makeRealShell(.refusesMissing)
        defer { try? FileManager.default.removeItem(at: realBinary.deletingLastPathComponent()) }
        let realManager = makeManager(shell: Shell(), binary: realBinary.path)
        let realDelete = await failure { try await realManager.deleteContainer(id: "ghost", force: true) }
        let realVolume = await failure { try await realManager.deleteVolume(name: "ghost") }

        // Fake: the same refusals out of its own state.
        let fake = FakeDocker()
        let fakeManager = makeManager(shell: fake)
        let fakeDelete = await failure { try await fakeManager.deleteContainer(id: "ghost", force: true) }
        let fakeStart = await failure { try await fakeManager.startContainer(id: "ghost") }
        let fakeStop = await failure { try await fakeManager.stopContainer(id: "ghost") }
        let fakeRestart = await failure { try await fakeManager.restartContainer(id: "ghost") }
        let fakeVolume = await failure { try await fakeManager.deleteVolume(name: "ghost") }

        let expectedDelete = ContainerManagerError.commandFailed(
            what: "deleting container 'ghost'", stderr: "Error: No such container: ghost\n")
        let daemonNoSuchContainer = "Error response from daemon: No such container: ghost\n"
        let expectedVolume = ContainerManagerError.commandFailed(
            what: "deleting volume 'ghost'", stderr: "Error response from daemon: No such volume: ghost\n")
        XCTAssertEqual(
            fakeDelete, realDelete,
            "deleting a container that vanished fails identically, whichever shell ran")
        XCTAssertEqual(fakeDelete, expectedDelete, "docker's own refusal reaches the model verbatim")
        XCTAssertEqual(fakeVolume, realVolume, "same for a volume that vanished")
        XCTAssertEqual(fakeVolume, expectedVolume)
        XCTAssertEqual(
            fakeStart,
            ContainerManagerError.commandFailed(what: "starting container 'ghost'", stderr: daemonNoSuchContainer))
        XCTAssertEqual(
            fakeStop,
            ContainerManagerError.commandFailed(what: "stopping container 'ghost'", stderr: daemonNoSuchContainer))
        XCTAssertEqual(
            fakeRestart,
            ContainerManagerError.commandFailed(what: "restarting container 'ghost'", stderr: daemonNoSuchContainer))

        // Nothing was dropped: the fake never removes what it doesn't have.
        let containers = try await fakeManager.containers()
        XCTAssertEqual(containers.map(\.id), ["web", "kinhin-1"])
    }

    func testInvalidNamesAreRejectedBeforeAnyArgvReachesTheShell() async throws {
        let fake = FakeDocker()
        let manager = makeManager(shell: fake)

        do {
            try await manager.deleteContainer(id: "-oRm", force: false)
            XCTFail("expected a refusal")
        } catch let error as ContainerManagerError {
            XCTAssertEqual(
                error, .invalidName("-oRm"),
                "validation happens in the manager — identical whether the shell is real or fake")
        }
        XCTAssertTrue(fake.calls.isEmpty, "a refused name must never reach any shell")
    }
}
