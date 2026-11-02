import XCTest

@testable import KinhinKit

/// `docker:` on `container:` and on each pool as `true` / `false` or `{ cache: false }`: the Docker Hub cache is on
/// whenever Docker is, pools inherit the section's whole `docker:` value, and every editor that rewrites the section
/// keeps the setting.
final class ContainerDockerCacheConfigTests: XCTestCase {
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

    // MARK: - Parsing

    func testTheCacheIsOnWheneverDockerIs() throws {
        let on = try container("  docker: true\n")
        XCTAssertTrue(on.docker)
        XCTAssertTrue(on.dockerCache)
        XCTAssertTrue(on.defaultPool.usesDockerCache)
        XCTAssertTrue(on.usesDockerCache)
    }

    func testWithoutDockerNothingUsesTheCache() throws {
        for keys in ["", "  docker: false\n"] {
            let off = try container(keys)
            XCTAssertFalse(off.docker, keys)
            XCTAssertTrue(off.dockerCache, "the default stays on, it just means nothing without Docker")
            XCTAssertFalse(off.defaultPool.usesDockerCache, keys)
            XCTAssertFalse(off.usesDockerCache, keys)
        }
    }

    func testTheMappingFormTurnsDockerOnAndTheCacheOff() throws {
        for keys in ["  docker: { cache: false }\n", "  docker:\n    cache: false\n"] {
            let section = try container(keys)
            XCTAssertTrue(section.docker, keys)
            XCTAssertFalse(section.dockerCache, keys)
            XCTAssertFalse(section.usesDockerCache, keys)
        }
    }

    func testAMappingAlwaysMeansDockerOn() throws {
        for keys in ["  docker: { cache: true }\n", "  docker: {}\n"] {
            let section = try container(keys)
            XCTAssertTrue(section.docker, keys)
            XCTAssertTrue(section.usesDockerCache, keys)
        }
    }

    func testTheMappingKeysAreKnownToTheSchema() throws {
        let yaml = """
            container:
              docker: { cache: false }
              pools:
                a: { docker: { cache: false } }
                b:
                  docker: true

            """
        XCTAssertEqual(try ConfigSchema.unknownKeys(in: yaml), [])
    }

    // MARK: - Validation

    func testAnUnknownKeyInTheMappingIsRejected() {
        let why = invalidMessage("  docker: { cahce: false }\n")
        XCTAssertTrue(why.contains("container.docker.cahce"), why)
        XCTAssertTrue(why.contains("container.docker.cache"), "suggests the key: \(why)")
    }

    func testAnUnknownKeyInAPoolsMappingIsRejected() {
        let why = invalidMessage("  pools:\n    a: { docker: { mirror: true } }\n")
        XCTAssertTrue(why.contains("container.pools.a.docker.mirror"), why)
    }

    func testAValueThatIsNeitherABoolNorAMappingIsRejected() {
        let why = invalidMessage("  docker: sometimes\n")
        XCTAssertTrue(why.contains("container.docker"), why)
        XCTAssertTrue(why.contains("true, false or a mapping such as { cache: false }"), why)
        let list = invalidMessage("  docker: [cache]\n")
        XCTAssertTrue(list.contains("true, false or a mapping"), list)
    }

    func testCacheMustBeABool() {
        let why = invalidMessage("  docker: { cache: sometimes }\n")
        XCTAssertTrue(why.contains("container.docker.cache"), why)
    }

    // MARK: - Pools

    func testPoolsInheritTheSectionsWholeDockerValue() throws {
        let section = try container(
            """
              docker: { cache: false }
              pools:
                inherits: { labels: [a] }
                plain: { labels: [b], docker: true }
                off: { labels: [c], docker: false }
                own: { labels: [d], docker: { cache: false } }

            """)
        let inherits = section.pool(named: "inherits")
        XCTAssertTrue(inherits.docker)
        XCTAssertFalse(inherits.usesDockerCache, "an omitted docker: brings the section's cache setting")
        XCTAssertTrue(section.pool(named: "plain").usesDockerCache, "docker: true gets the cache's default")
        XCTAssertFalse(section.pool(named: "off").docker)
        XCTAssertFalse(section.pool(named: "off").usesDockerCache)
        XCTAssertFalse(section.pool(named: "own").usesDockerCache)
        XCTAssertTrue(section.usesDockerCache, "one pool using the cache is enough")
    }

    func testAPoolCanTurnTheCacheOffUnderASectionThatUsesIt() throws {
        let section = try container(
            "  docker: true\n  pools:\n    a: { labels: [a] }\n    b: { labels: [b], docker: { cache: false } }\n")
        XCTAssertTrue(section.pool(named: "a").usesDockerCache)
        XCTAssertFalse(section.pool(named: "b").usesDockerCache)
        XCTAssertTrue(section.pool(named: "b").docker)
    }

    func testAnAmd64PoolUsesTheCacheToo() throws {
        let section = try container(
            "  docker: true\n  pools:\n    x64: { image: kinhin-ci-linux-x64, labels: [linux], platform: linux/amd64 }\n"
        )
        XCTAssertTrue(section.pool(named: "x64").usesDockerCache)
    }

    // MARK: - Editors keep it

    func testTheSnapshotCarriesTheSetting() throws {
        let yaml = Self.head + "  docker: { cache: false }\n  pools:\n    a: { docker: { cache: false } }\n"
        let snapshot = try XCTUnwrap(GeneralConfigEditor.snapshot(from: yaml).container)
        XCTAssertTrue(snapshot.docker)
        XCTAssertFalse(snapshot.dockerCache)
        XCTAssertEqual(snapshot.pools.first?.docker, true)
        XCTAssertEqual(snapshot.pools.first?.dockerCache, false)
        let defaults = try XCTUnwrap(GeneralConfigEditor.snapshot(from: Self.head + "  docker: true\n").container)
        XCTAssertTrue(defaults.dockerCache)
    }

    func testEditingTheContainerSectionKeepsTheCacheOff() throws {
        let yaml = Self.head + "  docker: { cache: false }\n"
        var edited = try XCTUnwrap(GeneralConfigEditor.snapshot(from: yaml).container)
        edited.cpus = 6
        let rewritten = try GeneralConfigEditor.replace(field: .container(edited), in: yaml)
        let section = try XCTUnwrap(ConfigLoader.parse(rewritten).container)
        XCTAssertEqual(section.cpus, 6)
        XCTAssertTrue(section.docker, rewritten)
        XCTAssertFalse(section.dockerCache, rewritten)
        XCTAssertTrue(rewritten.contains("  docker: { cache: false }"), rewritten)
    }

    func testTheSectionWriterSpellsTheDefaultAsTrue() {
        let on = GeneralConfigEditor.sectionText(.init(image: "kinhin-ci-linux", cpus: 4, memoryGB: 8, docker: true))
        XCTAssertTrue(on.contains("  docker: true"), on)
        let off = GeneralConfigEditor.sectionText(
            .init(image: "kinhin-ci-linux", cpus: 4, memoryGB: 8, docker: false, dockerCache: false))
        XCTAssertFalse(off.contains("docker"), "no Docker, nothing to write: \(off)")
    }

    func testAPoolWritesItsCacheSettingOnlyWithDockerOn() {
        typealias Pool = GeneralConfigEditor.Snapshot.ContainerPool
        XCTAssertEqual(
            Pool(name: "a", docker: true, dockerCache: false).lines(indent: ""), ["a:", "  docker: { cache: false }"])
        XCTAssertEqual(Pool(name: "a", docker: true).lines(indent: ""), ["a:", "  docker: true"])
        XCTAssertEqual(Pool(name: "a", docker: false, dockerCache: false).lines(indent: ""), ["a:", "  docker: false"])
        XCTAssertEqual(Pool(name: "a", dockerCache: false).lines(indent: ""), ["a: {}"], "no docker: key, no setting")
    }

    func testTheSpelledOutDefaultReadsAsTheDefault() throws {
        let yaml = Self.head + "  pools:\n    a: { docker: { cache: true } }\n"
        let pool = try XCTUnwrap(GeneralConfigEditor.snapshot(from: yaml).container?.pools.first)
        XCTAssertEqual(pool.docker, true)
        XCTAssertNil(pool.dockerCache, "{ cache: true } is written back as docker: true")
    }

    func testThePoolsEditorKeepsAPoolsCacheSetting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("docker-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try (Self.head + "  docker: { cache: false }\n  pools:\n    a: { labels: [a], docker: { cache: false } }\n")
            .write(to: url, atomically: true, encoding: .utf8)
        try ContainerPoolsConfigEditor.save(
            .init(name: "b", labels: ["b"], docker: true), replacing: nil, at: url)
        let section = try XCTUnwrap(ConfigLoader.load(from: url).container)
        XCTAssertFalse(section.dockerCache, "the section's setting stays")
        XCTAssertFalse(section.pool(named: "a").usesDockerCache, "the other pool's setting stays")
        XCTAssertTrue(section.pool(named: "b").usesDockerCache, "the new pool's docker: true gets the default")
    }

    func testTheStarterTemplateMentionsTheCache() throws {
        XCTAssertNil(try ConfigLoader.parse(ConfigLoader.template()).container)
        XCTAssertTrue(ConfigLoader.template().contains("docker: { cache: false }"))
    }
}
