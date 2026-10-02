import XCTest

@testable import KinhinKit

final class VersionFileProbeTests: XCTestCase {
    func testSingleVersionFilesAndAliases() throws {
        let fixture = try ProjectFixture([
            ".nvmrc": "v22.1.0\n", ".python-version": "3.12.4\n",
            ".tool-versions": "nodejs 20.11.0\ngolang 1.22.5 # pinned\n",
        ])
        let hits = try VersionFileProbe().hits(in: fixture.reader)
        XCTAssertTrue(hits.contains { $0.id == "node" && $0.version == "v22.1.0" && $0.source == ".nvmrc" })
        XCTAssertTrue(hits.contains { $0.id == "node" && $0.version == "20.11.0" && $0.source == ".tool-versions" })
        XCTAssertTrue(hits.contains { $0.id == "go" && $0.version == "1.22.5" })
        XCTAssertTrue(hits.contains { $0.id == "python" && $0.version == "3.12.4" })
        XCTAssertTrue(hits.allSatisfy { $0.precedence == .versionFile })
    }

    func testMiseTomlToolsSection() throws {
        let fixture = try ProjectFixture([
            "mise.toml": """
            [env]
            FOO = "bar"
            [tools]
            node = "22"
            python = ["3.12", "3.11"]
            go = { version = "1.23" }
            """
        ])
        let hits = try VersionFileProbe().hits(in: fixture.reader).map { "\($0.id)=\($0.version ?? "-")" }
        XCTAssertEqual(hits, ["node=22", "python=3.12", "go=1.23"])
    }
}
