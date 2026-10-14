import Foundation
import XCTest

@testable import KinhinKit
@testable import kinhin

final class MobileCommandTests: XCTestCase {
    func testDefaultsAreAutoInTheCurrentFolder() throws {
        let request = try MobileCommand.parse([])
        XCTAssertEqual(request, MobileCommand.Request(framework: .auto, directory: ".", force: false, dryRun: false))
    }

    func testFlagsAndDirectoryParse() throws {
        let request = try MobileCommand.parse(["apps/mobile", "--framework", "react-native", "--force", "--dry-run"])
        XCTAssertEqual(
            request,
            MobileCommand.Request(framework: .reactNative, directory: "apps/mobile", force: true, dryRun: true))
    }

    func testTheValueAfterFrameworkIsNotTheDirectory() {
        XCTAssertEqual(MobileCommand.positionals(in: ["--framework", "flutter", "app"]), ["app"])
        XCTAssertEqual(MobileCommand.positionals(in: ["app", "--force"]), ["app"])
    }

    func testUnknownFrameworkIsAUsageError() {
        XCTAssertThrowsError(try MobileCommand.parse(["--framework", "nope"])) { error in
            XCTAssertEqual((error as? MobileCommand.UsageError)?.message.hasPrefix("unknown framework 'nope'"), true)
        }
    }

    func testEveryFrameworkNameIsAccepted() throws {
        for framework in MobileFramework.allCases {
            XCTAssertEqual(try MobileCommand.parse(["--framework", framework.rawValue]).framework, framework)
        }
    }

    func testProjectErrorsExitWithUsageAndWriteErrorsWithGeneral() {
        XCTAssertEqual(MobileCommand.exitCode(for: .noProject(directory: "/x")), .usage)
        XCTAssertEqual(MobileCommand.exitCode(for: .noPlatformFolder(framework: .flutter, directory: "/x")), .usage)
        XCTAssertEqual(MobileCommand.exitCode(for: .cannotWrite(path: "x", reason: "y")), .general)
        XCTAssertEqual(MobileCommand.exitCode(for: .unreadableGemfile(path: "x")), .general)
    }
}
