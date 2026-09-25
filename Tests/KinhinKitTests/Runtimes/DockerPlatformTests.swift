import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `docker.platform`: opt-in linux/amd64 runners under emulation. arm64 stays
/// the byte-identical default; amd64 flows through config, the container
/// argv, runner labels, the bake, and the checklist, and is always disclosed.
final class DockerPlatformTests: XCTestCase {
    private let bin = "/usr/local/bin/docker"
    private let base = "repo: \"acme/widgets\"\nlabels: [self-hosted, macos, arm64]\n"

    // MARK: Config

    func testPlatformDefaultsToArm64() throws {
        let cfg = try ConfigLoader.parse(base + "docker:\n  image: ci\n")
        XCTAssertEqual(cfg.docker?.platform, .arm64)
    }

    func testPlatformParsesAmd64AndBareArchitectures() throws {
        for (raw, expected) in [
            ("linux/amd64", LinuxPlatform.amd64), ("amd64", .amd64), ("x86_64", .amd64), ("linux/arm64", .arm64),
        ] {
            let cfg = try ConfigLoader.parse(base + "docker:\n  image: ci\n  platform: \"\(raw)\"\n")
            XCTAssertEqual(cfg.docker?.platform, expected, raw)
        }
    }

    func testUnknownPlatformIsRejected() {
        XCTAssertThrowsError(try ConfigLoader.parse(base + "docker:\n  image: ci\n  platform: linux/riscv64\n")) {
            XCTAssertTrue("\($0)".contains("docker.platform"), "\($0)")
        }
    }

    func testContainerPlatformIsRejected() {
        XCTAssertThrowsError(try ConfigLoader.parse(base + "container:\n  image: ci\n  platform: linux/amd64\n")) {
            XCTAssertTrue("\($0)".contains("arm64 only"), "\($0)")
        }
    }

    func testEditingTheDockerSectionKeepsThePlatform() throws {
        let yaml = base + "docker:\n  image: ci\n  platform: \"linux/amd64\"\n"
        let snapshot = try GeneralConfigEditor.snapshot(from: yaml)
        XCTAssertEqual(snapshot.docker?.platform, "linux/amd64")
        var edited = try XCTUnwrap(snapshot.docker)
        edited.cpus = 6
        let rewritten = try GeneralConfigEditor.replace(field: .docker(edited), in: yaml)
        XCTAssertEqual(try ConfigLoader.parse(rewritten).docker?.platform, .amd64, rewritten)
    }

    func testSetDockerPlatformRoundTripsThroughTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("platform-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: url) }
        try (base + "docker:\n  image: ci\n  cpus: 3\n").write(to: url, atomically: true, encoding: .utf8)

        try GeneralConfigEditor.setDockerPlatform(.amd64, at: url)
        XCTAssertEqual(try ConfigLoader.load(from: url).docker?.platform, .amd64)
        XCTAssertEqual(try ConfigLoader.load(from: url).docker?.cpus, 3, "other keys survive")

        try GeneralConfigEditor.setDockerPlatform(.arm64, at: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("platform"), "arm64 is the default and is not written: \(text)")
    }

    // MARK: Runtime

    func testProvisionPinsTheConfiguredPlatform() async throws {
        for platform in LinuxPlatform.allCases {
            let shell = FakeShell()
            let runtime = DockerRuntime(shell: shell, image: "ci", platform: platform, binPath: bin)
            let route = RepoRoute(repo: "acme/widgets", image: "ci", ephemeral: true, bootTimeout: 30)
            try await runtime.provision(id: "kinhin-x", route: route)
            let argv = try XCTUnwrap(shell.calls.last)
            let idx = try XCTUnwrap(argv.firstIndex(of: "--platform"))
            XCTAssertEqual(argv[idx + 1], platform.rawValue)
        }
    }

    func testAmd64PoolSwapsTheArm64LabelForX64() {
        let fleet = ["self-hosted", "macos", "arm64"]
        XCTAssertEqual(
            RuntimePool.labelsFor(.docker, fleetLabels: fleet, dockerPlatform: .amd64),
            ["self-hosted", "macos", "x64", "kinhin-docker"])
        XCTAssertEqual(
            RuntimePool.labelsFor(.docker, fleetLabels: fleet),
            ["self-hosted", "macos", "arm64", "kinhin-docker"], "arm64 default is unchanged")
        XCTAssertEqual(
            RuntimePool.labelsFor(.tart, fleetLabels: fleet, dockerPlatform: .amd64), fleet,
            "only Docker pools are affected")
    }

    // MARK: Agent scripts

    func testAgentScriptsDefaultToArm64AndFollowTheArchitecture() {
        let github = RunnerBootstrap.linuxGitHubAgentInstallScript(runnerVersion: "2.1.0")
        XCTAssertTrue(github.contains("actions-runner-linux-arm64-2.1.0.tar.gz"))
        XCTAssertEqual(github, RunnerBootstrap.linuxGitHubAgentInstallScript(runnerVersion: "2.1.0", arch: "arm64"))
        XCTAssertTrue(
            RunnerBootstrap.linuxGitHubAgentInstallScript(runnerVersion: "2.1.0", arch: "x64")
                .contains("actions-runner-linux-x64-2.1.0.tar.gz"))
        XCTAssertTrue(
            RunnerBootstrap.linuxGiteaRunnerInstallScript(version: "0.2.0").contains("-linux-arm64.xz"))
        XCTAssertTrue(
            RunnerBootstrap.linuxGiteaRunnerInstallScript(version: "0.2.0", arch: "amd64")
                .contains("-linux-amd64.xz"))
    }

    // MARK: Bake

    func testAmd64BakePinsThePlatformAndInstallsX64Agents() async throws {
        let shell = FakeShell()
        var options = DockerImagePreparer.Options(
            image: "ubuntu:24.04", target: "ci", hasGitHubToken: true, hasGiteaToken: true)
        options.platform = .amd64
        _ = try await DockerImagePreparer(shell: shell).prepare(
            options, versions: .init(github: "2.1.0", gitea: "0.2.0"))
        let run = try XCTUnwrap(shell.calls.first { $0.contains("run") })
        let idx = try XCTUnwrap(run.firstIndex(of: "--platform"))
        XCTAssertEqual(run[idx + 1], "linux/amd64")
        let scripts = shell.calls.filter { $0.contains("/bin/bash") }.flatMap { $0 }.joined(separator: "\n")
        XCTAssertTrue(scripts.contains("actions-runner-linux-x64-2.1.0"), scripts)
        XCTAssertTrue(scripts.contains("linux-amd64.xz"), scripts)
    }

    func testArm64BakeArgvIsUnchanged() async throws {
        let shell = FakeShell()
        _ = try await DockerImagePreparer(shell: shell).prepare(
            .init(image: "ubuntu:24.04", target: "ci", hasGitHubToken: true, hasGiteaToken: false),
            versions: .init(github: "2.1.0", gitea: "0.2.0"))
        let run = try XCTUnwrap(shell.calls.first { $0.contains("run") })
        XCTAssertFalse(run.contains("--platform"), "native bakes add no flag: \(run)")
    }

    func testImageArchitectureQueriesDockerInspect() async {
        let shell = FakeShell()
        shell.responses = [ShellResult(exitCode: 0, stdout: "amd64\n", stderr: "")]
        let runtime = DockerRuntime(shell: shell, image: "ci", binPath: bin)
        let arch = await runtime.imageArchitecture(of: "ci")
        XCTAssertEqual(arch, "amd64")
        XCTAssertEqual(shell.calls.first, [bin, "image", "inspect", "--format", "{{.Architecture}}", "ci"])
    }

    func testStaleImageOfAnotherArchitectureIsNotAReusableBase() async {
        let shell = FakeShell()
        shell.responses = [
            ShellResult(exitCode: 0, stdout: "ci:latest\nubuntu:24.04\n", stderr: ""),  // docker images
            ShellResult(exitCode: 0, stdout: "arm64\n", stderr: ""),  // inspect
        ]
        let runtime = DockerRuntime(shell: shell, image: "ci", binPath: bin)
        let names = await runtime.localImageNames(reusing: "ci", for: .amd64)
        XCTAssertEqual(names, ["ubuntu:24.04"])
    }

    // MARK: Checklist + disclosure

    private func checklist(platform: LinuxPlatform, imageArch: String?) async -> SetupCheckResult? {
        var cfg = KinhinConfig.default
        cfg.repo = "acme/widgets"
        cfg.docker = .init(image: "ci", platform: platform)
        let status = await SetupStatusComputer(
            host: HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 120, arm64: true),
            clt: .ok(version: "27.0"), tartHealth: .healthy,
            tartList: [TartVM(name: "b", source: "s", status: "suspended", cpu: nil, memoryMB: nil)],
            config: .loaded(cfg), tokenStored: true, dockerHealth: .ready, dockerImages: ["ci"],
            dockerImageArchitecture: imageArch
        ).compute()
        return status.checks.first { $0.id == "docker-image" }
    }

    func testArm64ChecklistHasNoDisclosure() async throws {
        let found = await checklist(platform: .arm64, imageArch: "arm64")
        let row = try XCTUnwrap(found)
        XCTAssertTrue(row.ok)
        XCTAssertFalse(row.detail.contains("emulation"))
    }

    func testAmd64ChecklistDisclosesEmulation() async throws {
        let found = await checklist(platform: .amd64, imageArch: "amd64")
        let row = try XCTUnwrap(found)
        XCTAssertTrue(row.ok)
        XCTAssertTrue(row.detail.contains(LinuxPlatform.emulationNotice), row.detail)
    }

    func testArchitectureMismatchFailsTheImageRow() async throws {
        let found = await checklist(platform: .amd64, imageArch: "arm64")
        let row = try XCTUnwrap(found)
        XCTAssertFalse(row.ok)
        XCTAssertTrue(row.detail.contains("image 'ci' is arm64 but docker.platform is linux/amd64"), row.detail)
        XCTAssertEqual(row.action, "prepare_docker_image")
    }

    func testDoctorDockerSectionCarriesThePlatformAndNote() async throws {
        var cfg = KinhinConfig.default
        cfg.repo = "acme/widgets"
        cfg.docker = .init(image: "ci", platform: .amd64)
        let report = await DoctorReportBuilder(
            host: HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 120, arm64: true),
            clt: .ok(version: "27.0"), tartHealth: .healthy, tartList: [],
            config: .loaded(cfg), authLoad: { _ in "token" }, dockerHealth: .ready, dockerImages: ["ci"]
        ).build()
        XCTAssertEqual(report.docker?.platform, "linux/amd64")
        XCTAssertEqual(report.docker?.note, LinuxPlatform.emulationNotice)
    }
}
