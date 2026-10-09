import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The String Catalog is packaged and resolves at runtime: plural variations agree in English, and the
/// formatters follow the locale they are given.
final class L10nStringsTests: XCTestCase {
    func testCatalogIsFoundByCode() {
        // SwiftPM compiles Localizable.xcstrings into <lang>.lproj inside the resource bundle; `Bundle.l10n`
        // finds it under `swift test`, `swift run` and the bundled app alike.
        let bundle = Bundle.l10n
        let compiled =
            bundle.url(forResource: "Localizable", withExtension: "stringsdict", subdirectory: nil, localization: "en")
            ?? bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en")
        XCTAssertNotNil(compiled, "the compiled String Catalog is missing from \(bundle.bundlePath)")
    }

    func testPluralVariationsAgreeInEnglish() {
        func runners(_ n: Int) -> String {
            String(localized: "kinhin, \(n) runners", bundle: .l10n, comment: "test of the plural catalog entry")
        }
        XCTAssertEqual(runners(0), "kinhin, 0 runners")
        XCTAssertEqual(runners(1), "kinhin, 1 runner")
        XCTAssertEqual(runners(2), "kinhin, 2 runners")
    }

    func testPluralOfFirstArgumentWithASecondNumber() {
        func summary(_ n: Int, busy: Int) -> String {
            String(
                localized: "\(n) instances · \(busy) busy", bundle: .l10n, comment: "test of the plural catalog entry")
        }
        XCTAssertEqual(summary(1, busy: 1), "1 instance · 1 busy")
        XCTAssertEqual(summary(3, busy: 0), "3 instances · 0 busy")
        func capped(_ n: Int, cap: Int) -> String {
            String(localized: "\(n) instances · cap \(cap)", bundle: .l10n, comment: "test of the plural catalog entry")
        }
        XCTAssertEqual(capped(1, cap: 4), "1 instance · cap 4")
        XCTAssertEqual(capped(2, cap: 4), "2 instances · cap 4")
    }

    @MainActor
    func testAppSurfacesUseThePluralEntries() {
        XCTAssertEqual(LogsModel().statusText, "0 lines")
        var status = FleetStatus(running: true)
        status.queueDepth = 1
        XCTAssertTrue(FleetSummary.status(status).contains("1 job queued."))
        status.queueDepth = 2
        XCTAssertTrue(FleetSummary.status(status).contains("2 jobs queued."))
    }

    func testDurationFollowsTheGivenLocale() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(AppFormat.duration(5, locale: english), "5s")
        XCTAssertEqual(AppFormat.duration(66, locale: english), "1m 6s")
        // Another language spells the same duration differently; what matters is that nothing hand-built leaks in.
        XCTAssertNotEqual(AppFormat.duration(66, locale: Locale(identifier: "ja_JP")), "1m 6s")
    }

    func testRelativeTimeFollowsTheGivenLocale() {
        let now = Date()
        let twoHoursAgo = now.addingTimeInterval(-2 * 3600)
        XCTAssertEqual(AppFormat.relative(twoHoursAgo, to: now, locale: Locale(identifier: "en_US")), "2 hours ago")
        XCTAssertNotEqual(AppFormat.relative(twoHoursAgo, to: now, locale: Locale(identifier: "es_ES")), "2 hours ago")
    }
}
