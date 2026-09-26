import XCTest

@testable import KinhinKit

final class HostRequirementsTests: XCTestCase {
    private func host(arm64: Bool = true, memoryGB: Int = 16, macOS major: Int = 26) -> HostFacts {
        HostFacts(
            arm64: arm64, memoryGB: memoryGB,
            osVersion: OperatingSystemVersion(majorVersion: major, minorVersion: 1, patchVersion: 0))
    }

    private func option(_ id: String) throws -> InstallOption {
        let all = InstallableTool.allCases.flatMap { RuntimeInstaller.options(for: $0) }
        return try XCTUnwrap(all.first { $0.id == id })
    }

    // MARK: - Apple container

    func testContainerIsSupportedOnAppleSiliconWithMacOS26() throws {
        XCTAssertEqual(HostRequirements.verdict(for: try option("container-brew"), on: host()), .supported)
    }

    func testContainerIsUnsupportedOnIntel() throws {
        let verdict = HostRequirements.verdict(for: try option("container-brew"), on: host(arm64: false))
        XCTAssertTrue(verdict.isUnsupported)
        XCTAssertTrue(verdict.reason?.contains("Apple silicon") ?? false)
    }

    func testContainerIsUnsupportedBelowMacOS26AndNamesTheVersion() throws {
        let verdict = HostRequirements.verdict(for: try option("container-brew"), on: host(macOS: 15))
        XCTAssertTrue(verdict.isUnsupported)
        XCTAssertTrue(verdict.reason?.contains("macOS 26") ?? false)
        XCTAssertTrue(verdict.reason?.contains("15.1") ?? false, "says what this Mac runs")
        XCTAssertNotNil(HostRequirements.blockingReason(for: .appleContainer, on: host(macOS: 15)))
    }

    // MARK: - Docker

    func testDockerDesktopNeedsFourGBOfRAM() throws {
        XCTAssertTrue(
            HostRequirements.verdict(for: try option("docker-desktop"), on: host(memoryGB: 2)).isUnsupported)
    }

    func testDockerDesktopOnOlderMacOSWarnsButIsOffered() throws {
        let verdict = HostRequirements.verdict(for: try option("docker-desktop"), on: host(macOS: 14))
        guard case .limited = verdict else { return XCTFail("expected a warning, got \(verdict)") }
        let offered = HostRequirements.offeredOptions(for: .docker, on: host(macOS: 14))
        XCTAssertTrue(offered.first { $0.id == "docker-desktop" }?.detail.contains("macOS 15") ?? false)
    }

    func testColimaAndOrbStackRunEverywhereSoDockerIsNeverBlocked() throws {
        let weak = host(arm64: false, memoryGB: 2, macOS: 14)
        XCTAssertEqual(HostRequirements.verdict(for: try option("docker-colima"), on: weak), .supported)
        XCTAssertEqual(HostRequirements.verdict(for: try option("docker-orbstack"), on: weak), .supported)
        XCTAssertNil(HostRequirements.blockingReason(for: .docker, on: weak))
        XCTAssertEqual(
            HostRequirements.offeredOptions(for: .docker, on: weak).map(\.id), ["docker-orbstack", "docker-colima"],
            "Docker Desktop is dropped, the rest stay")
    }

    func testEnsureSupportedThrowsTheReason() {
        XCTAssertThrowsError(try HostRequirements.ensureSupported(.appleContainer, on: host(arm64: false))) {
            XCTAssertTrue($0.localizedDescription.contains("Apple silicon"))
        }
        XCTAssertNoThrow(try HostRequirements.ensureSupported(.appleContainer, on: host()))
    }
}
