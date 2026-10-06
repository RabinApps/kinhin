import XCTest

@testable import KinhinKit
@testable import kinhin

/// `kinhin image list` output (prose + JSON report) and `kinhin image
/// delete`'s report-vs-confirm contract, on injected inventories — no tart,
/// no docker, no config: `run` only reaches those after its argument check.
final class ImageListDeleteTests: XCTestCase {
    // MARK: - Fixtures

    private func record(_ name: String, summary: String = "go@1.22.5") -> ProjectImageRecord {
        ProjectImageRecord(
            name: name, key: name, base: "tahoe-base", summary: summary,
            createdAt: Date(timeIntervalSince1970: 0), lastUsedAt: Date(timeIntervalSince1970: 1000),
            toolchains: .init(KinhinConfig.ToolchainsConfig()), shareCache: false)
    }

    private func inventory(
        image: String = "tahoe-base", named: [String] = [],
        tart: ImageInventory.RuntimeImages,
        container: ImageInventory.RuntimeImages? = nil,
        docker: ImageInventory.RuntimeImages? = nil,
        records: [ProjectImageRecord] = []
    ) -> ImageInventory {
        var cfg = KinhinConfig.default
        cfg.image = image
        cfg.images = named.map { .init(name: $0) }
        return ImageInventory.build(
            config: cfg, tart: tart, container: container, docker: docker, projectRecords: records)
    }

    // MARK: - image list

    func testListGroupsByRuntimeAndShowsRoleSizeAndWhoUsesEachImage() {
        let listed = inventory(
            tart: .init(names: ["tahoe-base", "proj-abc"], sizesGB: ["tahoe-base": 33]),
            records: [record("proj-abc", summary: "xcode@15")])
        let lines = ImageListCommand.lines(for: listed)
        let text = lines.joined(separator: "\n")

        XCTAssertTrue(text.contains("tart images (macOS/Linux VM images):"), text)
        XCTAssertTrue(text.contains("tahoe-base"), text)
        XCTAssertTrue(text.contains("33 GB"), text)
        XCTAssertTrue(text.contains("derived"), text)
        XCTAssertTrue(text.contains("xcode@15"), text)
        XCTAssertTrue(text.contains("last used"), text)
        XCTAssertTrue(
            lines.contains("delete one with: kinhin image delete <name>"),
            "a present image should invite the delete command")
    }

    func testListOpensEachSectionWithACountAndTotalDiskUsage() {
        let listed = inventory(
            tart: .init(names: ["tahoe-base", "proj-abc"], sizesGB: ["tahoe-base": 33, "proj-abc": 12]),
            records: [record("proj-abc")])
        let lines = ImageListCommand.lines(for: listed)

        XCTAssertTrue(
            lines.contains("  2 image(s), 45 GB total"),
            "the section headline is the bloat-at-a-glance line: \(lines)")
        // The headline sits directly under its own title.
        let title = lines.firstIndex(of: "tart images (macOS/Linux VM images):")
        XCTAssertNotNil(title)
        XCTAssertEqual(lines[title! + 1], "  2 image(s), 45 GB total")
    }

    func testListOmitsTheTotalWhenTheRuntimeReportedNoSizes() {
        let listed = inventory(tart: .init(names: ["tahoe-base"]))
        let lines = ImageListCommand.lines(for: listed)

        XCTAssertTrue(lines.contains("  1 image(s)"), "count without a total: \(lines)")
        XCTAssertFalse(
            lines.contains { $0.contains("image(s),") },
            "a runtime that reported no sizes must not invent a total: \(lines)")
    }

    func testListShowsAnImageSmallerThanOneGigabyteInsteadOfZero() {
        let listed = inventory(tart: .init(names: ["tiny"], sizesGB: ["tiny": 0]))
        let text = ImageListCommand.lines(for: listed).joined(separator: "\n")

        XCTAssertTrue(text.contains("<1 GB"), text)
        XCTAssertFalse(text.contains("0 GB"), "'0 GB' reads as a broken measurement: \(text)")
    }

    func testListExplainsAConfiguredImageThatIsNotBuilt() {
        let listed = inventory(named: ["xcode"], tart: .init(names: []))
        let text = ImageListCommand.lines(for: listed).joined(separator: "\n")

        XCTAssertTrue(text.contains("not built"), text)
        XCTAssertTrue(
            text.contains("not built — run: kinhin image prepare --image xcode"),
            "the rebuild command must match the entry: \(text)")
    }

    func testListSaysWhyARuntimeCouldNotBeListedInsteadOfClaimingItIsEmpty() {
        let listed = inventory(tart: .init(unavailable: "tart is not installed — brew install cirruslabs/tart/tart"))
        let lines = ImageListCommand.lines(for: listed)

        XCTAssertTrue(
            lines.contains("  not listed — tart is not installed — brew install cirruslabs/tart/tart"), "\(lines)")
        XCTAssertFalse(
            lines.contains("delete one with: kinhin image delete <name>"),
            "nothing is known to be installed, so nothing is offered for deletion")
    }

    func testReportCarriesEveryEntryAndTheUnavailableReasons() throws {
        var cfg = KinhinConfig.default
        cfg.image = "tahoe-base"
        cfg.docker = .init(image: "kinhin-ci-linux")
        let listed = ImageInventory.build(
            config: cfg,
            tart: .init(unavailable: "could not list tart images: boom"),
            docker: .init(names: []))
        let report = ImageListCommand.report(for: listed)

        XCTAssertEqual(report.unavailable, ["tart": "could not list tart images: boom"])
        XCTAssertEqual(report.images.map(\.runtime), [.docker])
        XCTAssertEqual(report.images.map(\.name), ["kinhin-ci-linux"])
        XCTAssertEqual(
            report.totalGB, [:],
            "an unavailable runtime and an empty listing both mean no total, not zero")

        // The document must encode: this is what `--json` prints.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(report), as: UTF8.self)
        XCTAssertTrue(json.contains("\"tart\""), json)
        XCTAssertTrue(json.contains("kinhin-ci-linux"), json)
        XCTAssertTrue(json.contains("\"totalGB\""), json)
    }

    func testReportCarriesEachRuntimesTotalDiskUsage() {
        var cfg = KinhinConfig.default
        cfg.image = "tahoe-base"
        cfg.docker = .init(image: "kinhin-ci-linux")
        let listed = ImageInventory.build(
            config: cfg,
            tart: .init(names: ["tahoe-base"], sizesGB: ["tahoe-base": 33]),
            docker: .init(names: ["kinhin-ci-linux:latest"], sizesGB: ["kinhin-ci-linux:latest": 4]))

        XCTAssertEqual(
            ImageListCommand.report(for: listed).totalGB,
            ["tart": 33, "docker": 4],
            "the JSON document exposes every runtime's total, keyed by runtime")
    }

    func testListQueryParsesJsonAndRuntimeFilters() throws {
        let plain = try ImageListCommand.Query.parse([])
        XCTAssertNil(plain.only, "no --runtime means every runtime")

        XCTAssertEqual(try ImageListCommand.Query.parse(["--json"]).json, true)
        XCTAssertEqual(try ImageListCommand.Query.parse(["--runtime", "docker"]).only, [.docker])

        // Repeated flags widen the filter instead of fighting over it.
        let both = try ImageListCommand.Query.parse(["--runtime", "tart", "--runtime", "container", "--json"])
        XCTAssertEqual(both.only, [.tart, .container])
        XCTAssertEqual(both.json, true)
    }

    func testListQueryRejectsBadRuntimeValuesBeforeProbingAnything() {
        XCTAssertThrowsError(try ImageListCommand.Query.parse(["--runtime"])) { error in
            guard let cliError = error as? CLIError else { return XCTFail("expected CLIError, got \(error)") }
            XCTAssertEqual(cliError.exit, .usage)
            XCTAssertTrue(cliError.message.contains("tart, container or docker"), cliError.message)
        }
        XCTAssertThrowsError(try ImageListCommand.Query.parse(["--runtime", "vmware"])) { error in
            guard let cliError = error as? CLIError else { return XCTFail("expected CLIError, got \(error)") }
            XCTAssertEqual(cliError.exit, .usage)
            XCTAssertTrue(cliError.message.contains("vmware"), cliError.message)
        }
        XCTAssertThrowsError(try ImageListCommand.Query.parse(["tahoe-base"])) { error in
            guard let cliError = error as? CLIError else { return XCTFail("expected CLIError, got \(error)") }
            XCTAssertEqual(cliError.exit, .usage)
            XCTAssertTrue(cliError.message.contains("--runtime"), cliError.message)
        }
    }

    func testListPrintsOnlyTheRequestedRuntimeSections() {
        var cfg = KinhinConfig.default
        cfg.image = "tahoe-base"
        cfg.container = .init(image: "kinhin-ci-linux")
        let filtered = ImageInventory.build(
            config: cfg,
            tart: .init(names: ["tahoe-base"]),
            container: .init(names: ["kinhin-ci-linux"]),
            only: [.container])
        let text = ImageListCommand.lines(for: filtered).joined(separator: "\n")

        XCTAssertTrue(text.contains("apple container images:"), text)
        XCTAssertFalse(text.contains("tart images"), text)
    }

    func testListRejectsAnythingButJSON() async {
        do {
            try await ImageListCommand.run(["bogus"])
            XCTFail("image list must reject unknown arguments")
        } catch let error as CLIError {
            XCTAssertEqual(error.exit, .usage)
            XCTAssertTrue(error.message.contains("--json"), error.message)
        } catch {
            XCTFail("expected CLIError, got \(error)")
        }
    }

    // MARK: - image delete

    func testDeleteNeedsAtLeastOneName() async {
        do {
            try await ImageDeleteCommand.run([])
            XCTFail("image delete without names must fail")
        } catch let error as CLIError {
            XCTAssertEqual(error.exit, .usage)
            XCTAssertTrue(error.message.contains("kinhin image list"), error.message)
        } catch {
            XCTFail("expected CLIError, got \(error)")
        }
    }

    func testDeleteAcceptsOnlyYes() async {
        do {
            try await ImageDeleteCommand.run(["--force"])
            XCTFail("image delete must reject unknown flags")
        } catch let error as CLIError {
            XCTAssertEqual(error.exit, .usage)
            XCTAssertTrue(error.message.contains("--yes"), error.message)
        } catch {
            XCTFail("expected CLIError, got \(error)")
        }
    }

    func testDescribeSwitchesWordingWithConfirmation() {
        let plan = ImageDeletePlan.plan(
            names: ["tahoe-base"],
            inventory: inventory(tart: .init(names: ["tahoe-base"])))

        let dry = ImageDeleteCommand.describe(plan, willDelete: false)
        XCTAssertTrue(dry.hasPrefix("would delete 1 image(s):"), dry)
        XCTAssertTrue(dry.contains("tahoe-base"), dry)
        XCTAssertTrue(dry.contains("(tart, base)"), dry)

        let real = ImageDeleteCommand.describe(plan, willDelete: true)
        XCTAssertTrue(real.hasPrefix("deleting 1 image(s):"), real)
    }

    func testWarningsNameTheCommandThatRebuildsEachConfiguredImage() {
        var dockerConfigured = KinhinConfig.default
        dockerConfigured.image = "tahoe-base"
        dockerConfigured.docker = .init(image: "kinhin-ci-linux")
        let plan = ImageDeletePlan.plan(
            names: ["tahoe-base", "kinhin-ci-linux:latest"],
            inventory: ImageInventory.build(
                config: dockerConfigured,
                tart: .init(names: ["tahoe-base"]),
                docker: .init(names: ["kinhin-ci-linux:latest"])))

        let warnings = ImageDeleteCommand.warnings(for: plan)
        XCTAssertEqual(warnings.count, 2, "both configured images need their rebuild command")
        XCTAssertTrue(
            warnings.contains { $0.contains("kinhin image prepare") && !$0.contains("--docker") },
            "\(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("kinhin image prepare --docker") }, "\(warnings)")

        // A local image nobody configured gets no warning.
        let local = ImageDeletePlan.plan(
            names: ["ubuntu:24.04"],
            inventory: inventory(tart: .init(names: ["ubuntu:24.04"])))
        XCTAssertEqual(ImageDeleteCommand.warnings(for: local), [])
    }

    func testExitCodeSeparatesBadNamesFromAMachineBusyWithRunners() {
        func refusal(_ kind: ImageDeletePlan.Refusal.Kind) -> ImageDeletePlan.Refusal {
            .init(name: "x", kind: kind, reason: "because")
        }
        XCTAssertEqual(ImageDeleteCommand.exitCode(for: [refusal(.unknown)]), .usage)
        XCTAssertEqual(ImageDeleteCommand.exitCode(for: [refusal(.notAnImage)]), .usage)
        XCTAssertEqual(ImageDeleteCommand.exitCode(for: [refusal(.unknown), refusal(.inUse)]), .runtime)
    }
}
