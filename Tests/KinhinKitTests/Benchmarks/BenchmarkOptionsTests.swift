import XCTest

@testable import KinhinKit

final class BenchmarkOptionsTests: XCTestCase {
    func testDefaultsRunEveryQuickSuiteButToolchains() {
        let options = BenchmarkOptions()
        XCTAssertEqual(options.suites, [.boot, .casual, .xcode, .large])
        XCTAssertFalse(options.suites.contains(.toolchains), "the hours-long pass is opt-in")
        XCTAssertEqual(options.intensity, .quick)
        XCTAssertNoThrow(try options.validate())
    }

    func testIterationsAreCapped() {
        XCTAssertThrowsError(try BenchmarkOptions(iterations: 0).validate())
        XCTAssertThrowsError(try BenchmarkOptions(iterations: BenchmarkLimits.maxIterations + 1).validate())
        XCTAssertNoThrow(try BenchmarkOptions(iterations: BenchmarkLimits.maxIterations).validate())
    }

    func testNetworkURLAcceptsOnlyGitSchemes() throws {
        for good in [
            "https://github.com/apple/swift-log.git", "ssh://git@example.com/x.git", "git://example.com/x.git",
        ] {
            XCTAssertEqual(try BenchmarkOptions.validatedGitURL(good), good)
        }
        for bad in [
            "http://example.com/x.git", "file:///etc/passwd", "ext::sh -c id", "--upload-pack=touch /tmp/x",
            "https://exam ple.com/x", "git@github.com:acme/x.git", "", "https://", "ftp://example.com/x",
            "https://example.com/x\nrm -rf",
        ] {
            XCTAssertThrowsError(try BenchmarkOptions.validatedGitURL(bad), bad) { error in
                guard case BenchmarkError.invalidOption = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testProjectMustBeAnExistingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNoThrow(try BenchmarkOptions.validatedProjectDirectory(directory.path))
        XCTAssertThrowsError(
            try BenchmarkOptions.validatedProjectDirectory(directory.appendingPathComponent("nope").path))
        let file = directory.appendingPathComponent("file.txt")
        try Data().write(to: file)
        XCTAssertThrowsError(try BenchmarkOptions.validatedProjectDirectory(file.path))
        XCTAssertThrowsError(try BenchmarkOptions.validatedProjectDirectory("/tmp/a\nb"))
    }

    func testHostNeedsExplicitConsent() {
        XCTAssertThrowsError(try BenchmarkOptions(runtimes: [.host]).validate())
        XCTAssertNoThrow(try BenchmarkOptions(runtimes: [.host], includeHost: true).validate())
    }

    func testToolchainIDsMustExist() {
        XCTAssertThrowsError(try BenchmarkOptions(suites: [.toolchains], toolchains: ["nodejs"]).validate())
        XCTAssertNoThrow(try BenchmarkOptions(suites: [.toolchains], toolchains: ["node", "flutter"]).validate())
    }

    func testThoroughToolchainsMustBeScoped() {
        XCTAssertThrowsError(try BenchmarkOptions(suites: [.toolchains], intensity: .thorough).validate())
        XCTAssertNoThrow(
            try BenchmarkOptions(suites: [.toolchains], intensity: .thorough, toolchains: ["go"]).validate())
        XCTAssertNoThrow(
            try BenchmarkOptions(suites: [.toolchains], intensity: .thorough, allToolchains: true).validate())
        XCTAssertNoThrow(
            try BenchmarkOptions(suites: [.toolchains], intensity: .quick).validate(),
            "a quick pass is minutes, so unscoped is fine")
    }

    func testProfilesStayInsideTheHardCaps() {
        let quick = BenchmarkProfile.make(.quick, iterations: nil)
        let thorough = BenchmarkProfile.make(.thorough, iterations: nil)
        XCTAssertEqual(quick.iterations, 1)
        XCTAssertEqual(thorough.iterations, 3)
        XCTAssertGreaterThan(thorough.treeMB, quick.treeMB)
        XCTAssertLessThanOrEqual(thorough.blobMB, BenchmarkLimits.maxPayloadMB)
        XCTAssertEqual(BenchmarkProfile.make(.quick, iterations: 99).iterations, BenchmarkLimits.maxIterations)
        XCTAssertEqual(BenchmarkProfile.make(.thorough, iterations: 2).iterations, 2)
    }

    func testOptionsRoundTripThroughJSON() throws {
        let options = BenchmarkOptions(
            suites: [.boot, .toolchains], intensity: .thorough, iterations: 2, runtimes: [.tart, .docker],
            toolchains: ["go"], includeHost: true, networkURL: "https://example.com/x.git", keep: true, confirmed: true)
        let data = try JSONEncoder().encode(options)
        XCTAssertEqual(try JSONDecoder().decode(BenchmarkOptions.self, from: data), options)
    }
}
