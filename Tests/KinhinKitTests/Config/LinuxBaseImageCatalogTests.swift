import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class LinuxBaseImageCatalogTests: XCTestCase {
    func testCuratedListIsValidUniqueAndIncludesTheDefault() {
        let references = LinuxBaseImage.curated.map(\.reference)
        XCTAssertEqual(Set(references).count, references.count, "no duplicates")
        XCTAssertEqual(Set(LinuxBaseImage.curated.map(\.title)).count, references.count, "titles are distinct")
        XCTAssertTrue(references.contains(LinuxBaseImage.defaultReference))
        for reference in references {
            XCTAssertNil(LinuxBaseImage.problem(with: reference), reference)
            XCTAssertTrue(
                reference.hasPrefix("ubuntu:") || reference.hasPrefix("debian:"),
                "\(reference): install scripts use apt-get, so bases must be Debian or Ubuntu")
        }
    }
}
