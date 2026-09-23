import XCTest
@testable import orchard

final class CLICommandTests: XCTestCase {
    // MARK: routing table

    func testCommandRouting() {
        XCTAssertEqual(CLICommand.parse(["config"]), .configInit)
        XCTAssertEqual(CLICommand.parse(["config", "init"]), .configInit)
        XCTAssertEqual(CLICommand.parse(["auth"]), .auth)
        XCTAssertEqual(CLICommand.parse(["auth", "set"]), .auth)
        XCTAssertEqual(CLICommand.parse(["auth", "status"]), .auth)
        XCTAssertEqual(CLICommand.parse(["auth", "clear"]), .auth)
        XCTAssertEqual(CLICommand.parse(["doctor"]), .doctor)
        XCTAssertEqual(CLICommand.parse(["setup-status"]), .setupStatus)
        XCTAssertEqual(CLICommand.parse(["setup-status", "--json"]), .setupStatus)
        XCTAssertEqual(CLICommand.parse(["image"]), .imagePrepare)
        XCTAssertEqual(CLICommand.parse(["image", "prepare"]), .imagePrepare)
        XCTAssertEqual(CLICommand.parse(["image", "prepare", "--container"]), .imagePrepare)
        XCTAssertEqual(CLICommand.parse(["start"]), .start)
        XCTAssertEqual(CLICommand.parse(["stop"]), .stop)
        XCTAssertEqual(CLICommand.parse(["pause"]), .pause)
        XCTAssertEqual(CLICommand.parse(["resume"]), .resume)
        XCTAssertEqual(CLICommand.parse(["status"]), .status)
        XCTAssertEqual(CLICommand.parse(["status", "--json"]), .status)
        XCTAssertEqual(CLICommand.parse(["watch"]), .watch)
        XCTAssertEqual(CLICommand.parse(["logs"]), .logs)
        XCTAssertEqual(CLICommand.parse(["logs", "-n", "10"]), .logs)
        XCTAssertEqual(CLICommand.parse(["daemon"]), .daemon)
        XCTAssertEqual(CLICommand.parse(["daemon", "install"]), .daemon)
        XCTAssertEqual(CLICommand.parse(["daemon", "uninstall"]), .daemon)
        XCTAssertEqual(CLICommand.parse(["version"]), .version)
        XCTAssertEqual(CLICommand.parse(["--version"]), .version)
        XCTAssertEqual(CLICommand.parse(["-v"]), .version)
        XCTAssertEqual(CLICommand.parse(["help"]), .help)
        XCTAssertEqual(CLICommand.parse(["--help"]), .help)
        XCTAssertEqual(CLICommand.parse(["-h"]), .help)
        // No arguments behaves like `help`.
        XCTAssertEqual(CLICommand.parse([]), .help)
    }

    func testHeadTokenDispatchIgnoresSubcommandTokens() {
        // Historical behavior: only the head token routes. `config bogus` ran
        // `configInit` before this refactor and still does — pinned so the
        // surface cannot silently change meaning.
        XCTAssertEqual(CLICommand.parse(["config", "bogus-subcommand"]), .configInit)
    }

    func testUnknownCommandReturnsNil() {
        XCTAssertNil(CLICommand.parse(["frobnicate"]))
        XCTAssertNil(CLICommand.parse(["--unknown-flag"]))
        XCTAssertNil(CLICommand.parse(["CONFIG"])) // dispatch is case-sensitive
    }

    // MARK: starter-config auto-create exemptions

    func testNoOpCommandsAreExemptFromAutoCreate() {
        XCTAssertFalse(CLICommand.shouldAutoCreateConfig(.help))
        XCTAssertFalse(CLICommand.shouldAutoCreateConfig(.version))
        XCTAssertFalse(CLICommand.shouldAutoCreateConfig(.configInit))
    }

    func testWorkingCommandsAutoCreate() {
        let working: [CLICommand] = [
            .auth, .doctor, .setupStatus, .imagePrepare, .start, .stop,
            .pause, .resume, .status, .watch, .logs, .daemon,
        ]
        for command in working {
            XCTAssertTrue(CLICommand.shouldAutoCreateConfig(command), "\(command) should auto-create")
        }
    }

    func testUnknownCommandAutoCreates() {
        // The original switch's `default` arm ran before help+fail, so an
        // unknown command still materialized the starter config.
        XCTAssertTrue(CLICommand.shouldAutoCreateConfig(nil))
    }

    // MARK: tiny flag parser

    func testFlagParsing() {
        XCTAssertEqual(flag("-n", in: ["logs", "-n", "10"]), "10")
        XCTAssertEqual(flag("--json", in: ["status", "--json", "pretty"]), "pretty")
        // First occurrence wins.
        XCTAssertEqual(flag("-n", in: ["logs", "-n", "5", "-n", "9"]), "5")
    }

    func testFlagParsingMisses() {
        XCTAssertNil(flag("-n", in: ["logs"]))
        // Dangling flag at the end has no value.
        XCTAssertNil(flag("-n", in: ["logs", "-n"]))
        XCTAssertNil(flag("--missing", in: ["logs", "-n", "5"]))
    }

    func testHasFlag() {
        XCTAssertTrue(hasFlag("--force", in: ["config", "init", "--force"]))
        XCTAssertFalse(hasFlag("--force", in: ["config", "init"]))
        // Exact-token match: no substring matching.
        XCTAssertFalse(hasFlag("force", in: ["--force"]))
    }
}
