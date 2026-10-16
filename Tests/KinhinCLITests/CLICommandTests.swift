import XCTest

@testable import kinhin

final class CLICommandTests: XCTestCase {
    // MARK: - routing table

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
        XCTAssertEqual(CLICommand.parse(["setup", "repair", "host-agent"]), .setupRepair)
        XCTAssertEqual(CLICommand.parse(["image"]), .imagePrepare)
        XCTAssertEqual(CLICommand.parse(["image", "prepare"]), .imagePrepare)
        XCTAssertEqual(CLICommand.parse(["image", "prepare", "--container"]), .imagePrepare)
        XCTAssertEqual(CLICommand.parse(["image", "list"]), .imageList)
        XCTAssertEqual(CLICommand.parse(["image", "ls"]), .imageList)
        XCTAssertEqual(CLICommand.parse(["image", "delete", "tahoe-base"]), .imageDelete)
        XCTAssertEqual(CLICommand.parse(["image", "rm", "tahoe-base"]), .imageDelete)
        XCTAssertEqual(CLICommand.parse(["image", "prune"]), .imagePrune)
        XCTAssertEqual(CLICommand.parse(["image", "prune", "--yes"]), .imagePrune)
        // `image digest` used to fall through to prepare (the head switch
        // only saw "image") and started a bake; the two-token table routes it.
        XCTAssertEqual(CLICommand.parse(["image", "digest", "ghcr.io/x:latest"]), .imageDigest)
        XCTAssertEqual(CLICommand.parse(["start"]), .start)
        XCTAssertEqual(CLICommand.parse(["stop"]), .stop)
        XCTAssertEqual(CLICommand.parse(["pause"]), .pause)
        XCTAssertEqual(CLICommand.parse(["resume"]), .resume)
        XCTAssertEqual(CLICommand.parse(["status"]), .status)
        XCTAssertEqual(CLICommand.parse(["status", "--json"]), .status)
        XCTAssertEqual(CLICommand.parse(["watch"]), .watch)
        XCTAssertEqual(CLICommand.parse(["pipeline"]), .pipeline)
        XCTAssertEqual(CLICommand.parse(["pipeline", "kinhin-1", "--job", "build"]), .pipeline)
        XCTAssertEqual(CLICommand.parse(["pipelines"]), .pipeline)
        XCTAssertEqual(CLICommand.parse(["logs"]), .logs)
        XCTAssertEqual(CLICommand.parse(["logs", "-n", "10"]), .logs)
        XCTAssertEqual(CLICommand.parse(["daemon"]), .daemon)
        XCTAssertEqual(CLICommand.parse(["daemon", "install"]), .daemon)
        XCTAssertEqual(CLICommand.parse(["daemon", "uninstall"]), .daemon)
        XCTAssertEqual(CLICommand.parse(["support"]), .support)
        XCTAssertEqual(CLICommand.parse(["sponsor"]), .support)
        XCTAssertEqual(CLICommand.parse(["version"]), .version)
        XCTAssertEqual(CLICommand.parse(["--version"]), .version)
        XCTAssertEqual(CLICommand.parse(["-v"]), .version)
        XCTAssertEqual(CLICommand.parse(["help"]), .help)
        XCTAssertEqual(CLICommand.parse(["--help"]), .help)
        XCTAssertEqual(CLICommand.parse(["-h"]), .help)
        XCTAssertEqual(CLICommand.parse(["mcp"]), .mcp)
        // No arguments behaves like `help`.
        XCTAssertEqual(CLICommand.parse([]), .help)
    }

    func testHeadTokenDispatchIgnoresSubcommandTokens() {
        // Historical behavior: only the head token routes. `config bogus` ran
        // `configInit` before this refactor and still does — pinned so the
        // surface cannot silently change meaning.
        XCTAssertEqual(CLICommand.parse(["config", "bogus-subcommand"]), .configInit)
        // An unknown `image` subcommand still means prepare (bare `image`
        // and `image prepare` are the same command), only the listed pairs
        // in `twoTokenHeads` route elsewhere.
        XCTAssertEqual(CLICommand.parse(["image", "frobnicate"]), .imagePrepare)
    }

    /// The subcommands that parse their own operands get the head tokens
    /// stripped, in both spellings the router accepts.
    func testImageSubcommandArgumentsAreStripped() throws {
        XCTAssertEqual(try CommandResolver.resolve(["image", "digest", "ghcr.io/x"]).rest, ["ghcr.io/x"])
        XCTAssertEqual(try CommandResolver.resolve(["image", "list"]).rest, [])
        XCTAssertEqual(try CommandResolver.resolve(["image", "delete", "a", "--yes"]).rest, ["a", "--yes"])
        XCTAssertEqual(try CommandResolver.resolve(["image", "prune", "--yes"]).rest, ["--yes"])
        XCTAssertEqual(try CommandResolver.resolve(["image digest", "ghcr.io/x"]).rest, ["ghcr.io/x"])
    }

    func testNormalizedSpellingsRouteLikeTheLegacyOnes() {
        XCTAssertEqual(CLICommand.parse(["setup", "status"]), .setupStatus)
        XCTAssertEqual(CLICommand.parse(["setup", "status", "--json"]), .setupStatus)
        XCTAssertEqual(CLICommand.parse(["setup", "repair", "tart"]), .setupRepair)
        XCTAssertEqual(CLICommand.parse(["config", "validate"]), .configInit)
        XCTAssertEqual(CLICommand.parse(["workflow", "route", "ci.yml", "tart"]), .workflow)
        XCTAssertEqual(CLICommand.parse(["toolchains", "prune"]), .toolchains)
    }

    func testUnknownCommandReturnsNil() {
        XCTAssertNil(CLICommand.parse(["frobnicate"]))
        XCTAssertNil(CLICommand.parse(["--unknown-flag"]))
        XCTAssertNil(CLICommand.parse(["CONFIG"]))  // dispatch is case-sensitive
    }

    // MARK: - starter-config auto-create exemptions

    func testNoOpCommandsAreExemptFromAutoCreate() {
        XCTAssertFalse(CLICommand.shouldAutoCreateConfig(.help))
        XCTAssertFalse(CLICommand.shouldAutoCreateConfig(.version))
        XCTAssertFalse(CLICommand.shouldAutoCreateConfig(.support))
        XCTAssertFalse(CLICommand.shouldAutoCreateConfig(.configInit))
        // A stdio server must not touch disk on boot; its tools report a
        // missing config instead.
        XCTAssertFalse(CLICommand.shouldAutoCreateConfig(.mcp))
        // Scaffolding a repo (even a --dry-run that promises to write nothing) must not create the fleet config.
        XCTAssertFalse(CLICommand.shouldAutoCreateConfig(.mobile, args: ["mobile", "init", "--dry-run"]))
        XCTAssertFalse(CLICommand.shouldAutoCreateConfig(.video, args: ["video", "list"]))
    }

    func testWorkingCommandsAutoCreate() {
        let working: [CLICommand] = [
            .auth, .doctor, .setupStatus, .setupRepair, .imagePrepare, .imageList, .imageDelete, .start, .stop,
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

    // MARK: - tiny flag parser

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
