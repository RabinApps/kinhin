import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The Toolchains tab is read-only: rows come from config.yaml's `projects:`
/// and global `toolchains:`, and nothing is ever written back.
@MainActor final class ToolchainsModelTests: XCTestCase {
    private var scratch: URL!
    private var configURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-tc-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        configURL = scratch.appendingPathComponent("config.yaml")
    }

    override func tearDown() async throws {
        try await super.tearDown()
        try? FileManager.default.removeItem(at: scratch)
    }

    private let sampleConfig = """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: [self-hosted]
        projects:
          - pattern: "acme/api"
            repo_file: true
          - pattern: "acme/*"
            toolchains:
              specs: ["go@1.22.5"]
          - pattern: "other/tool"
        """

    private func makeModel(
        _ yaml: String? = nil, images: [ProjectImageRecord] = [], tart: [TartVM] = []
    ) throws -> ToolchainsModel {
        try (yaml ?? sampleConfig).write(to: configURL, atomically: true, encoding: .utf8)
        let model = ToolchainsModel()
        model.configURL = configURL
        model.loadImageRecords = { images }
        model.listTartImages = { _ in tart }
        model.reload()
        return model
    }

    private func record(_ name: String, summary: String = "go@1.22.5") -> ProjectImageRecord {
        ProjectImageRecord(
            name: name, key: "k", base: "tahoe-base", summary: summary, createdAt: Date(), lastUsedAt: Date(),
            toolchains: .init(KinhinConfig.ToolchainsConfig(specs: ["go@1.22.5"])), shareCache: false)
    }

    // MARK: - Rows

    func testBuildsOneRowPerProjectThenTheDefaultRow() throws {
        let model = try makeModel()
        XCTAssertEqual(model.rows.map(\.id), ["acme/api", "acme/*", "other/tool", "<default>"])
        XCTAssertEqual(model.rows.map(\.source), [.repoFile, .projectFallback, .none, .none])
        XCTAssertEqual(model.rows[1].specs, ["go@1.22.5"])
        XCTAssertFalse(model.rows[3].hasToolchains, "other repos get no toolchains")
        XCTAssertTrue(model.rows[3].isDefault)
    }

    func testRepoFileRowSaysVersionsComeFromTheRepoAndInventsNone() throws {
        let model = try makeModel()
        let row = try XCTUnwrap(model.rows.first)
        XCTAssertEqual(row.source, .repoFile)
        XCTAssertFalse(row.hasToolchains, "no versions are invented for a repo-file project")
        let detail = ToolchainsModel.detail(row)
        XCTAssertTrue(
            detail.contains(".kinhin/config.yml (or the older .kinhin.yml) in the repo at each job's branch/tag"),
            detail)
        XCTAssertEqual(ToolchainsModel.sourceTitle(row), ".kinhin/config.yml honored")
    }

    func testFallbackAndGlobalWordingDiffer() throws {
        let model = try makeModel()
        XCTAssertTrue(ToolchainsModel.detail(model.rows[1]).contains("repo_file is off"))
        XCTAssertTrue(ToolchainsModel.detail(model.rows[2]).contains("use the base image"))
        let other = ToolchainsModel.detail(model.rows[3])
        XCTAssertTrue(other.contains("no toolchains baked") || other.contains("No toolchains baked"), other)
        XCTAssertTrue(other.contains("kinhin-toolchain install"), other)
    }

    func testOtherReposRowShowsTheBaseImageWithSizeWhenKnown() async throws {
        let model = try makeModel(tart: [TartVM(name: "tahoe-base", source: "local", status: "stopped", diskGB: 33)])
        await model.refreshImageSizes()
        let image = try XCTUnwrap(model.rows.last?.baseImage)
        XCTAssertEqual(model.baseImageLine(image), "\(image) · 33 GB")
    }

    // MARK: - Images

    func testDerivedImageForAFallbackSetIsAttachedAndTheRestAreRepoFileImages() throws {
        let cfg = try makeModel().rows  // loads once to learn the image name below
        XCTAssertFalse(cfg.isEmpty)
        let loaded = try ConfigLoader.load(from: configURL)
        let fallback = try XCTUnwrap(loaded.projects[1].toolchains)
        let key = ToolchainImageKey.make(toolchains: fallback, base: loaded.image, platform: .macOS)
        let name = ToolchainImageKey.imageName(base: loaded.image, key: key)

        let model = try makeModel(images: [record(name), record("tahoe-base-pdeadbeef", summary: "go@1.23.4")])
        XCTAssertEqual(model.rows[1].images.map(\.name), [name])
        XCTAssertEqual(model.repoFileImages.map(\.name), ["tahoe-base-pdeadbeef"])
        XCTAssertTrue(model.imageLine(model.rows[1].images[0]).contains("last used"))
    }

    func testImageSizesAreOptionalWhenTartIsUnavailable() async throws {
        let model = try makeModel(images: [record("tahoe-base-pdeadbeef")])
        model.listTartImages = { _ in throw TartError.missingBinary(path: "tart") }
        await model.refreshImageSizes()
        XCTAssertFalse(model.imageLine(record("x")).contains("GB"))
    }

    /// The tart row is offered (or withheld) by the configured `tart_path:`,
    /// the same authoritative rule This Mac, the CLI and the doctor apply.
    func testTheTartRowProbesTheConfiguredTartPath() throws {
        let found = try makeModel(sampleConfig + "\ntart_path: \"/usr/bin/true\"\n")
        XCTAssertTrue(
            found.imageRuntimes.contains { $0.runtime == .tart },
            "a configured binary outside the trusted directories still offers the tart row")

        let missing = try makeModel(sampleConfig + "\ntart_path: \"/nonexistent/kinhin-test-tart\"\n")
        XCTAssertFalse(
            missing.imageRuntimes.contains { $0.runtime == .tart },
            "a configured path that does not exist reads as missing, even with tart on PATH")
    }

    /// The size listing goes through the configured binary too: `tart list`
    /// must read the fleet's tart, not whatever sits on PATH.
    func testImageSizesListThroughTheConfiguredTartPath() async throws {
        let model = try makeModel(sampleConfig + "\ntart_path: \"/custom/tart\"\n")
        var asked: [String?] = []
        model.listTartImages = { path in
            asked.append(path)
            return []
        }
        await model.refreshImageSizes()
        XCTAssertFalse(asked.isEmpty, "the listing runs")
        XCTAssertTrue(asked.allSatisfy { $0 == "/custom/tart" }, "\(asked)")
    }

    // MARK: - Read-only

    func testReloadAndCopyNeverWriteTheConfig() throws {
        let model = try makeModel()
        let before = try String(contentsOf: configURL, encoding: .utf8)
        let modified = try FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate] as? Date

        model.reload()
        var copied: [String] = []
        model.copyToPasteboard = { copied.append($0) }
        model.copy("go@latest", id: "tool:go")

        XCTAssertEqual(copied, ["go@latest"])
        XCTAssertEqual(model.copiedID, "tool:go")
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), before)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate] as? Date, modified)
    }

    func testRebuildBaseImageDoesNotTouchConfig() async throws {
        let model = try makeModel()
        let before = try String(contentsOf: configURL, encoding: .utf8)
        model.confirmRebuild = { _ in true }
        var rebuilt: [RuntimeID] = []
        model.rebuild = { runtime, _ in rebuilt.append(runtime) }

        let task = try XCTUnwrap(model.startRebuild(.docker))
        await task.value

        XCTAssertEqual(rebuilt, [.docker])
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), before)
    }

    func testRebuildCanBeCancelledAndSaysTheImageIsUntouched() async throws {
        let model = try makeModel()
        model.confirmRebuild = { _ in true }
        model.rebuild = { _, _ in
            try await Task.sleep(for: .seconds(10))
        }
        XCTAssertNotNil(model.startRebuild(.tart))
        XCTAssertTrue(model.busy)
        XCTAssertNotNil(model.runningTask, "the rebuild's task is retained for the Cancel button")

        model.cancelRunning()
        let deadline = Date().addingTimeInterval(5)
        while model.busy, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))  // bounded poll: the state flips in the rebuild task
        }

        XCTAssertFalse(model.busy)
        XCTAssertNil(model.runningTask)
        XCTAssertEqual(model.status.text, "Cancelled — the previous image is untouched")
        XCTAssertEqual(model.status.style, .warn)
    }

    func testCancelWithoutARebuildIsANoop() throws {
        let model = try makeModel()
        model.cancelRunning()
        XCTAssertFalse(model.busy)
    }

    // MARK: - Catalog and examples

    func testCatalogListingCoversEveryToolAndStack() {
        let toolIDs = ToolchainCategory.allCases.flatMap { ToolchainsCatalogListing.tools(in: $0).map(\.id) }
        XCTAssertEqual(Set(toolIDs), Set(ToolchainCatalog.tools.map(\.id)))
        XCTAssertEqual(ToolchainsCatalogListing.stacks.map(\.id), ToolchainCatalog.stacks.map(\.id))
        let pnpm = ToolchainsCatalogListing.tools(in: .javascript).first { $0.id == "pnpm" }
        XCTAssertTrue(pnpm?.requirement?.contains("node@22") ?? false, "requirements are shown")
        let node = ToolchainsCatalogListing.tools(in: .languages).first { $0.id == "node" }
        XCTAssertEqual(node?.copyText, ToolchainCatalog.tool(id: "node")?.defaultSpec)
    }

    /// Each `.kinhin/config.yml` example parses through the real repo-file loader and
    /// satisfies the no-implicit-installs rule.
    func testExamplesAreValidRepoFiles() throws {
        let repoFiles = ToolchainsCatalogListing.examples.filter { $0.yaml.hasPrefix("toolchains:") }
        XCTAssertGreaterThanOrEqual(repoFiles.count, 4)
        for example in repoFiles {
            let parsed = try XCTUnwrap(try ProjectFileLoader.parse(Data(example.yaml.utf8)), example.title)
            let tools = Set((parsed.specs ?? []).map { String($0.split(separator: "@").first ?? "") })
            let stacks = (parsed.stacks ?? []).map { String($0.split(separator: "@").first ?? "") }
            var needs: [ToolchainRequirement] = []
            for id in tools { needs += ToolchainCatalog.tool(id: id)?.requires ?? [] }
            for id in stacks { needs += ToolchainCatalog.stack(id: id)?.requires ?? [] }
            for requirement in needs {
                XCTAssertTrue(tools.contains(requirement.toolID), "\(example.title) needs \(requirement.rawValue)")
            }
        }
    }
}
