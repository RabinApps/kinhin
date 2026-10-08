import XCTest

@testable import kinhin

/// Strict resolution: unknown commands, subcommands and flags are usage errors
/// (exit 2) with a usage line and a "did you mean"; every legacy spelling still
/// resolves.
final class CommandResolverTests: XCTestCase {
    private func usageError(_ args: [String], file: StaticString = #filePath, line: UInt = #line) -> String? {
        do {
            _ = try CommandResolver.resolve(args)
            XCTFail("expected a usage error for \(args)", file: file, line: line)
            return nil
        } catch let error as CLIError {
            XCTAssertEqual(error.exit, .usage, file: file, line: line)
            return error.message
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: - Unknown flags

    func testTypoedFlagIsAUsageErrorNotADryRun() throws {
        let message = try XCTUnwrap(usageError(["cleanup", "--ys"]))
        XCTAssertTrue(message.contains("unknown option '--ys' for 'cleanup'"), message)
        XCTAssertTrue(message.contains("did you mean '--yes'?"), message)
        XCTAssertTrue(message.contains("usage: kinhin cleanup"), message)
    }

    func testUnknownFlagWithNothingCloseSuggestsNothing() throws {
        let message = try XCTUnwrap(usageError(["status", "--frobnicate"]))
        XCTAssertFalse(message.contains("did you mean"), message)
    }

    func testFlagOfAnotherCommandIsRejected() {
        XCTAssertNotNil(usageError(["stop", "--yes"]))
        XCTAssertNotNil(usageError(["logs", "--json"]))
        // A leaf takes only its own flags, not its siblings'.
        XCTAssertNotNil(usageError(["image", "delete", "x", "--json"]))
        XCTAssertNotNil(usageError(["toolchains", "prune", "--json"]))
    }

    func testValueFlagNeedsAValue() throws {
        let message = try XCTUnwrap(usageError(["logs", "-n"]))
        XCTAssertTrue(message.contains("needs a value"), message)
    }

    func testEqualsFormIsRejectedWithAHint() throws {
        let message = try XCTUnwrap(usageError(["reset", "--scope=all"]))
        XCTAssertTrue(message.contains("separate argument"), message)
    }

    func testValuesMayLookLikeFlagsAndNegativeNumbersArePositionals() throws {
        // The value after a value flag is consumed, whatever it looks like.
        XCTAssertEqual(try CommandResolver.resolve(["auth", "set", "--account", "-odd"]).path, ["auth", "set"])
        XCTAssertEqual(try CommandResolver.resolve(["logs", "-n", "20"]).rest, ["-n", "20"])
        // Everything after `--` is operands.
        XCTAssertNoThrow(try CommandResolver.resolve(["image", "delete", "--yes", "--", "--odd-name"]))
    }

    func testOptionalValueFlagTakesTheNextNonFlagArgument() throws {
        XCTAssertNoThrow(try CommandResolver.resolve(["image", "prepare", "--linux", "--from", "--target", "x"]))
        XCTAssertNoThrow(
            try CommandResolver.resolve(["image", "prepare", "--linux", "--from", "ref", "--target", "x"]))
        XCTAssertNoThrow(try CommandResolver.resolve(["doctor", "--bundle"]))
        XCTAssertNoThrow(try CommandResolver.resolve(["doctor", "--bundle", "out.txt"]))
    }

    // MARK: - Unknown commands and subcommands

    func testUnknownCommandSuggestsTheNearest() throws {
        let message = try XCTUnwrap(usageError(["statuss"]))
        XCTAssertTrue(message.contains("unknown command 'statuss'; did you mean 'status'?"), message)
        XCTAssertTrue(try XCTUnwrap(usageError(["clenaup"])).contains("did you mean 'cleanup'?"))
        XCTAssertTrue(try XCTUnwrap(usageError(["image-list"])).contains("unknown command"))
        XCTAssertFalse(try XCTUnwrap(usageError(["zzzzzz"])).contains("did you mean"))
    }

    func testUnknownSubcommandNamesTheChoices() throws {
        let message = try XCTUnwrap(usageError(["config", "bogus"]))
        XCTAssertTrue(message.contains("unknown subcommand 'bogus' for 'config'"), message)
        XCTAssertTrue(message.contains("available: init, validate"), message)
        XCTAssertTrue(try XCTUnwrap(usageError(["auth", "lst"])).contains("did you mean 'list'?"))
        XCTAssertNotNil(usageError(["image", "frobnicate"]))
        XCTAssertNotNil(usageError(["daemon", "restart"]))
        XCTAssertNotNil(usageError(["toolchains", "frobnicate"]))
        XCTAssertNotNil(usageError(["runtimes", "frobnicate"]))
    }

    func testCommandsThatNeedASubcommandSayWhich() throws {
        for args in [["setup"], ["workflow"], ["runtimes", "route"], ["setup", "repair"]] {
            let message = try XCTUnwrap(usageError(args))
            XCTAssertTrue(message.contains("needs a subcommand"), message)
        }
    }

    // MARK: - Every historical spelling keeps working

    func testLegacySpellingsStillResolve() throws {
        let cases: [([String], CLICommand, [String])] = [
            (["setup-status"], .setupStatus, ["setup-status"]),
            (["setup-status", "--json"], .setupStatus, ["setup-status"]),
            (["setup", "status"], .setupStatus, ["setup", "status"]),
            (["pipelines"], .pipeline, ["pipeline"]),
            (["sponsor"], .support, ["support"]),
            (["--version"], .version, ["version"]),
            (["-v"], .version, ["version"]),
            (["--help"], .help, ["help"]),
            (["-h"], .help, ["help"]),
            (["image", "ls"], .imageList, ["image", "list"]),
            (["image", "rm", "x"], .imageDelete, ["image", "delete"]),
            (["image"], .imagePrepare, ["image"]),
            (["image", "--container"], .imagePrepare, ["image"]),
            (["image", "prepare", "--container"], .imagePrepare, ["image", "prepare"]),
            (["config"], .configInit, ["config"]),
            (["config", "--force"], .configInit, ["config"]),
            (["config", "init", "--force"], .configInit, ["config", "init"]),
            (["auth"], .auth, ["auth"]),
            (["auth", "--gitea"], .auth, ["auth"]),
            (["auth", "set", "--gitea", "--token", "x"], .auth, ["auth", "set"]),
            (["auth", "set", "--account", "work"], .auth, ["auth", "set"]),
            (
                ["auth", "add", "ci", "--gitea", "--scope", "o/r", "--instance", "https://g.example"], .auth,
                ["auth", "add"]
            ),
            (["auth", "status", "--json"], .auth, ["auth", "status"]),
            (["doctor", "--bundle", "x.txt"], .doctor, ["doctor"]),
            (["runtimes", "--json", "--no-health"], .runtimes, ["runtimes"]),
            (["runtimes", "route", "add", "a/b", "host", "--consent"], .runtimes, ["runtimes", "route", "add"]),
            (["toolchains", "--project", "o/r", "--ref", "main"], .toolchains, ["toolchains"]),
            (["toolchains", "detect", ".", "--json", "--write", "--force"], .toolchains, ["toolchains", "detect"]),
            (["daemon"], .daemon, ["daemon"]),
            (["daemon", "install"], .daemon, ["daemon", "install"]),
            (["logs", "-n", "10"], .logs, ["logs"]),
            (["pipeline", "vm-1", "--job", "build", "--step", "2", "-f"], .pipeline, ["pipeline"]),
            (["requeue", "github", "--yes"], .requeue, ["requeue"]),
            (["cleanup", "--vms", "--image", "--cache", "--all", "--yes"], .cleanup, ["cleanup"]),
            (["reset", "--scope", "all", "--yes"], .reset, ["reset"]),
            (["workflow", "test", "ci.yml", "--job", "build", "--list", "--json"], .workflow, ["workflow", "test"]),
            (["workflow", "test"], .workflow, ["workflow", "test"]),
            (
                ["workflow", "route", "ci.yml", "host", "--consent", "--dry-run", "--job", "j"], .workflow,
                ["workflow", "route"]
            ),
            (["setup", "repair", "docker", "--method", "colima"], .setupRepair, ["setup", "repair", "docker"]),
        ]
        for (args, command, path) in cases {
            let invocation = try CommandResolver.resolve(args)
            XCTAssertEqual(invocation.command, command, "\(args)")
            XCTAssertEqual(invocation.path, path, "\(args)")
            XCTAssertFalse(invocation.wantsHelp, "\(args)")
        }
    }

    func testImageFlagsOfEveryBakeModeAreAccepted() {
        let flags = [
            "--provision-script", "--image", "--project", "--ref", "--platform", "--container-image", "--docker-image",
            "--target", "--iso", "--runner-version", "--source",
        ]
        for flag in flags {
            XCTAssertNoThrow(try CommandResolver.resolve(["image", "prepare", flag, "x"]), flag)
        }
        for flag in ["--all", "--container", "--docker", "--linux"] {
            XCTAssertNoThrow(try CommandResolver.resolve(["image", "prepare", flag]), flag)
        }
    }

    func testQuotedTwoWordHeadsAreSplit() throws {
        let digest = try CommandResolver.resolve(["image digest", "ghcr.io/x"])
        XCTAssertEqual(digest.path, ["image", "digest"])
        XCTAssertEqual(digest.args, ["image", "digest", "ghcr.io/x"])
        XCTAssertEqual(try CommandResolver.resolve(["config init"]).path, ["config", "init"])
        XCTAssertEqual(try CommandResolver.resolve(["workflow test", "ci.yml"]).path, ["workflow", "test"])
    }

    func testJSONAndQuietAreReadFromTheOperands() throws {
        let invocation = try CommandResolver.resolve(["status", "--json", "-q"])
        XCTAssertTrue(invocation.json)
        XCTAssertTrue(invocation.quiet)
        XCTAssertFalse(try CommandResolver.resolve(["status"]).json)
    }

    func testEmptyLineResolvesToHelp() throws {
        XCTAssertEqual(try CommandResolver.resolve([]).command, .help)
    }

    // MARK: - Suggestions

    func testEditDistanceCountsTranspositionAsOne() {
        XCTAssertEqual(CommandResolver.editDistance(Array("clenaup"), Array("cleanup")), 1)
        XCTAssertEqual(CommandResolver.editDistance(Array("ys"), Array("yes")), 1)
        XCTAssertEqual(CommandResolver.editDistance(Array("abc"), Array("xyz")), 3)
    }

    func testSuggestionIgnoresDashesAndPrefersTheClosest() {
        XCTAssertEqual(CommandResolver.suggestion(for: "--jsno", among: ["--json", "--quiet"]), "--json")
        XCTAssertEqual(CommandResolver.suggestion(for: "--qui", among: ["--json", "--quiet"]), "--quiet")
        XCTAssertNil(CommandResolver.suggestion(for: "--zebra", among: ["--json", "--quiet"]))
        XCTAssertNil(CommandResolver.suggestion(for: "x", among: ["--json"]))
    }
}
