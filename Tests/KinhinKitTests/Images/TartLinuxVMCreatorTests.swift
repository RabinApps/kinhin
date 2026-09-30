import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The "Linux VM image from scratch" flow (tart.run quick-start): kinhin
/// creates the bare VM with `tart create --linux`, optionally boots it once
/// with install media attached, and leaves the interactive OS install — and
/// the follow-up `image prepare --source <vm>` — to the user.
final class TartLinuxVMCreatorTests: XCTestCase {
    private func makeISO() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-install-\(UUID().uuidString).iso")
        try Data("iso".utf8).write(to: url)
        return url.path
    }

    func testCreateWithISOBootsTheInstallMediaOnce() async throws {
        let tart = FakeTart()
        let iso = try makeISO()
        defer { try? FileManager.default.removeItem(atPath: iso) }

        try await TartLinuxVMCreator(tart: tart).run(TartLinuxVMCreator.Options(name: "ubuntu-scratch", isoPath: iso))

        XCTAssertEqual(tart.createLinuxCalls, ["ubuntu-scratch"])
        XCTAssertEqual(tart.runWithDiskCalls.count, 1)
        XCTAssertEqual(tart.runWithDiskCalls.first?.name, "ubuntu-scratch")
        XCTAssertEqual(tart.runWithDiskCalls.first?.isoPath, iso)
        // No registry traffic and no clones: the VM IS the product here.
        XCTAssertTrue(tart.pullCalls.isEmpty)
        XCTAssertTrue(tart.cloneCalls.isEmpty)
        XCTAssertFalse(tart.deleteCalls.contains("ubuntu-scratch"), "a successful create is never rolled back")
    }

    func testCreateWithoutISOBootsTheBareVM() async throws {
        let tart = FakeTart()

        try await TartLinuxVMCreator(tart: tart).run(TartLinuxVMCreator.Options(name: "bare-linux"))

        XCTAssertEqual(tart.createLinuxCalls, ["bare-linux"])
        XCTAssertEqual(tart.runCalls, ["bare-linux"], "no ISO → plain boot, no --disk")
        XCTAssertTrue(tart.runWithDiskCalls.isEmpty)
    }

    func testNameCollisionFailsBeforeAnythingIsCreated() async throws {
        let tart = FakeTart()
        tart.vms["taken"] = TartVM(name: "taken", source: "old", status: "stopped")

        do {
            try await TartLinuxVMCreator(tart: tart).run(TartLinuxVMCreator.Options(name: "taken"))
            XCTFail("expected the name collision to throw")
        } catch let error as ImageError {
            guard case .provisioningFailed(let why) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertTrue(why.contains("already exists"), why)
        }
        XCTAssertTrue(tart.createLinuxCalls.isEmpty, "an existing VM must never be clobbered")
    }

    func testMissingISOFailsBeforeTheVMIsCreated() async throws {
        let tart = FakeTart()

        do {
            try await TartLinuxVMCreator(tart: tart).run(
                TartLinuxVMCreator.Options(name: "never-created", isoPath: "/nonexistent/install.iso"))
            XCTFail("expected the missing ISO to throw")
        } catch let error as ImageError {
            guard case .provisioningFailed(let why) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertTrue(why.contains("does not exist"), why)
        }
        XCTAssertTrue(tart.createLinuxCalls.isEmpty, "a bad ISO must not leave an empty VM behind")
    }

    func testBootFailureRollsBackTheCreatedVM() async throws {
        // A tart double whose runWithDisk always fails: the creator must
        // delete the freshly created VM instead of stranding it. (A real ISO
        // path is required: validation runs before the VM is created.)
        final class FailingBoot: TartControlling, Sendable {
            private let state = Mutex((created: [String](), deleted: [String]()))
            var created: [String] { state.withLock { $0.created } }
            var deleted: [String] { state.withLock { $0.deleted } }
            func list() async throws -> [TartVM] { [] }
            func clone(source: String, to name: String) async throws {}
            func run(name: String, mounts: [String]) async throws {}
            func run(name: String) async throws {}
            func ip(of name: String, timeout: TimeInterval) async throws -> String { "" }
            func sshExec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws
                -> ShellResult
            { ShellResult(exitCode: 1, stdout: "", stderr: "boot failed") }
            func stop(name: String) async throws {}
            func delete(name: String) async throws { state.withLock { $0.deleted.append(name) } }
            func pull(image: String) async throws {}
            func createLinux(name: String) async throws { state.withLock { $0.created.append(name) } }
            func runWithDisk(name: String, isoPath: String) async throws {
                throw TartError.commandFailed(what: "run --disk", stderr: "boot failed")
            }
        }
        let tart = FailingBoot()
        let iso = try makeISO()
        defer { try? FileManager.default.removeItem(atPath: iso) }

        do {
            try await TartLinuxVMCreator(tart: tart).run(
                TartLinuxVMCreator.Options(name: "doomed", isoPath: iso))
            XCTFail("expected the boot failure to throw")
        } catch {}

        XCTAssertEqual(tart.created, ["doomed"])
        XCTAssertEqual(tart.deleted, ["doomed"], "the unusable VM must be deleted, never stranded")
    }
}
