import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Per-project toolchain images in the engine: queued jobs resolve to a
/// derived image, new VMs are bound to it, and jobs run on the base image
/// while it bakes.
final class ProjectImageEngineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-pie-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)  // test temp dir
    }

    private let goFile = Data("toolchains:\n  specs: [go@1.22.5]\n".utf8)

    /// Records the bakes and gates their completion.
    private final class BakeLog: Sendable {
        private let names = Mutex<[String]>([])
        private let released: Mutex<Bool>

        init(released: Bool) { self.released = Mutex(released) }

        func record(_ name: String) { names.withLock { $0.append(name) } }
        var all: [String] { names.withLock { $0 } }
        var isReleased: Bool { released.withLock { $0 } }
        func release() { released.withLock { $0 = true } }
    }

    private struct Harness {
        let engine: FleetEngine
        let github: FakeGitHub
        let tart: FakeTart
        let bakes: BakeLog
    }

    /// An engine for `acme` (org scope) with the given projects. Bakes
    /// register the derived image in the fake tart after `releaseBake` flips.
    private func harness(projects: [KinhinConfig.ProjectConfig], bakeImmediately: Bool = true) -> Harness {
        var cfg = makeTestConfig()
        cfg.accounts = [AccountConfig(name: "github", forge: .github, scope: "acme")]
        cfg.projects = projects
        let github = FakeGitHub()
        let tart = FakeTart()
        let bakes = BakeLog(released: bakeImmediately)
        var deps = FleetEngine.Dependencies()
        deps.projectImageStore = ProjectImageStore(directory: dir)
        deps.projectBake = { options in
            bakes.record(options.target)
            while !bakes.isReleased { try await Task.sleep(for: .milliseconds(20)) }
            tart.vms[options.target] = TartVM(name: options.target, source: "local", status: "stopped")
        }
        let engine = FleetEngine(
            config: cfg, github: github, tart: tart, store: makeTestStore(), ssh: FakeSSH(), host: testHost,
            dependencies: deps)
        return Harness(engine: engine, github: github, tart: tart, bakes: bakes)
    }

    private func queue(_ github: FakeGitHub, repo: String = "acme/api", ref: String = "main", depth: Int = 1) {
        github.queueDepth = depth
        github.queueRepos = [repo]
        github.queueRefs = [ref]
        github.queueShas = ["abc123"]
    }

    func testRepoFileBakesADerivedImageAndBindsTheNextVMToIt() async throws {
        let h = harness(projects: [KinhinConfig.ProjectConfig(pattern: "acme/api", repoFile: true)])
        h.github.projectFiles["acme/api@abc123"] = goFile
        queue(h.github)

        // Pass 1: the image is missing, so a bake starts and the job runs on the base image.
        try await h.engine.reconcileOnce()
        await h.engine.projectImages.waitForBakes()
        let firstClone = try XCTUnwrap(h.tart.cloneCalls.first)
        XCTAssertEqual(firstClone.source, "tahoe-base")
        XCTAssertEqual(h.bakes.all.count, 1)

        // Pass 2: the image exists, so the next VM is cloned from it.
        let derived = try XCTUnwrap(h.bakes.all.first)
        try await h.engine.deleteVMRecord(id: h.engine.status().records[0].id, reason: "test")
        try await h.engine.reconcileOnce()
        let clones = h.tart.cloneCalls
        XCTAssertEqual(clones.last?.source, derived)
        let record = await h.engine.status().records.last
        XCTAssertEqual(record?.image, derived)
    }

    func testStatusSaysWhenJobsRunOnTheBaseImageWhileBaking() async throws {
        let h = harness(
            projects: [KinhinConfig.ProjectConfig(pattern: "acme/api", repoFile: true)], bakeImmediately: false)
        h.github.projectFiles["acme/api@abc123"] = goFile
        queue(h.github)
        try await h.engine.reconcileOnce()
        let notice = await h.engine.status().imageNotice
        XCTAssertEqual(notice?.contains("baking image for acme/api"), true, notice ?? "nil")
        XCTAssertEqual(notice?.contains("using base meanwhile"), true)
        h.bakes.release()
        await h.engine.projectImages.waitForBakes()
    }

    func testReposWithoutAProjectEntryNeverBakeAnything() async throws {
        let h = harness(projects: [KinhinConfig.ProjectConfig(pattern: "acme/api", repoFile: true)])
        queue(h.github, repo: "acme/other")
        try await h.engine.reconcileOnce()
        XCTAssertTrue(h.bakes.all.isEmpty)
        XCTAssertTrue(h.github.projectFileCalls.isEmpty)
        XCTAssertEqual(h.tart.cloneCalls.first?.source, "tahoe-base")
    }

    func testRepoFileIsOnlyReadWhenTheProjectOptsIn() async throws {
        let h = harness(projects: [KinhinConfig.ProjectConfig(pattern: "acme/api")])
        h.github.projectFiles["acme/api@abc123"] = goFile
        queue(h.github)
        try await h.engine.reconcileOnce()
        XCTAssertTrue(h.github.projectFileCalls.isEmpty, "repo_file is off: the forge is never asked")
        XCTAssertTrue(h.bakes.all.isEmpty)
    }

    func testProjectEntryToolchainsBakeWithoutAnyRepoFile() async throws {
        var own = KinhinConfig.ToolchainsConfig()
        own.specs = ["node@20"]
        let h = harness(projects: [KinhinConfig.ProjectConfig(pattern: "acme/*", toolchains: own)])
        queue(h.github)
        try await h.engine.reconcileOnce()
        await h.engine.projectImages.waitForBakes()
        XCTAssertEqual(h.bakes.all.count, 1)
        XCTAssertTrue(h.github.projectFileCalls.isEmpty)
    }

    func testForkJobsReadTheDefaultBranchFile() async throws {
        let h = harness(projects: [KinhinConfig.ProjectConfig(pattern: "acme/api", repoFile: true)])
        h.github.projectFiles["acme/api@default"] = goFile
        h.github.projectFiles["acme/api@abc123"] = Data("toolchains:\n  specs: [go@9.9.9]\n".utf8)
        queue(h.github)
        h.github.queueForks = true
        try await h.engine.reconcileOnce()
        XCTAssertEqual(h.github.projectFileCalls, ["acme/api@default"])
    }

    func testFileReadsAreCachedPerSha() async throws {
        let h = harness(projects: [KinhinConfig.ProjectConfig(pattern: "acme/api", repoFile: true)])
        h.github.projectFiles["acme/api@abc123"] = goFile
        queue(h.github, depth: 3)
        try await h.engine.reconcileOnce()
        try await h.engine.reconcileOnce()
        XCTAssertEqual(h.github.projectFileCalls.count, 1)
    }

    func testProjectsHotReload() async throws {
        let h = harness(projects: [])
        queue(h.github)
        h.github.projectFiles["acme/api@abc123"] = goFile
        try await h.engine.reconcileOnce()
        XCTAssertTrue(h.bakes.all.isEmpty)
        var updated = h.engine.activeConfig
        updated.projects = [KinhinConfig.ProjectConfig(pattern: "acme/api", repoFile: true)]
        XCTAssertFalse(FleetEngine.restartRequired(from: h.engine.activeConfig, to: updated))
        h.engine.applyReloaded(config: updated, host: testHost)
        try await h.engine.reconcileOnce()
        await h.engine.projectImages.waitForBakes()
        XCTAssertEqual(h.bakes.all.count, 1)
    }
}
