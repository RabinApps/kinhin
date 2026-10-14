import XCTest

@testable import KinhinKit

final class HealingConfigTests: XCTestCase {
    private let accounts = """
        accounts:
          - name: github
            forge: github
            scope: acme/widgets

        """

    func testDefaultsWhenAbsent() throws {
        let config = try ConfigLoader.parse(accounts)
        XCTAssertEqual(config.healing, .default)
        XCTAssertTrue(config.healing.enabled)
        XCTAssertEqual(config.healing.auto, .safe)
        XCTAssertEqual(config.healing.ai, .auto)
        XCTAssertEqual(config.healing.maxAttempts, 3)
    }

    func testEveryKeyParses() throws {
        let config = try ConfigLoader.parse(
            accounts + """
                healing:
                  enabled: false
                  auto: none
                  ai: off
                  max_attempts: 5
                """)
        XCTAssertEqual(
            config.healing, KinhinConfig.HealingConfig(enabled: false, auto: .none, ai: .off, maxAttempts: 5))
    }

    func testBadValuesAreRejectedByName() {
        XCTAssertThrowsError(try ConfigLoader.parse(accounts + "healing:\n  auto: sometimes\n")) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("healing.auto"))
        }
        XCTAssertThrowsError(try ConfigLoader.parse(accounts + "healing:\n  ai: cloud\n")) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("healing.ai"))
        }
        XCTAssertThrowsError(try ConfigLoader.parse(accounts + "healing:\n  max_attempts: 0\n")) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("healing.max_attempts"))
        }
    }

    func testUnknownKeysAreReported() {
        XCTAssertThrowsError(try ConfigLoader.parse(accounts + "healing:\n  enable: true\n")) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("healing.enable"))
        }
    }

    func testAPolicyChangeRebuildsTheEngine() {
        var changed = KinhinConfig.default
        changed.healing.auto = .none
        XCTAssertTrue(FleetEngine.restartRequired(from: .default, to: changed))
    }
}
