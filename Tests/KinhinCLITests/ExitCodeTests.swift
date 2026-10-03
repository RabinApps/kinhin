import XCTest

@testable import KinhinKit
@testable import kinhin

final class ExitCodeTests: XCTestCase {
    func testCodesAreStableAndDistinct() {
        XCTAssertEqual(
            [CLIExit.general, .usage, .config, .runtime, .auth].map(\.rawValue),
            [1, 2, 3, 4, 5], "scripts depend on these values")
    }

    func testCLIErrorCarriesItsOwnExitCode() {
        XCTAssertEqual(CLIExit(CLIError("bad flag", exit: .usage)), .usage)
        XCTAssertEqual(CLIExit(CLIError("oops")), .general)
        XCTAssertEqual(CLIError("bad flag").localizedDescription, "bad flag")
    }

    func testEngineErrorsMapToTheirArea() {
        XCTAssertEqual(CLIExit(ConfigError.notFound("/x")), .config)
        XCTAssertEqual(CLIExit(ConfigEditError.validation("bad")), .config)
        XCTAssertEqual(CLIExit(GitHubError.unauthorized), .auth)
        XCTAssertEqual(CLIExit(ForgeAPIError.unauthorized(forge: .gitea)), .auth)
        XCTAssertEqual(CLIExit(RPCError.connectionFailed("/sock")), .runtime)
        XCTAssertEqual(CLIExit(ImageError.noCredentials("none")), .runtime)
        XCTAssertEqual(CLIExit(TartError.ipNotFound(vm: "vm")), .runtime)
    }

    func testUnclassifiedErrorsExitOne() {
        struct Other: Error {}
        XCTAssertEqual(CLIExit(Other()), .general)
    }
}
