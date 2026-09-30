import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ImagePreparerTests: XCTestCase {
    /// Every prepare entry point builds its options from the config, so a
    /// configured `base_image:` is never silently dropped (two app buttons
    /// used to ignore it).
    func testOptionsFromConfigCarryBaseImageProvisionScriptAndToolchains() throws {
        var cfg = makeTestConfig()
        cfg.baseImage = "macos-sequoia-base"
        cfg.provisionScript = "/tmp/provision.sh"
        let options = ImagePreparer.Options(config: cfg)
        XCTAssertEqual(options.source, "ghcr.io/cirruslabs/macos-sequoia-base:latest")
        XCTAssertEqual(options.provisionScriptPath, "/tmp/provision.sh")
        XCTAssertEqual(options.toolchains, cfg.toolchains)

        cfg.baseImage = nil
        XCTAssertEqual(ImagePreparer.Options(config: cfg).source, ImagePreparer.defaultSource)
    }

    func testImagePrepareHappyPath() async throws {
        let tart = FakeTart()
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        var options = ImagePreparer.Options(
            hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
            hasAzureDevOpsToken: false)
        options.source = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
        options.target = "tahoe-base"

        try await preparer.run(options)

        XCTAssertEqual(tart.pullCalls, ["ghcr.io/cirruslabs/macos-tahoe-base:latest"])
        // First clone: source -> scratch; last clone: scratch -> target.
        XCTAssertEqual(tart.cloneCalls.first?.source, options.source)
        XCTAssertEqual(tart.cloneCalls.last?.name, options.target)
        let scratch = try XCTUnwrap(tart.cloneCalls.first?.name)
        XCTAssertNotEqual(scratch, options.target, "scratch VM must differ from the target")
        // The final clone sources from the scratch VM.
        XCTAssertEqual(tart.cloneCalls.last?.source, scratch)
        XCTAssertEqual(tart.vms[options.target]?.source, scratch)
    }

    func testABuildkiteTokenAloneBakesOnlyTheBuildkiteAgent() async throws {
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: FakeTart(), ssh: ssh)
        try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: false, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: true))

        let baked = ssh.scripts.joined(separator: "\n")
        XCTAssertTrue(baked.contains("buildkite-agent-darwin-arm64-"), "the agent is baked")
        XCTAssertTrue(baked.contains("tar xzf agent.tar.gz ./buildkite-agent"))
        XCTAssertFalse(baked.contains("actions-runner-osx"), "no GitHub token: no actions-runner")
    }

    func testAnAzureDevOpsTokenAloneBakesOnlyTheAzureAgent() async throws {
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: FakeTart(), ssh: ssh)
        try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: false, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: true))

        let baked = ssh.scripts.joined(separator: "\n")
        XCTAssertTrue(baked.contains("vsts-agent-osx-arm64-"), "the agent is baked")
        XCTAssertTrue(baked.contains("$HOME/azure-agent"), "as the template runners clone")
        XCTAssertFalse(baked.contains("buildkite-agent-darwin"))
    }

    func testImagePrepareSkipsTheRegistryPullForALocalSourceVM() async throws {
        // A locally created VM (tart create --linux, then OS-installed) is not
        // a registry reference — pulling it would fail. Names without a slash
        // are treated as local and used as-is.
        let tart = FakeTart()
        let preparer = ImagePreparer(tart: tart, ssh: FakeSSH())
        var options = ImagePreparer.Options(
            hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
            hasAzureDevOpsToken: false)
        options.source = "ubuntu-scratch"
        options.target = "ubuntu-base"

        try await preparer.run(options)

        XCTAssertTrue(tart.pullCalls.isEmpty, "a local VM is never pulled")
        XCTAssertEqual(tart.cloneCalls.first?.source, "ubuntu-scratch")
        XCTAssertEqual(tart.cloneCalls.last?.name, "ubuntu-base")
    }

    func testImagePrepareReplacesExistingTarget() async throws {
        let tart = FakeTart()
        tart.vms["tahoe-base"] = TartVM(name: "tahoe-base", source: "old-source", status: "stopped")
        let preparer = ImagePreparer(tart: tart, ssh: FakeSSH())
        var options = ImagePreparer.Options(
            hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
            hasAzureDevOpsToken: false)
        options.target = "tahoe-base"

        try await preparer.run(options)

        XCTAssertTrue(tart.deleteCalls.contains("tahoe-base"), "old image is deleted before the new one lands")
        // The final clone targeted the same name and sourced from the scratch VM.
        XCTAssertEqual(tart.cloneCalls.last?.name, "tahoe-base")
        let scratch = try XCTUnwrap(tart.cloneCalls.first?.name)
        XCTAssertEqual(tart.vms["tahoe-base"]?.source, scratch, "target now sources from the fresh scratch clone")
    }

    func testImagePrepareProvisioningFailureLeavesTargetUntouched() async throws {
        let tart = FakeTart()
        let ssh = FakeSSH()
        ssh.failWith = "sudo: a password is required"
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        var options = ImagePreparer.Options(
            hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
            hasAzureDevOpsToken: false)
        options.target = "tahoe-base"

        do {
            try await preparer.run(options)
            XCTFail("expected provisioning failure")
        } catch let error as ImageError {
            guard case .provisioningFailed(let why) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(why.contains("password"))
        }
        // The target must NOT have been created from the failed scratch VM.
        XCTAssertNil(tart.vms["tahoe-base"])
        XCTAssertFalse(tart.deleteCalls.contains("tahoe-base"))
        XCTAssertFalse(tart.cloneCalls.contains { $0.name == "tahoe-base" })
    }
}
