import XCTest

@testable import KinhinKit

/// The #107 options on `container:`: `registry_cache_ttl_hours` (section only, shared by every pool) and
/// `docker: { build_cache: true }` (section and pools, off by default), parsed, validated and kept by every editor
/// that rewrites the section.
final class ContainerCacheOptionsConfigTests: XCTestCase {
    private static let head = """
        accounts:
          - name: github
            forge: github
            scope: "acme"
        labels: [self-hosted, arm64]
        max_runners: 10
        container:
          image: kinhin-ci-linux

        """

    private func container(_ keys: String) throws -> KinhinConfig.ContainerConfig {
        try XCTUnwrap(ConfigLoader.parse(Self.head + keys).container)
    }

    private func invalidMessage(_ keys: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try ConfigLoader.parse(Self.head + keys)
            XCTFail("expected a ConfigError for:\n\(keys)", file: file, line: line)
            return ""
        } catch ConfigError.invalid(let why) {
            return why
        } catch {
            XCTFail("expected ConfigError.invalid, got \(error)", file: file, line: line)
            return ""
        }
    }

    // MARK: - registry_cache_ttl_hours

    func testTheTTLDefaultsToTwoWeeks() throws {
        let section = try container("  docker: true\n")
        XCTAssertNil(section.registryCacheTTLHours)
        XCTAssertEqual(section.effectiveRegistryCacheTTLHours, 336)
    }

    func testTheTTLCanBeSetOrTurnedOff() throws {
        XCTAssertEqual(try container("  registry_cache_ttl_hours: 720\n").effectiveRegistryCacheTTLHours, 720)
        XCTAssertEqual(try container("  registry_cache_ttl_hours: 0\n").effectiveRegistryCacheTTLHours, 0)
    }

    func testTheTTLIsKeptWithPools() throws {
        let section = try container("  registry_cache_ttl_hours: 0\n  pools:\n    a: { docker: true }\n")
        XCTAssertEqual(section.registryCacheTTLHours, 0)
    }

    func testANegativeOrHugeTTLIsRejected() {
        for value in ["-1", "87601"] {
            let why = invalidMessage("  registry_cache_ttl_hours: \(value)\n")
            XCTAssertTrue(why.contains("container.registry_cache_ttl_hours"), why)
            XCTAssertTrue(why.contains("never expire"), "says what 0 means: \(why)")
        }
    }

    func testThePoolsHaveNoTTLOfTheirOwn() {
        let why = invalidMessage("  pools:\n    a: { registry_cache_ttl_hours: 0 }\n")
        XCTAssertTrue(why.contains("container.pools.a.registry_cache_ttl_hours"), why)
    }

    // MARK: - build_cache

    func testTheBuildCacheIsOffByDefault() throws {
        let section = try container("  docker: true\n")
        XCTAssertFalse(section.dockerBuildCache)
        XCTAssertFalse(section.defaultPool.usesDockerBuildCache)
    }

    func testTheBuildCacheIsTurnedOnInTheMapping() throws {
        for keys in ["  docker: { build_cache: true }\n", "  docker:\n    build_cache: true\n    cache: false\n"] {
            let section = try container(keys)
            XCTAssertTrue(section.docker, keys)
            XCTAssertTrue(section.dockerBuildCache, keys)
            XCTAssertTrue(section.defaultPool.usesDockerBuildCache, keys)
        }
        XCTAssertTrue(try container("  docker: { build_cache: true }\n").usesDockerCache, "the pull cache stays on")
    }

    func testPoolsInheritOrSetTheBuildCache() throws {
        let section = try container(
            """
              docker: { build_cache: true }
              pools:
                inherits: { labels: [a] }
                plain: { labels: [b], docker: true }
                own: { labels: [c], docker: { build_cache: true } }

            """)
        let byName = Dictionary(uniqueKeysWithValues: section.pools.map { ($0.name, $0.usesDockerBuildCache) })
        XCTAssertEqual(byName, ["inherits": true, "plain": false, "own": true])
    }

    func testTheBuildCacheKeyIsKnownToTheSchema() throws {
        let yaml = """
            container:
              docker: { build_cache: true }
              registry_cache_ttl_hours: 0
              pools:
                a: { docker: { build_cache: true, cache: false } }

            """
        XCTAssertEqual(try ConfigSchema.unknownKeys(in: yaml), [])
    }

    // MARK: - Editors keep both

    func testEditingTheContainerSectionKeepsBothOptions() throws {
        let yaml =
            Self.head
            + "  docker: { cache: false, build_cache: true }\n  registry_cache_ttl_hours: 0\n"
            + "  pools:\n    a: { labels: [a], docker: { build_cache: true } }\n"
        var edited = try XCTUnwrap(GeneralConfigEditor.snapshot(from: yaml).container)
        XCTAssertTrue(edited.dockerBuildCache)
        XCTAssertEqual(edited.registryCacheTTLHours, 0)
        XCTAssertEqual(edited.pools.first?.dockerBuildCache, true)
        edited.cpus = 6
        let rewritten = try GeneralConfigEditor.replace(field: .container(edited), in: yaml)
        let section = try XCTUnwrap(ConfigLoader.parse(rewritten).container)
        XCTAssertEqual(section.cpus, 6)
        XCTAssertTrue(section.dockerBuildCache, rewritten)
        XCTAssertFalse(section.dockerCache, rewritten)
        XCTAssertEqual(section.registryCacheTTLHours, 0, rewritten)
        XCTAssertEqual(section.pools.first?.dockerBuildCache, true, rewritten)
    }

    func testTheWriterSpellsOnlyWhatDiffersFromTheDefaults() {
        XCTAssertEqual(GeneralConfigEditor.dockerValue(cache: true), "true")
        XCTAssertEqual(GeneralConfigEditor.dockerValue(cache: false), "{ cache: false }")
        XCTAssertEqual(GeneralConfigEditor.dockerValue(cache: true, buildCache: true), "{ build_cache: true }")
        XCTAssertEqual(
            GeneralConfigEditor.dockerValue(cache: false, buildCache: true), "{ cache: false, build_cache: true }")
        typealias Pool = GeneralConfigEditor.Snapshot.ContainerPool
        XCTAssertEqual(
            Pool(name: "a", docker: true, dockerBuildCache: true).lines(indent: ""),
            ["a:", "  docker: { build_cache: true }"])
        XCTAssertEqual(
            Pool(name: "a", docker: false, dockerBuildCache: true).lines(indent: ""), ["a:", "  docker: false"])
    }
}
