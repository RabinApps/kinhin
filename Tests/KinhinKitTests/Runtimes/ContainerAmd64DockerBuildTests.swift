import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Docker builds on an amd64 container runner (#75, step 3): dockerd runs under Rosetta there and its built-in
/// BuildKit cannot start a `RUN` step, so registration points `docker build` at a `docker-container` buildx builder
/// once dockerd answers, and arm64 runners keep the built-in builder.
final class ContainerAmd64DockerBuildTests: XCTestCase {
    private let bin = "/usr/local/bin/container"

    private func registrationScript(docker: Bool, platform: LinuxPlatform) async throws -> String {
        let runtime = AppleContainerRuntime(
            shell: FakeShell(), image: "img", docker: docker, platform: platform, binPath: bin)
        let github = GitHubForge(
            credentials: .github(token: "t", scope: "acme/widgets"), labels: ["kinhin"], client: FakeGitHub())
        return try await runtime.registrationScript(
            forge: github, token: "RT", name: "kinhin-1", runnerCount: 2,
            route: RepoRoute(repo: "acme/widgets", image: "tahoe-base", ephemeral: true, bootTimeout: 30), labels: nil)
    }

    func testAnAmd64DockerRunnerSetsUpTheBuilderAfterDockerdAndBeforeRegistering() async throws {
        let script = try await registrationScript(docker: true, platform: .amd64)
        let dockerd = try XCTUnwrap(script.range(of: "setsid nohup dockerd"))
        let builder = try XCTUnwrap(script.range(of: "docker buildx create --name kinhin"))
        let register = try XCTUnwrap(script.range(of: "./config.sh --url"))
        XCTAssertLessThan(dockerd.upperBound, builder.lowerBound, "the builder needs a running dockerd")
        XCTAssertLessThan(builder.upperBound, register.lowerBound, "config.sh keeps the .env the builder step wrote")
        XCTAssertTrue(script.hasPrefix(RunnerBootstrap.linuxDockerDaemonScript()), script)

        let syntax = try await Shell().run(["/bin/bash", "-n", "-c", script], cwd: nil, timeout: 10)
        XCTAssertTrue(syntax.succeeded, "composed registration script: \(syntax.stderr)")
    }

    func testArm64RunnersAndAmd64RunnersWithoutDockerKeepTheBuiltInBuilder() async throws {
        for script in [
            try await registrationScript(docker: true, platform: .arm64),
            try await registrationScript(docker: false, platform: .amd64),
        ] {
            XCTAssertFalse(script.contains("buildx"), script)
            XCTAssertFalse(script.contains("BUILDX_BUILDER"), script)
        }
    }

    func testTheBuilderScriptSelectsTheBuilderForEveryJob() async throws {
        let script = RunnerBootstrap.linuxDockerBuilderScript()
        XCTAssertTrue(
            script.contains("--driver docker-container --driver-opt default-load=true"),
            "a BuildKit container, whose results load into dockerd's image store")
        XCTAssertTrue(
            script.contains("docker buildx inspect kinhin"), "idempotent: a re-registration keeps the builder")
        XCTAssertTrue(
            script.contains("for runner_dir in /opt/actions-runner /opt/actions-runner-*; do"),
            "every baked runner directory, for several runners per container")
        XCTAssertTrue(script.contains(#"echo 'BUILDX_BUILDER=kinhin' >> "$runner_dir/.env""#))
        XCTAssertTrue(script.contains("grep -qs '^BUILDX_BUILDER='"), "a value the image already sets is kept")
        XCTAssertTrue(script.contains("/etc/profile.d/kinhin-buildx.sh"), "login shells too")
        let syntax = try await Shell().run(["/bin/bash", "-n", "-c", script], cwd: nil, timeout: 10)
        XCTAssertTrue(syntax.succeeded, syntax.stderr)
    }

    /// Without buildx (or with a builder that cannot be created), the runner still registers with the built-in
    /// builder and says why builds will fail, and nothing selects a builder that does not exist.
    func testAFailedBuilderWarnsAndSelectsNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-buildx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeDocker = dir.appendingPathComponent("docker")
        try "#!/bin/sh\nexit 1\n".write(to: fakeDocker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDocker.path)

        let result = try await Shell().run(
            ["/bin/bash", "-c", "PATH=\(dir.path):/usr/bin:/bin\n" + RunnerBootstrap.linuxDockerBuilderScript()],
            cwd: nil, timeout: 10)
        XCTAssertTrue(result.succeeded, "registration goes on: \(result.stderr)")
        XCTAssertTrue(result.stderr.contains("could not create the kinhin buildx builder"), result.stderr)
        XCTAssertFalse(result.stdout.contains("docker build uses"), result.stdout)
    }
}
