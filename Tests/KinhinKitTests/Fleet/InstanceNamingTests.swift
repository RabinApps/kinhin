import XCTest

@testable import KinhinKit

/// The instance-name seam: the fleet's prefix, the debug-only override the e2e suite uses, and the names it mints.
final class InstanceNamingTests: XCTestCase {
    func testNoOverrideMeansTheFleetPrefix() {
        XCTAssertEqual(InstanceNaming.resolvePrefix(environment: [:]), "kinhin-")
        XCTAssertEqual(InstanceNaming.resolvePrefix(environment: ["KINHIN_INSTANCE_PREFIX": ""]), "kinhin-")
    }

    #if DEBUG
        func testDebugOverrideReplacesThePrefix() {
            XCTAssertEqual(InstanceNaming.resolvePrefix(environment: ["KINHIN_INSTANCE_PREFIX": "ke2e-"]), "ke2e-")
        }
    #endif

    func testDefaultPrefixOwnsCurrentAndLegacyNames() {
        // Tests run in a build with no override, so `prefix` is the fleet's.
        XCTAssertEqual(InstanceNaming.prefix, "kinhin-")
        XCTAssertTrue(InstanceNaming.isOurs("kinhin-1760000000-abcd1234"))
        XCTAssertTrue(InstanceNaming.isOurs("orchard-1760000000-abcd1234"))
        XCTAssertFalse(InstanceNaming.isOurs("ke2e-1760000000-abcd1234"))
        XCTAssertFalse(InstanceNaming.isOurs("my-own-vm"))
    }

    func testMintedNamesCarryThePrefixAndMatchTheGeneratedPattern() {
        let name = VMRecord.newName(now: Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertTrue(name.hasPrefix(InstanceNaming.prefix))
        XCTAssertNotNil(name.range(of: InstanceNaming.generatedNamePattern, options: .regularExpression))
        XCTAssertTrue(VMRecord.isValidID(name))
    }

    func testGeneratedPatternRejectsAHandNamedInstance() {
        XCTAssertNil("kinhin-foo".range(of: InstanceNaming.generatedNamePattern, options: .regularExpression))
        let scratch = "kinhin-prepare-tmp-1760000000"
        XCTAssertNil(scratch.range(of: InstanceNaming.generatedNamePattern, options: .regularExpression))
    }
}
