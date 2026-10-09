import XCTest

@testable import KinhinKit

/// Validation errors name the YAML key the user wrote (never a Swift property),
/// carry the real failure reason, and reject out-of-range values.
final class ConfigValidationMessagesTests: XCTestCase {
    private static let account = """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        """

    private func invalidMessage(_ yaml: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try ConfigLoader.parse(yaml)
            XCTFail("expected a ConfigError", file: file, line: line)
            return ""
        } catch ConfigError.invalid(let why) {
            return why
        } catch {
            XCTFail("expected ConfigError.invalid, got \(error)", file: file, line: line)
            return ""
        }
    }

    // MARK: - Key names, not Swift names

    func testVMMemoryErrorNamesTheConfigKey() {
        let why = invalidMessage("\(Self.account)\nvm:\n  memory_gb: 1\n")
        XCTAssertTrue(why.contains("vm.memory_gb"), why)
        XCTAssertFalse(why.contains("memoryGB"), why)
    }

    func testWarmPoolParsesAndDefaultsToOff() throws {
        XCTAssertEqual(try ConfigLoader.parse(Self.account).warmPool, 0)
        let cfg = try ConfigLoader.parse("\(Self.account)\nwarm_pool: 1\nwarm_max_age_minutes: 30\n")
        XCTAssertEqual(cfg.warmPool, 1)
        XCTAssertEqual(cfg.warmMaxAgeMinutes, 30)
    }

    func testWarmPoolBeyondMaxRunnersIsRejected() {
        let why = invalidMessage("\(Self.account)\nmax_runners: 2\nwarm_pool: 3\n")
        XCTAssertTrue(why.contains("warm_pool"), why)
        XCTAssertTrue(invalidMessage("\(Self.account)\nwarm_max_age_minutes: 1\n").contains("warm_max_age_minutes"))
    }

    func testPollIntervalErrorIsNotGitHubSpecific() {
        let why = invalidMessage("\(Self.account)\npoll_interval: 1\n")
        XCTAssertTrue(why.contains("poll_interval"), why)
        XCTAssertFalse(why.contains("GitHub"), why)
    }

    func testWrongTypedValueNamesTheKey() {
        let why = invalidMessage("\(Self.account)\nmax_runners: four\n")
        XCTAssertTrue(why.contains("max_runners"), why)
        let nested = invalidMessage("\(Self.account)\nvm:\n  cpu: lots\n")
        XCTAssertTrue(nested.contains("vm.cpu"), nested)
    }

    func testYAMLSyntaxErrorIsAConfigError() {
        let why = invalidMessage("labels: [unterminated\n")
        XCTAssertTrue(why.contains("not valid YAML"), why)
    }

    // MARK: - The real reason a read failed

    func testUnreadableConfigSurfacesTheUnderlyingReason() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A directory exists but cannot be read as text.
        XCTAssertThrowsError(try ConfigLoader.load(from: dir)) { error in
            guard case ConfigError.unreadable(let path, let reason) = error else {
                return XCTFail("expected unreadable, got \(error)")
            }
            XCTAssertEqual(path, dir.path)
            XCTAssertFalse(reason.isEmpty)
            XCTAssertTrue(error.localizedDescription.contains(reason), error.localizedDescription)
        }
    }

    func testNonUTF8ConfigReportsWhy() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).yaml")
        try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ConfigLoader.load(from: url)) { error in
            guard case ConfigError.unreadable(_, let reason) = error else {
                return XCTFail("expected unreadable, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    // MARK: - Ranges

    func testVMBootTimeoutIsRangeChecked() throws {
        for bad in [0, 29, 3601, -5] {
            let why = invalidMessage("\(Self.account)\nvm_boot_timeout: \(bad)\n")
            XCTAssertTrue(why.contains("vm_boot_timeout"), why)
        }
        XCTAssertEqual(try ConfigLoader.parse("\(Self.account)\nvm_boot_timeout: 30\n").vmBootTimeout, 30)
        XCTAssertEqual(try ConfigLoader.parse("\(Self.account)\nvm_boot_timeout: 3600\n").vmBootTimeout, 3600)
    }

    func testTokenTTLIsRangeChecked() throws {
        for bad in [0, 59, 3601, -1] {
            let why = invalidMessage("\(Self.account)\ntoken_ttl: \(bad)\n")
            XCTAssertTrue(why.contains("token_ttl"), why)
        }
        XCTAssertEqual(try ConfigLoader.parse("\(Self.account)\ntoken_ttl: 60\n").tokenTTL, 60)
        XCTAssertEqual(try ConfigLoader.parse("\(Self.account)\ntoken_ttl: 3600\n").tokenTTL, 3600)
    }

    // MARK: - Defaults have one source

    func testOmittedKeysTakeTheDefaultConfigValues() throws {
        let cfg = try ConfigLoader.parse(Self.account)
        let d = KinhinConfig.default
        XCTAssertEqual(cfg.minRunners, d.minRunners)
        XCTAssertEqual(cfg.maxRunners, d.maxRunners)
        XCTAssertEqual(cfg.runnersPerVM, d.runnersPerVM)
        XCTAssertEqual(cfg.pollInterval, d.pollInterval)
        XCTAssertEqual(cfg.autoResume, d.autoResume)
        XCTAssertEqual(cfg.vm, d.vm)
        XCTAssertEqual(cfg.tokenTTL, d.tokenTTL)
        XCTAssertEqual(cfg.vmBootTimeout, d.vmBootTimeout)
        XCTAssertEqual(cfg.reserve, d.reserve)
    }

    func testTemplateAgreesWithTheDefaults() throws {
        // The starter template spells out max_runners; it must match what omitting it gives.
        let template = try ConfigLoader.parse(ConfigLoader.template())
        XCTAssertEqual(template.maxRunners, KinhinConfig.default.maxRunners)
        XCTAssertEqual(template.minRunners, KinhinConfig.default.minRunners)
    }

    func testContainerAndDockerDefaultsComeFromTheirTypes() throws {
        let cfg = try ConfigLoader.parse(
            "\(Self.account)\ncontainer:\n  image: ubuntu-runner\ndocker:\n  image: ubuntu-runner\n")
        XCTAssertEqual(cfg.container, KinhinConfig.ContainerConfig(image: "ubuntu-runner"))
        XCTAssertEqual(cfg.docker, KinhinConfig.DockerForgeConfig(image: "ubuntu-runner"))
    }

    // MARK: - Runtime names

    func testRuntimeNamesComeFromRuntimeID() throws {
        for id in RuntimeID.allCases where id != .host {
            var yaml =
                "\(Self.account)\ncontainer:\n  image: img\ndocker:\n  image: img\nruntimes:\n  default: \(id.rawValue)\n"
            yaml += "  budget:\n    \(id.rawValue): 0.5\n"
            XCTAssertNoThrow(try ConfigLoader.parse(yaml), "\(id) must be accepted")
        }
    }

    func testUnknownRuntimeSuggestsTheClosestName() {
        let why = invalidMessage("\(Self.account)\nruntimes:\n  default: tarts\n")
        XCTAssertTrue(why.contains("unknown runtime 'tarts'"), why)
        XCTAssertTrue(why.contains("did you mean 'tart'?"), why)
        for id in RuntimeID.allCases {
            XCTAssertTrue(why.contains(id.rawValue), "known list must include \(id): \(why)")
        }
        let route = invalidMessage(
            "\(Self.account)\nruntimes:\n  routes:\n    - pattern: acme/widgets\n      runtime: dokcer\n")
        XCTAssertTrue(route.contains("did you mean 'docker'?"), route)
    }
}
