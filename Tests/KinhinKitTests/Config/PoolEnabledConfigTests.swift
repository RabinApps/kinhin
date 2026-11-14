import XCTest

@testable import KinhinKit

/// The per-pool `enabled:` switch: parsing, what the loader rejects, how a disabled pool drops out of the routing
/// table, capacity and `min_idle`, and that the editors keep the switch when they rewrite a section.
final class PoolEnabledConfigTests: XCTestCase {
    private static let head = """
        accounts:
          - name: github
            forge: github
            scope: "acme"
        labels: [self-hosted, arm64]
        max_runners: 10

        """

    private func parse(_ body: String) throws -> KinhinConfig {
        try ConfigLoader.parse(Self.head + body)
    }

    private func message(_ body: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try parse(body)
            XCTFail("expected the config to be rejected", file: file, line: line)
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Parsing

    func testEverythingIsEnabledByDefault() throws {
        let cfg = try parse("container: { image: kinhin-ci-linux }\ndocker: { image: kinhin-ci-linux }\n")
        XCTAssertEqual(cfg.container?.enabled, true)
        XCTAssertEqual(cfg.docker?.enabled, true)
        XCTAssertTrue(cfg.tartEnabled)
        XCTAssertNotNil(cfg.activeContainer)
        XCTAssertNotNil(cfg.activeDocker)
    }

    func testDisabledSectionsKeepTheirSettings() throws {
        let cfg = try parse(
            """
            container: { image: kinhin-ci-linux, cpus: 6, enabled: false }
            docker: { image: kinhin-ci-linux, max_slots: 3, enabled: false }
            """)
        XCTAssertEqual(cfg.container?.cpus, 6)
        XCTAssertEqual(cfg.docker?.maxSlots, 3)
        XCTAssertNil(cfg.activeContainer)
        XCTAssertNil(cfg.activeDocker)
    }

    func testTartCanBeSwitchedOffWhenAnotherPoolIsTheDefault() throws {
        let cfg = try parse(
            """
            container: { image: kinhin-ci-linux }
            runtimes:
              default: appleContainer
              tart:
                enabled: false
            """)
        XCTAssertFalse(cfg.tartEnabled)
        let model = RuntimeConfigModel(config: cfg)
        XCTAssertNil(model.pools[.tart])
        XCTAssertNotNil(model.pools[.appleContainer])
    }

    func testNamedPoolSwitchAndSectionSwitch() throws {
        let cfg = try parse(
            """
            container:
              image: kinhin-ci-linux
              pools:
                small: { labels: [small] }
                big: { labels: [big], enabled: false }
            """)
        XCTAssertEqual(cfg.container?.enabledPools.map(\.name), ["small"])
        let off = try parse(
            """
            container:
              enabled: false
              image: kinhin-ci-linux
              pools:
                small: { labels: [small], enabled: true }
            """)
        XCTAssertTrue(off.container?.enabledPools.isEmpty ?? false, "the section switch turns every pool off")
        XCTAssertNil(off.activeContainer)
    }

    // MARK: - Validation

    func testEveryPoolDisabledIsRejected() {
        let text = message(
            """
            container: { image: kinhin-ci-linux, enabled: false }
            runtimes:
              default: appleContainer
              tart: { enabled: false }
            """)
        XCTAssertTrue(text.contains("every pool is disabled"), text)
    }

    func testDefaultOrRouteOnADisabledPoolIsRejected() {
        let asDefault = message(
            """
            docker: { image: kinhin-ci-linux, enabled: false }
            runtimes: { default: tart, routes: [{ pattern: acme/api, runtime: docker }] }
            """)
        XCTAssertTrue(asDefault.contains("docker.enabled is false"), asDefault)

        let tartDefault = message(
            """
            container: { image: kinhin-ci-linux }
            runtimes: { tart: { enabled: false } }
            """)
        XCTAssertTrue(tartDefault.contains("runtimes.tart.enabled is false"), tartDefault)
    }

    func testUnknownKeyUnderTartIsStillReported() {
        let text = message("runtimes: { tart: { enable: false } }\n")
        XCTAssertTrue(text.contains("enable"), text)
    }

    func testDisabledPoolFloorDoesNotCountTowardMaxRunners() throws {
        // 8 + 8 would exceed max_runners: 10, but the Docker pool is off and holds no idle runners.
        XCTAssertNoThrow(
            try parse(
                """
                container: { image: kinhin-ci-linux, min_idle: 8 }
                docker: { image: kinhin-ci-linux, min_idle: 8, enabled: false }
                """))
    }

    // MARK: - Routing and capacity

    func testDisabledPoolsLeaveTheRoutingTableAndTheirLabelsLeaveServedLabels() throws {
        let cfg = try parse(
            """
            container: { image: kinhin-ci-linux, labels: [linux] }
            docker: { image: kinhin-ci-linux, enabled: false }
            runtimes: { default: tart }
            """)
        let model = RuntimeConfigModel(config: cfg)
        XCTAssertEqual(Set(model.pools.keys), [.tart, .appleContainer])
        XCTAssertNil(RuntimeConfigModel.poolLabels(for: .docker, config: cfg))
    }

    func testDisabledPoolGetsNoBudgetAndItsShareFallsToTheDefault() throws {
        let cfg = try parse(
            """
            container: { image: kinhin-ci-linux }
            docker: { image: kinhin-ci-linux, enabled: false }
            runtimes:
              default: tart
              budget: { appleContainer: 0.25, docker: 0.5 }
            """)
        let host = HostResources(logicalCores: 16, memoryGB: 64, freeDiskGB: 500, arm64: true)
        let caps = RuntimeCapacity.caps(for: cfg, host: host)
        XCTAssertNil(caps[.docker], "a disabled pool has no cap of its own")
        XCTAssertNotNil(caps[.appleContainer])
        // The same config without the Docker entry: Tart gets exactly the share Docker's weight would have taken.
        let without = try parse(
            """
            container: { image: kinhin-ci-linux }
            docker: { image: kinhin-ci-linux, enabled: false }
            runtimes:
              default: tart
              budget: { appleContainer: 0.25 }
            """)
        XCTAssertEqual(caps[.tart], RuntimeCapacity.caps(for: without, host: host)[.tart])
        XCTAssertEqual(
            RuntimeCapacity.enabledWeights(["docker": 0.5, "appleContainer": 0.25], in: cfg), ["appleContainer": 0.25])
    }

    func testDisabledPoolsKeepFloorsAboveTheCap() throws {
        XCTAssertNoThrow(
            try ConfigLoader.parse(
                """
                accounts:
                  - name: github
                    forge: github
                    scope: "acme"
                labels: [self-hosted, arm64]
                max_runners: 2
                container: { image: kinhin-ci-linux, min_idle: 3, enabled: false }
                docker: { image: kinhin-ci-linux, min_idle: 3, enabled: false }
                """))
    }

    func testReviewFollowUps() throws {
        // `test` is not an event type a webhook can select.
        XCTAssertTrue(
            message("alerts: { enabled: true, webhooks: [{ name: a, url: 'https://x.example/h', events: [test] }] }\n")
                .contains("unknown event type"))
        // A container whose every named pool is off cannot be the default.
        let allOff = message(
            """
            container:
              image: kinhin-ci-linux
              pools:
                a: { labels: [a], enabled: false }
            runtimes: { default: appleContainer, tart: { enabled: true } }
            """)
        XCTAssertTrue(allOff.contains("every container pool is disabled"), allOff)
        // Retained Tart floors do not count while Tart is off.
        XCTAssertNoThrow(
            try ConfigLoader.parse(
                """
                accounts:
                  - name: github
                    forge: github
                    scope: "acme"
                labels: [self-hosted, arm64]
                max_runners: 2
                image_min_idle: 1
                container: { image: kinhin-ci-linux, min_idle: 2 }
                runtimes: { default: appleContainer, tart: { enabled: false } }
                """))
        // Switching Tart needs an engine rebuild: its floors live in the frozen config.
        var on = try parse("container: { image: kinhin-ci-linux }\nruntimes: { default: appleContainer }\n")
        var off = on
        off.runtimes?.tartEnabled = false
        XCTAssertTrue(FleetEngine.restartRequired(from: on, to: off))
        on.runtimes?.tartEnabled = false
        XCTAssertFalse(FleetEngine.restartRequired(from: on, to: off))
    }

    func testPrimaryRuntimeSkipsADisabledContainer() throws {
        let cfg = try parse(
            """
            container: { image: kinhin-ci-linux, enabled: false }
            docker: { image: kinhin-ci-linux }
            """)
        XCTAssertEqual(Capacity.primaryRuntime(of: cfg), .docker)
    }

    // MARK: - Editors keep the switch

    func testSnapshotRewriteKeepsEnabledFalse() throws {
        let yaml =
            Self.head
                + """
                container:
                  enabled: false
                  image: kinhin-ci-linux
                  pools:
                    big: { image: kinhin-ci-linux, labels: [big], enabled: false }
                docker:
                  enabled: false
                  image: kinhin-ci-linux
                """
        let snapshot = try XCTUnwrap(try GeneralConfigEditor.snapshot(from: yaml))
        XCTAssertEqual(snapshot.container?.enabled, false)
        XCTAssertEqual(snapshot.docker?.enabled, false)
        XCTAssertEqual(snapshot.container?.pools.first?.enabled, false)
        let container = try XCTUnwrap(snapshot.container)
        let rewritten = GeneralConfigEditor.sectionText(container)
        XCTAssertTrue(rewritten.contains("enabled: false"), rewritten)
        // Parse what was written: the section switches and the named pool's switch all survive.
        let reparsed = try parse(rewritten + "\n" + GeneralConfigEditor.sectionText(try XCTUnwrap(snapshot.docker)))
        XCTAssertEqual(reparsed.container?.enabled, false)
        XCTAssertEqual(reparsed.docker?.enabled, false)
        XCTAssertEqual(reparsed.container?.pools.first?.name, "big")
        XCTAssertEqual(reparsed.container?.pools.first?.enabled, false)
    }

    func testRuntimesEditorRoundTripsTartSwitch() throws {
        var rc = KinhinConfig.RuntimeConfig(defaultRuntime: .appleContainer)
        rc.tartEnabled = false
        let text = RuntimesConfigEditor.sectionText(rc)
        XCTAssertTrue(text.contains("tart:\n    enabled: false"), text)
        let parsed = try XCTUnwrap(try RuntimesConfigEditor.parsed(from: text))
        XCTAssertFalse(parsed.tartEnabled)
    }

    func testPaneListsDisabledPoolsSeparately() async throws {
        let yaml =
            Self.head
                + """
                container: { image: kinhin-ci-linux }
                docker: { image: kinhin-ci-linux, enabled: false }
                runtimes: { default: tart }
                """
        let vm = await RuntimesPaneViewModel.load(
            configYAML: yaml, host: HostResources(logicalCores: 16, memoryGB: 64, freeDiskGB: 500, arm64: true),
            reserve: .init(cpu: 0, memoryGB: 0, diskGB: 0))
        XCTAssertEqual(vm.disabledPools, [.docker])
        XCTAssertFalse(vm.pools.contains { $0.runtime == .docker })
    }
}
