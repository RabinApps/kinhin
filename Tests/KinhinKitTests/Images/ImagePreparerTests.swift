import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ImagePreparerTests: XCTestCase {
    /// Every prepare entry point builds its options from the config, so a
    /// configured `base_image:` is never silently dropped (two app buttons
    /// used to ignore it).
    func testOptionsFromConfigCarryBaseImageProvisionScriptAndCachePolicy() throws {
        var cfg = makeTestConfig()
        cfg.baseImage = "macos-sequoia-base"
        cfg.provisionScript = "/tmp/provision.sh"
        let options = ImagePreparer.Options(config: cfg)
        XCTAssertEqual(options.source, "ghcr.io/cirruslabs/macos-sequoia-base:latest")
        XCTAssertEqual(options.provisionScriptPath, "/tmp/provision.sh")
        XCTAssertNil(options.toolchains, "toolchains are per project; the fleet-wide options carry none")

        cfg.baseImage = nil
        XCTAssertEqual(ImagePreparer.Options(config: cfg).source, ImagePreparer.defaultSource)
    }

    /// An explicit registry reference in `base_image:` is used verbatim —
    /// it must never be rewritten to the default (a cirruslabs reference
    /// once got silently swapped for an unreachable openai one).
    func testOptionsFromConfigUseARegistryBaseImageVerbatim() throws {
        var cfg = makeTestConfig()
        cfg.baseImage = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
        XCTAssertEqual(
            ImagePreparer.Options(config: cfg).source, "ghcr.io/cirruslabs/macos-tahoe-base:latest")

        cfg.baseImage =
            "ghcr.io/cirruslabs/macos-tahoe-base@sha256:1b093499716409d29e8b5336844528e1cae375db97d2ad8e5aeff78cf0da201e"
        XCTAssertEqual(
            ImagePreparer.Options(config: cfg).source,
            "ghcr.io/cirruslabs/macos-tahoe-base@sha256:1b093499716409d29e8b5336844528e1cae375db97d2ad8e5aeff78cf0da201e"
        )
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

    func testPrepareTrustsTheGuestSSHKeyBeforeTheFirstSSHCall() async throws {
        let tart = FakeTart()
        let preparer = ImagePreparer(tart: tart, ssh: FakeSSH())
        try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false))
        let scratch = try XCTUnwrap(tart.cloneCalls.first?.name)
        XCTAssertEqual(tart.installKeyCalls.map(\.vm), [scratch])
        XCTAssertEqual(tart.installKeyCalls.map(\.user), ["admin"])
    }

    func testAKeyInstallFailureIsReportedWhenSSHThenFails() async throws {
        let tart = FakeTart()
        tart.failNext("installKey", stderr: "guest agent not running")
        let ssh = FakeSSH()
        ssh.failWith = "admin@192.168.65.2: Permission denied (publickey)"
        var preparer = ImagePreparer(tart: tart, ssh: ssh)
        preparer.guestKeyAttempts = 3
        preparer.guestKeyRetryDelay = .zero
        do {
            try await preparer.run(
                ImagePreparer.Options(
                    hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                    hasAzureDevOpsToken: false))
            XCTFail("expected the bake to fail")
        } catch let error as ImageError {
            guard case .provisioningFailed(let why) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertTrue(why.contains("Permission denied"), why)
            XCTAssertTrue(why.contains("guest agent not running"), why)
        }
        XCTAssertEqual(tart.installKeyCalls.count, 3, "retries while the guest agent comes up")
    }

    func testAKeyInstallFailureDoesNotStopABakeWhoseSSHWorks() async throws {
        let tart = FakeTart()
        tart.failNext("installKey", stderr: "no guest agent")
        var preparer = ImagePreparer(tart: tart, ssh: FakeSSH())
        preparer.guestKeyAttempts = 2
        preparer.guestKeyRetryDelay = .zero
        try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false))
        XCTAssertTrue(tart.cloneCalls.contains { $0.name == "tahoe-base" })
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

    // MARK: - Linux guests (tart Linux VMs)

    /// `image prepare --source <linux-vm>` detects the guest via `uname -s`
    /// and bakes the Linux agent binaries in the same $HOME layout.
    func testALinuxGuestBakesTheLinuxAgentBinaries() async throws {
        let ssh = FakeSSH()
        ssh.setStdout("Linux", forCall: 0)  // the guest-OS probe
        let preparer = ImagePreparer(tart: FakeTart(), ssh: ssh)
        try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: true, hasGiteaToken: true, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false))

        // First exec is the probe; second is the agent bake.
        XCTAssertEqual(ssh.scripts[0], "uname -s", "the probe is the first exec")
        let baked = ssh.scripts[1]
        XCTAssertTrue(baked.contains("actions-runner-linux-arm64-"), "Linux actions-runner binary")
        XCTAssertTrue(baked.contains("$HOME/actions-runner"), "same layout the registration script uses")
        // The agent versions resolve from the live release feeds, so match the platform suffix only.
        XCTAssertTrue(baked.contains("-linux-arm64.xz"), "Linux gitea-runner")
        XCTAssertFalse(baked.contains("osx-arm64"), "no macOS binaries on a Linux guest")
        XCTAssertFalse(baked.contains("darwin-arm64"), "no macOS binaries on a Linux guest")
        XCTAssertFalse(baked.contains("pmset"), "no macOS tweaks on a Linux guest")
        XCTAssertTrue(baked.contains("apt-get"), "prerequisites install through apt")
    }

    func testALinuxGuestBakesTheLinuxBitbucketRunner() async throws {
        let ssh = FakeSSH()
        ssh.setStdout("Linux", forCall: 0)
        let preparer = ImagePreparer(tart: FakeTart(), ssh: ssh)
        try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: false, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false, hasBitbucketToken: true))

        let baked = ssh.scripts[1]
        XCTAssertTrue(baked.contains("$HOME/bitbucket-runner"), "macOS-style layout: registration needs no change")
        XCTAssertTrue(baked.contains("aarch64_linux"), "Temurin JDK for aarch64 Linux")
        XCTAssertFalse(baked.contains("aarch64_mac"))
    }

    func testALinuxGuestBakesTheLinuxToolchainHelper() async throws {
        let ssh = FakeSSH()
        ssh.setStdout("Linux", forCall: 0)
        let preparer = ImagePreparer(tart: FakeTart(), ssh: ssh)
        try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false))

        let baked = ssh.scripts[1]
        XCTAssertTrue(baked.contains("/usr/local/bin/kinhin-toolchain"), "the helper is baked")
        XCTAssertTrue(
            baked.range(of: #"sudo mkdir -p /usr/local/bin"#) != nil,
            "a tart Linux guest is an admin user, not root")
        XCTAssertFalse(baked.contains("/Volumes/My Shared Files"), "no macOS virtiofs path on Linux")
    }

    func testALinuxGuestBakesLinuxManagedToolchains() async throws {
        let ssh = FakeSSH()
        ssh.setStdout("Linux", forCall: 0)
        let preparer = ImagePreparer(tart: FakeTart(), ssh: ssh)
        var options = ImagePreparer.Options(
            hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
            hasAzureDevOpsToken: false)
        options.toolchains = KinhinConfig.ToolchainsConfig(specs: ["node@22"], brew: ["wget"])

        try await preparer.run(options)

        // Execs: probe, agents, managed toolchains.
        XCTAssertEqual(ssh.scripts.count, 3)
        let managed = ssh.scripts[2]
        XCTAssertTrue(managed.contains("mise use --global 'node@22'"), managed)
        XCTAssertTrue(managed.contains("$SUDO apt-get"), "a tart Linux guest elevates through sudo")
        XCTAssertTrue(managed.contains("| sudo tee /etc/profile.d/kinhin-mise.sh"), "profile.d needs root")
        XCTAssertFalse(managed.contains("brew install"), "brew formulas never install on a Linux guest")
    }

    func testAnUnrecognizedGuestOSFailsTheBake() async throws {
        let tart = FakeTart()
        let ssh = FakeSSH()
        ssh.setStdout("FreeBSD", forCall: 0)
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        do {
            try await preparer.run(
                ImagePreparer.Options(
                    hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                    hasAzureDevOpsToken: false))
            XCTFail("expected the unrecognized guest to fail the bake")
        } catch let error as ImageError {
            guard case .provisioningFailed(let why) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(why.contains("FreeBSD"), why)
        }
        // Nothing was committed.
        XCTAssertFalse(tart.cloneCalls.contains { $0.name == "tahoe-base" })
    }

    func testALinuxGuestMountsTheSharedCacheBeforeTheBake() async throws {
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: FakeTart(), ssh: ssh)
        try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false, guestOS: .linux))

        let baked = ssh.scripts[0]
        let mount = try XCTUnwrap(baked.range(of: "mount -t virtiofs")).lowerBound
        let agent = try XCTUnwrap(baked.range(of: "actions-runner-linux-arm64-")).lowerBound
        XCTAssertLessThan(mount, agent, "the cache is mounted before anything downloads")
    }

    /// Parity with the container bakes: a tart Linux guest installs git and
    /// jq before any agent does — `actions/checkout`, `git ls-files` and
    /// jq-piping workflow steps need both, and no agent download installs
    /// them. The container baker (`LinuxImageBaker`) installs the same list.
    func testALinuxGuestInstallsGitAndJqBeforeAnyAgent() async throws {
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: FakeTart(), ssh: ssh)
        try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false, guestOS: .linux))

        let baked = ssh.scripts[0]
        XCTAssertTrue(baked.contains("command -v git"), "git must be checked for: \(baked)")
        XCTAssertTrue(baked.contains("command -v jq"), "jq must be checked for: \(baked)")
        let common = try XCTUnwrap(baked.range(of: "command -v git"), "no git prerequisite")
        let agent = try XCTUnwrap(baked.range(of: "actions-runner-linux-arm64-"), "no GitHub agent install")
        XCTAssertLessThan(common.upperBound, agent.lowerBound, "git installs before the agent does")
        // A guest runs as an admin user: apt goes through passwordless sudo,
        // unlike the container bake which runs as root.
        XCTAssertTrue(baked.contains("sudo -n true"), "the guest apt must go through sudo")

        let syntax = try await Shell().run(["/bin/bash", "-n", "-c", baked], cwd: nil, timeout: 10)
        XCTAssertTrue(syntax.succeeded, "composed tart Linux bake script: \(syntax.stderr)")
    }

    /// The macOS bake keeps its classic shape: no apt prerequisite block is
    /// injected for a Darwin guest (macOS images ship git with the CLT).
    func testAMacOSGuestInstallsNoAptGitAndJqBlock() async throws {
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: FakeTart(), ssh: ssh)
        try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false, guestOS: .macOS))

        let baked = ssh.scripts[0]
        XCTAssertFalse(baked.contains("command -v jq"), "no jq apt block on a macOS guest")
        XCTAssertFalse(baked.contains("apt-get install"), "no apt on a macOS guest")
    }

    func testAMacOSGuestDoesNotMountVirtiofsByHand() async throws {
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: FakeTart(), ssh: ssh)
        try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false, guestOS: .macOS))
        XCTAssertFalse(ssh.scripts[0].contains("mount -t virtiofs"))
    }

    func testAGuestOSOverrideSkipsTheProbe() async throws {
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: FakeTart(), ssh: ssh)
        try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false, guestOS: .linux))

        XCTAssertEqual(ssh.scripts.count, 1, "no probe exec when the guest OS is overridden: just the bake")
        XCTAssertTrue(ssh.scripts[0].contains("actions-runner-linux-arm64-"), "Linux agents baked directly")
    }

    func testAMacOSGuestKeepsTheClassicBake() async throws {
        let ssh = FakeSSH()
        ssh.setStdout("Darwin", forCall: 0)
        let preparer = ImagePreparer(tart: FakeTart(), ssh: ssh)
        try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false))

        XCTAssertEqual(ssh.scripts[0], "uname -s")
        XCTAssertTrue(ssh.scripts[1].contains("actions-runner-osx-arm64-"), "macOS guest → macOS binaries")
        XCTAssertTrue(ssh.scripts[1].contains("pmset"), "and the classic base tweaks")
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

    /// A failed prepare must clean up its scratch VM before the error reaches
    /// the caller: a CLI process exits right after, killing any
    /// fire-and-forget cleanup task (seen live: kinhin-prepare-tmp-* left on
    /// disk after a failed toolchain bake).
    func testImagePrepareFailureDeletesTheScratchVMInline() async throws {
        let tart = FakeTart()
        let ssh = FakeSSH()
        ssh.failWith = "sudo: a password is required"
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        let options = ImagePreparer.Options(
            hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
            hasAzureDevOpsToken: false)

        do {
            try await preparer.run(options)
            XCTFail("expected provisioning failure")
        } catch let error as ImageError {
            guard case .provisioningFailed = error else { return XCTFail("wrong error: \(error)") }
        }
        // Inline cleanup, not a background task the exiting CLI would kill.
        let scratch = try XCTUnwrap(tart.cloneCalls.first?.name)
        XCTAssertTrue(scratch.hasPrefix("kinhin-prepare-tmp-"), scratch)
        XCTAssertTrue(tart.stopCalls.contains(scratch), "scratch stopped on failure: \(tart.stopCalls)")
        XCTAssertTrue(tart.deleteCalls.contains(scratch), "scratch deleted on failure: \(tart.deleteCalls)")
    }

    /// A successful prepare also deletes its scratch VM: the target image is
    /// a clone peer, so nothing needs the scratch clone anymore.
    func testImagePrepareSuccessDeletesTheScratchVM() async throws {
        let tart = FakeTart()
        let preparer = ImagePreparer(tart: tart, ssh: FakeSSH())
        try await preparer.run(
            .init(
                hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false))
        let scratch = try XCTUnwrap(tart.cloneCalls.first?.name)
        XCTAssertTrue(scratch.hasPrefix("kinhin-prepare-tmp-"), scratch)
        XCTAssertTrue(tart.deleteCalls.contains(scratch), "scratch deleted after success: \(tart.deleteCalls)")
        XCTAssertNotNil(tart.vms["tahoe-base"], "the prepared image survives")
    }
}
