import XCTest

@testable import KinhinKit

final class SupportLinksTests: XCTestCase {
    func testDonateChannelsAreHTTPS() {
        for channel in SupportLinks.donate {
            XCTAssertEqual(channel.url.scheme, "https", channel.name)
        }
    }

    func testBecomeASponsorIsMailto() {
        XCTAssertEqual(SupportLinks.becomeASponsor.url.scheme, "mailto")
    }

    func testSupDeskIsAProjectNotASponsor() {
        XCTAssertTrue(SupportLinks.projects.contains { $0.name == "SupDesk" })
        XCTAssertFalse(SupportLinks.sponsors.contains { $0.name == "SupDesk" })
    }

    func testSummaryListsEveryLink() {
        let text = SupportLinks.summary()
        for channel in SupportLinks.donate { XCTAssertTrue(text.contains(channel.url.absoluteString)) }
        XCTAssertTrue(text.contains("support@rabinapps.com"))
        XCTAssertTrue(text.contains("SupDesk"))
    }
}
