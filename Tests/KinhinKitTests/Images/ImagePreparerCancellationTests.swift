import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Cancelling an image bake must never leak the scratch VM nor half-replace
/// the target image: cancellation unwinds at phase boundaries, the teardown
/// runs uncancelled, and the commit swap (stop → delete target → clone) runs
/// to completion once it has begun.
@MainActor
final class ImagePreparerCancellationTests: XCTestCase {
    private func makeOptions(target: String = "tahoe-base") -> ImagePreparer.Options {
        var options = ImagePreparer.Options(
            hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
            hasAzureDevOpsToken: false)
        options.source = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
        options.target = target
        return options
    }

    /// Cancelling while the agent-install SSH exec runs removes the scratch VM
    /// (the teardown must run even though the caller is cancelled) and never
    /// touches the target image.
    func testCancelMidBakeRemovesTheScratchVMAndKeepsTheTarget() async throws {
        let tart = FakeTart()
        let ssh = FakeSSH()
        ssh.blockOnCall(1)  // 0 is the uname probe; 1 is the agent install
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        let options = makeOptions()

        let task = Task { try await preparer.run(options) }
        await ssh.waitUntilBlocked()
        task.cancel()
        ssh.releaseBlocked()

        do {
            try await task.value
            XCTFail("expected the cancelled bake to throw CancellationError")
        } catch is CancellationError {
            // expected
        }

        let scratch = try XCTUnwrap(tart.cloneCalls.first?.name)
        XCTAssertTrue(scratch.hasPrefix(ImagePreparer.scratchPrefix))
        XCTAssertEqual(tart.stopCalls, [scratch], "the uncancelled teardown stopped the scratch VM")
        XCTAssertEqual(tart.deleteCalls, [scratch], "the uncancelled teardown deleted the scratch VM")
        XCTAssertFalse(
            tart.cloneCalls.contains { $0.name == options.target },
            "a cancelled bake never commits the target image")
    }

    /// A cancel that lands DURING the commit swap (which runs uncancelled) is
    /// absorbed: the swap completes, the target is replaced, and the bake
    /// reports success.
    func testCancelDuringTheCommitSwapDoesNotHalfReplaceTheTarget() async throws {
        let tart = FakeTart()
        tart.vms = ["tahoe-base": TartVM(name: "tahoe-base", source: "", status: "stopped")]
        tart.blockNextStop()  // the commit swap's first step
        let preparer = ImagePreparer(tart: tart, ssh: FakeSSH())
        let options = makeOptions()

        let task = Task { try await preparer.run(options) }
        await tart.waitUntilStopParked()
        task.cancel()  // lands while the uncancelled commit is parked mid-swap
        tart.releaseStop()

        try await task.value  // succeeds: the commit ran to completion

        let scratch = try XCTUnwrap(tart.cloneCalls.first?.name)
        XCTAssertEqual(tart.stopCalls, [scratch])
        XCTAssertEqual(
            tart.deleteCalls, [options.target, scratch], "old image replaced in the swap, scratch deleted after")
        XCTAssertEqual(tart.cloneCalls.last?.name, options.target, "the new image was committed")
        XCTAssertEqual(tart.vms[options.target]?.source, scratch)
    }

    /// Cancellation between the provision exec and the commit leaves the
    /// previous target image intact and removes the scratch VM.
    func testCancelBeforeTheCommitKeepsTheTargetUntouched() async throws {
        let tart = FakeTart()
        tart.vms = ["tahoe-base": TartVM(name: "tahoe-base", source: "", status: "stopped")]
        let ssh = FakeSSH()
        ssh.blockOnCall(1)
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        let options = makeOptions()

        let task = Task { try await preparer.run(options) }
        await ssh.waitUntilBlocked()
        task.cancel()
        ssh.releaseBlocked()
        do {
            try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {}

        let scratch = try XCTUnwrap(tart.cloneCalls.first?.name)
        XCTAssertFalse(
            tart.deleteCalls.contains("tahoe-base"), "the previous target image stays untouched")
        XCTAssertEqual(tart.stopCalls, [scratch])
        XCTAssertEqual(tart.deleteCalls, [scratch])
    }

    /// A bake sweeps leftover scratch VMs from earlier crashed or killed bakes
    /// before starting, and never touches non-scratch VMs.
    func testBakeSweepsLeftoverScratchVMsFirst() async throws {
        let tart = FakeTart()
        tart.vms = [
            "kinhin-prepare-tmp-123": TartVM(name: "kinhin-prepare-tmp-123", source: "old-base", status: "running"),
            "kinhin-runner-1": TartVM(name: "kinhin-runner-1", source: "tahoe-base", status: "running"),
            "tahoe-base": TartVM(name: "tahoe-base", source: "", status: "stopped"),
        ]
        let preparer = ImagePreparer(tart: tart, ssh: FakeSSH())
        let options = makeOptions()

        try await preparer.run(options)

        XCTAssertTrue(tart.deleteCalls.contains("kinhin-prepare-tmp-123"), "the leftover was swept")
        XCTAssertFalse(tart.deleteCalls.contains("kinhin-runner-1"), "runner VMs are never swept")
        XCTAssertEqual(
            tart.deleteCalls.filter { $0.hasPrefix(ImagePreparer.scratchPrefix) }.count, 2,
            "the leftover and this bake's own scratch were both deleted")
        XCTAssertEqual(tart.cloneCalls.last?.name, options.target)
    }
}
