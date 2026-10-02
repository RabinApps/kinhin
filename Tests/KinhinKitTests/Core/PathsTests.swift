import XCTest

@testable import KinhinKit

/// Paths.findExecutable: override is authoritative, then PATH, then brew prefixes.
final class PathsTests: XCTestCase {
    func testOverrideWinsOverPATHWhenItExists() throws {
        let real = try XCTUnwrap(Paths.findExecutable(named: "sh"))
        XCTAssertEqual(Paths.findExecutable(named: "sh", override: real), real)
    }

    /// An explicit override pointing at nothing is a misconfiguration: it
    /// reports missing rather than probing PATH/Homebrew behind the user's
    /// back (kinhin doctor must never bless a runtime the config doesn't use).
    func testMissingOverrideIsAuthoritative() {
        // A nonexistent override reports missing — no silent PATH fallback.
        XCTAssertNil(Paths.findExecutable(named: "tart", override: "/nonexistent/kinhin-test/sh"))
        // An empty override means "not configured": normal discovery applies.
        XCTAssertNotNil(Paths.findExecutable(named: "sh", override: ""))
    }
}
