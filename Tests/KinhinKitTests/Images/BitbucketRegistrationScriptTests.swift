import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The Bitbucket runner bootstrap on each runtime: the credential bundle
/// reaches the runner through its private file, the package layout matches
/// the vendor tarball (`bin/start.sh`), and the launcher is runtime-specific.
final class BitbucketRegistrationScriptTests: XCTestCase {
    private let route = RepoRoute(repo: "acme", image: "img", ephemeral: true, bootTimeout: 30)

    private func forge() -> BitbucketForge {
        let credentials = BitbucketCredentials(token: "bbtkn", scope: "acme")
        return BitbucketForge(
            credentials: ForgeCredentials(forge: .bitbucket, token: "bbtkn", scope: "acme"),
            labels: ["self.hosted", "macos", "kinhin"],
            client: BitbucketClient(credentials: credentials),
            scope: .workspace("acme"), workspaceUUID: "{ws-1}", repositoryUUID: nil, listTTL: 0)
    }

    func testScriptStartsOneRunnerPerNameFromAPrivateBundle() {
        let script = RunnerBootstrap.bitbucketRegistrationScript(
            runners: [
                ("kinhin-1-r1", "{ws}|{repo}|{r1}|cli-1|sec-1"),
                ("kinhin-1-r2", "{ws}|{repo}|{r2}|cli-2|sec-2"),
            ],
            runtime: "macos", runnerCommand: #""$HOME/bitbucket-runner/runner.sh""#,
            baseDir: #""$HOME/bitbucket-runners""#)
        XCTAssertTrue(script.contains("2 bitbucket runner(s) started"), script)
        XCTAssertTrue(
            script.contains(#"umask 077"#), "the bundle is written through a private umask")
        XCTAssertTrue(
            script.contains(
                #"IFS="|" read -r WORKSPACE_UUID REPOSITORY_UUID RUNNER_UUID OAUTH_CLIENT_ID OAUTH_CLIENT_SECRET < "$1""#
            ),
            script)
        XCTAssertTrue(
            script.contains(#"--accountUuid "$WORKSPACE_UUID" --runnerUuid "$RUNNER_UUID""#), script)
        XCTAssertTrue(
            script.contains(#"--OAuthClientId "$OAUTH_CLIENT_ID""#), script)
        XCTAssertTrue(
            script.contains(#"--OAuthClientSecret "$OAUTH_CLIENT_SECRET""#), script)
        XCTAssertTrue(script.contains(#"--workingDirectory "$PWD/work" --runtime "$KINHIN_RUNTIME""#), script)
        XCTAssertTrue(script.contains("KINHIN_RUNTIME='macos'"), "an explicit runtime is passed through")
        XCTAssertTrue(script.contains(#""$HOME/bitbucket-runner/runner.sh""#), script)
        XCTAssertTrue(script.contains(#""$HOME/bitbucket-runners"/'kinhin-1-r1'"#), script)
        XCTAssertTrue(script.contains("runner.pid"), "teardown can stop the recorded process")
        // The secrets only travel through the per-runner private files.
        XCTAssertFalse(script.contains("--labels"), "labels were decided at runner creation")
    }

    /// A tart base VM may be a macOS or a Linux guest: `auto` lets the guest pick.
    func testAutoRuntimeIsResolvedByTheGuest() {
        let script = RunnerBootstrap.bitbucketRegistrationScript(
            runners: [("kinhin-1-r1", "{ws}||{r1}|cli-1|sec-1")], runtime: "auto",
            runnerCommand: #""$HOME/bitbucket-runner/runner.sh""#, baseDir: #""$HOME/bitbucket-runners""#)
        XCTAssertTrue(
            script.contains("Darwin) KINHIN_RUNTIME=macos ;; *) KINHIN_RUNTIME=linux-shell ;; esac"), script)
        XCTAssertFalse(script.contains("KINHIN_RUNTIME='auto'"))
    }

    func testEachRuntimeUsesItsOwnRunnerPaths() async throws {
        let runnerTokens = ["kinhin-1": "{ws-1}||{r-1}|cli-1|sec-1"]
        let tart = try await TartRuntime(tart: FakeTart(), bootTimeout: { 30 }).registrationScript(
            forge: forge(), token: "", runnerTokens: runnerTokens, name: "kinhin-1", runnerCount: 1,
            route: route, labels: nil)
        XCTAssertTrue(tart.contains(#""$HOME/bitbucket-runner/runner.sh""#), tart)
        XCTAssertTrue(tart.contains(#""$HOME/bitbucket-runners""#), tart)

        let docker = try await DockerRuntime(shell: FakeShell(), image: "img", cpus: 2, memoryGB: 4)
            .registrationScript(
                forge: forge(), token: "", runnerTokens: runnerTokens, name: "kinhin-1", runnerCount: 1,
                route: route, labels: nil)
        XCTAssertTrue(docker.contains("/opt/bitbucket-runner/runner.sh"), docker)
        XCTAssertTrue(docker.contains("--runtime"), docker)

        let agentDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = try await HostRuntime(shell: FakeShell(), agentDir: agentDir).registrationScript(
            forge: forge(), token: "", runnerTokens: runnerTokens, name: "kinhin-1", runnerCount: 1,
            route: route, labels: nil)
        XCTAssertTrue(host.contains(agentDir.appendingPathComponent("bitbucket-runner/runner.sh").path), host)
        XCTAssertTrue(host.contains("host-instances/kinhin-1"), "runners live in the scrubbed instance dir")
    }

    func testRunnerCountProducesOneRunnerPerName() throws {
        let runners = try RunnerBootstrap.bitbucketRunners(
            name: "kinhin-7", runnerCount: 2,
            tokens: [
                "kinhin-7-r1": "{ws}||{r1}|cli|sec1",
                "kinhin-7-r2": "{ws}||{r2}|cli|sec2",
            ])
        XCTAssertEqual(runners.map(\.name), ["kinhin-7-r1", "kinhin-7-r2"])
        XCTAssertThrowsError(
            try RunnerBootstrap.bitbucketRunners(name: "kinhin-7", runnerCount: 1, tokens: [:]),
            "a missing bundle is a registration failure, not an empty runner"
        )
    }

    func testInstallScriptDownloadsThePinnedPackageAndJDK() {
        let script = RunnerBootstrap.bitbucketRunnerInstallScript(
            version: "6.0.8", jdkVersion: "25.0.4.1+1", jdkPlatform: "aarch64_mac")
        XCTAssertTrue(
            script.contains(
                "https://product-downloads.atlassian.com/software/bitbucket/pipelines/atlassian-bitbucket-pipelines-runner-6.0.8.tar.gz"
            ),
            script)
        XCTAssertTrue(script.contains("tar xzf runner.tar.gz"), script)
        XCTAssertTrue(script.contains("bin/start.sh"), "the package's launcher is the install marker", )
        XCTAssertTrue(
            script.contains("releases/download/jdk-25.0.4.1+1/OpenJDK25U-jdk_aarch64_mac_hotspot_25.0.4.1_1.tar.gz"),
            script)
        XCTAssertTrue(script.contains(".sha256.txt"), "the JDK digest comes from Temurin's sidecar")
        XCTAssertTrue(script.contains("jdk/bin"), "the wrapper puts the JDK on PATH")
    }

    func testLinuxInstallScriptUsesTheOptLayout() {
        let script = RunnerBootstrap.linuxBitbucketRunnerInstallScript(
            version: "6.0.8", jdkVersion: "25.0.4.1+1")
        XCTAssertTrue(script.contains("/opt/bitbucket-runner/bin/start.sh"), script)
        XCTAssertTrue(script.contains("aarch64_linux"), script)
    }

    func testRunnerPackageDigestIsPinned() {
        XCTAssertEqual(
            RunnerVersionResolver.pinnedBitbucketRunnerDigests["6.0.8"]?.count, 64,
            "the pinned digest is a full SHA-256")
    }
}
