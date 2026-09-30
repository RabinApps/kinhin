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

    func testFromClonesAPreconfiguredImageWithoutAnInstallStep() async throws {
        let tart = FakeTart()

        try await TartLinuxVMCreator(tart: tart).run(
            TartLinuxVMCreator.Options(
                name: "linux-base", from: "ghcr.io/cirruslabs/ubuntu:latest"))

        XCTAssertEqual(tart.cloneCalls.count, 1)
        XCTAssertEqual(tart.cloneCalls.first?.source, "ghcr.io/cirruslabs/ubuntu:latest")
        XCTAssertEqual(tart.cloneCalls.first?.name, "linux-base")
        // No bare VM, no ISO boot, no registry pull of our own: tart's clone
        // pulls the image implicitly.
        XCTAssertTrue(tart.createLinuxCalls.isEmpty)
        XCTAssertTrue(tart.runWithDiskCalls.isEmpty)
        XCTAssertTrue(tart.pullCalls.isEmpty)
        XCTAssertFalse(tart.deleteCalls.contains("linux-base"))
    }

    func testFromRejectsArgvHazardousReferencesBeforeCloning() async throws {
        let tart = FakeTart()

        do {
            try await TartLinuxVMCreator(tart: tart).run(
                TartLinuxVMCreator.Options(name: "x", from: "--privileged"))
            XCTFail("expected the hazardous reference to throw")
        } catch let error as ImageError {
            guard case .provisioningFailed(let why) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertTrue(why.contains("'-'"), why)
        }
        XCTAssertTrue(tart.cloneCalls.isEmpty)
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
        // A tart whose runWithDisk fails: the creator must delete the freshly
        // created VM instead of stranding it. (A real ISO path is required:
        // validation runs before the VM is created.)
        let tart = FakeTart()
        tart.failNext("runWithDisk", stderr: "boot failed")
        let iso = try makeISO()
        defer { try? FileManager.default.removeItem(atPath: iso) }

        do {
            try await TartLinuxVMCreator(tart: tart).run(
                TartLinuxVMCreator.Options(name: "doomed", isoPath: iso))
            XCTFail("expected the boot failure to throw")
        } catch {}

        XCTAssertEqual(tart.createLinuxCalls, ["doomed"])
        XCTAssertEqual(tart.deleteCalls, ["doomed"], "the unusable VM must be deleted, never stranded")
    }
}
