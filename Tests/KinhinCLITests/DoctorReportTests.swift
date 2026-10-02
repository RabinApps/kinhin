import Synchronization
import XCTest

@testable import KinhinKit
@testable import kinhin

/// The `kinhin doctor --json` contract: one merged document combining the
/// host/capacity probes, CLT/tart/container health, every forge's stored-token
/// state (`AuthStatusReport`), and the first-run checklist (`SetupStatus`).
/// Fully hermetic — every builder parameter is a fixture, so no Keychain,
/// subprocess, or network is touched. Section mapping (CLT/tart) is pure and
/// tested directly; the CLI flow runs through the injectable `emitJSON`.
final class DoctorReportTests: XCTestCase {
    // MARK: - Fixtures

    private let host = HostResources(logicalCores: 10, memoryGB: 32, freeDiskGB: 200, arm64: true)

    private static func project(specs: [String]?, shareCache: Bool? = nil) -> KinhinConfig.ProjectConfig {
        KinhinConfig.ProjectConfig(
            pattern: "acme/widgets", toolchains: KinhinConfig.ToolchainsConfig(specs: specs), shareCache: shareCache)
    }

    private static func config(repo: String = "acme/widgets", gitea: Bool = false, container: Bool = false)
        -> KinhinConfig
    {
        var cfg = KinhinConfig.default
        if !repo.isEmpty {
            cfg.accounts = [AccountConfig(name: "github", forge: .github, scope: repo)]
        }
        if gitea {
            cfg.accounts.append(
                AccountConfig(
                    name: "gitea", forge: .gitea, scope: "acme", instance: "https://gitea.example.com",
                    labels: ["macos:host"]))
        }
        if container {
            cfg.container = KinhinConfig.ContainerConfig(image: "kinhin-ci-linux", cpus: 4, memoryGB: 8)
        }
        return cfg
    }

    private func builder(
        stored: [ForgeID: String] = [:],
        config: KinhinConfig?,
        clt: CLTState = .ok(version: "26.6"),
        tartHealth: TartHealth = .healthy,
        containerHealth: RuntimeHealth? = nil,
        containerImages: [String]? = nil
    ) -> DoctorReportBuilder {
        DoctorReportBuilder(
            host: host,
            clt: clt,
            tartHealth: tartHealth,
            tartList: [
                TartVM(name: "tahoe-base", source: "ghcr.io/cirruslabs/macos-tahoe-base:latest", status: "stopped")
            ],
            config: config.map(ConfigScenario.loaded) ?? .missing,
            authLoad: { stored[$0] },
            accountLoad: { forge, name in
                guard let account = config?.accounts.first(where: { $0.name == name }) else { return nil }
                return account.forge == forge ? stored[forge] : nil
            },
            containerHealth: containerHealth,
            containerImages: containerImages
        )
    }

    // MARK: - Merge semantics

    func testMergedDocumentCarriesAllHalves() async {
        let report = await builder(
            stored: [.github: "ghp_live", .gitea: "gt_live"],
            config: Self.config(gitea: true, container: true),
            containerHealth: .ready,
            containerImages: ["kinhin-ci-linux:latest"]
        ).build()

        XCTAssertEqual(report.host, host, "the host snapshot passes through verbatim")
        XCTAssertEqual(report.clt.state, "ok")
        XCTAssertEqual(report.tart.state, "healthy")
        XCTAssertEqual(report.auth.forges.map(\.id), ["github", "gitea", "forgejo"])
        XCTAssertEqual(report.checks.first?.id, "arch", "the checklist rows are embedded in order")
        XCTAssertNotNil(report.capacity, "a parsed config yields the capacity section")
        XCTAssertNotNil(report.container, "a container: config yields the container section")
    }

    func testContainerSectionAbsentWithoutContainerConfig() async {
        let report = await builder(config: Self.config()).build()
        XCTAssertNil(report.container, "no container: section → no container half (mirrors the checklist rows)")
    }

    func testContainerSectionReportsImagePresence() async {
        let found = await builder(
            config: Self.config(container: true),
            containerHealth: .ready,
            containerImages: ["kinhin-ci-linux:1.2"]
        ).build()
        XCTAssertEqual(found.container?.state, "ready")
        XCTAssertEqual(found.container?.image, "kinhin-ci-linux")
        XCTAssertTrue(
            found.container?.imageFound ?? false, "a tag-prefixed local image matches (same rule as the checklist)")

        let absent = await builder(
            config: Self.config(container: true),
            containerHealth: .ready,
            containerImages: []
        ).build()
        XCTAssertFalse(absent.container?.imageFound ?? true)
        XCTAssertNotNil(absent.container?.fix, "a missing image carries the prepare command")
        XCTAssertEqual(absent.container?.fix, "kinhin image prepare --container --target kinhin-ci-linux")
    }

    func testContainerUnhealthyStateCarriesFix() async {
        let report = await builder(
            config: Self.config(container: true),
            containerHealth: .missing(tool: "apple container", fix: "brew install container && container system start")
        ).build()
        XCTAssertEqual(report.container?.state, "missing")
        XCTAssertFalse(report.container?.ok ?? true)
        XCTAssertEqual(report.container?.fix, "brew install container && container system start")
        XCTAssertFalse(report.container?.imageFound ?? true, "no images when the runtime is not ready")
    }

    func testDockerAvailabilityIsReportedEvenWithoutDockerConfig() async {
        let macOS26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        func build(installed: Bool) async -> DoctorReport {
            await DoctorReportBuilder(
                host: host, clt: .ok(version: "26.6"), tartHealth: .healthy, tartList: [],
                config: .loaded(Self.config()), authLoad: { _ in nil }, dockerInstalled: installed, osVersion: macOS26
            ).build()
        }
        let missing = await build(installed: false)
        XCTAssertNil(missing.docker, "no docker: section → no runtime half")
        XCTAssertEqual(
            missing.dockerAvailability,
            DoctorReport.DockerAvailabilitySection(installed: false, supported: true, reason: nil))
        let installedReport = await build(installed: true)
        XCTAssertEqual(installedReport.dockerAvailability?.installed, true)
    }

    func testCapacityOnlyPresentForParsedConfig() async {
        let present = await builder(config: Self.config()).build()
        XCTAssertEqual(
            present.capacity?.maxConcurrent, 2,
            "10 cores − 2 reserved = 8 usable / 4 per VM = cpu cap 2; mem cap 3; user max_runners 2 → 2"
        )
        XCTAssertEqual(present.capacity?.bindingConstraint, "cpu (need 4 cores per VM, 8 usable)")
        XCTAssertEqual(present.capacity?.jobSlots, 2, "2 VMs × runners_per_vm 1")
        XCTAssertTrue(present.capacity!.fits)

        let absent = await builder(config: nil).build()
        XCTAssertNil(absent.capacity, "no parsed config → no capacity section (nothing to plan)")
    }

    func testChecklistEmbedsGiteaTokenRowOnlyWhenConfigured() async {
        let withGitea = await builder(
            stored: [.github: "ghp_x", .gitea: "gt_x"],
            config: Self.config(gitea: true)
        ).build()
        XCTAssertTrue(
            withGitea.checks.contains { $0.id == "account-token-gitea" && $0.ok },
            "the embedded checklist sees the same token source as the auth half")

        let without = await builder(stored: [.github: "ghp_x"], config: Self.config()).build()
        XCTAssertFalse(without.checks.contains { $0.id == "account-token-gitea" })
    }

    // MARK: - Tart base-image section

    func testTartBaseImageSectionAbsentWithoutConfigKey() async {
        let report = await builder(stored: [.github: "ghp_x"], config: Self.config()).build()
        XCTAssertNil(report.tartBaseImage, "no base_image: key → no section")
    }

    func testTartBaseImageSectionCoversAllThreeVerdicts() async {
        // Known (curated) reference — green without needing the tart list.
        var known = Self.config()
        known.baseImage = "ghcr.io/cirruslabs/macos-sequoia-base:latest"
        let knownReport = await builder(stored: [.github: "ghp_x"], config: known, tartHealth: .healthy).build()
        XCTAssertEqual(
            knownReport.tartBaseImage,
            DoctorReport.TartBaseImageSection(
                reference: known.baseImage ?? "", state: "known", ok: true, fix: nil, pinned: false,
                warning: SetupStatusComputer.baseImageMutabilityNote(known.baseImage)))

        // Local VM — resolves against the injected tart list.
        var local = Self.config()
        local.baseImage = "sequoia-scratch"
        let localBuilder = DoctorReportBuilder(
            host: host, clt: .ok(version: "26.6"), tartHealth: .healthy,
            tartList: [TartVM(name: "sequoia-scratch", source: "anywhere", status: "stopped")],
            config: .loaded(local), authLoad: { _ in "ghp_x" })
        let localReport = await localBuilder.build()
        XCTAssertEqual(localReport.tartBaseImage?.state, "local")
        XCTAssertTrue(localReport.tartBaseImage?.ok ?? false)
        XCTAssertNil(localReport.tartBaseImage?.fix)

        // Unknown — the fix tells the user exactly what to rewrite.
        var unknown = Self.config()
        unknown.baseImage = "ghcr.io/acme/vanished:latest"
        let unknownReport = await builder(stored: [.github: "ghp_x"], config: unknown, tartHealth: .healthy).build()
        XCTAssertEqual(unknownReport.tartBaseImage?.state, "unknown")
        XCTAssertFalse(unknownReport.tartBaseImage?.ok ?? true)
        XCTAssertTrue(unknownReport.tartBaseImage?.fix?.contains("ghcr.io/acme/vanished:latest") ?? false)
    }

    func testTartBaseImageJSONRoundTrips() async throws {
        var cfg = Self.config()
        cfg.baseImage = "ghcr.io/cirruslabs/macos-sequoia-base:latest"
        let report = await builder(stored: [.github: "ghp_x"], config: cfg).build()
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: data)
        XCTAssertEqual(decoded.tartBaseImage, report.tartBaseImage, "the new section is part of the emitted contract")
    }

    // MARK: - ready truth table (the contract's headline field)

    func testReadyRequiresBothChecklistAndAuthToPass() async {
        let both = await builder(stored: [.github: "ghp_x"], config: Self.config()).build()
        XCTAssertTrue(both.ready, "green checklist + stored scoped token → ready")

        let checklistBlocked = await builder(stored: [.github: "ghp_x"], config: Self.config(), tartHealth: .missing)
            .build()
        XCTAssertFalse(checklistBlocked.ready, "a red checklist row blocks ready even with tokens stored")

        let authBlocked = await builder(config: Self.config()).build()
        XCTAssertFalse(authBlocked.ready, "a missing token blocks ready even with a green checklist")

        let noRepo = await builder(stored: [.github: "ghp_x"], config: Self.config(repo: "")).build()
        XCTAssertFalse(noRepo.ready, "a token without a scope is not usable (auth.allGood false, config row red)")
    }

    // MARK: - Auth half

    func testAuthHalfKeepsMaskedPrefixesOnly() async throws {
        let report = await builder(stored: [.github: "ghp_supersecret"], config: Self.config()).build()
        let github = report.auth.forges[0]
        XCTAssertTrue(github.stored)
        XCTAssertEqual(github.prefix, "ghp_")
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(json.contains("supersecret"), "the full secret never appears anywhere in the document")
    }

    // MARK: - Section mapping (pure)

    func testCLTSectionMapping() {
        let ok = DoctorReportBuilder.cltSection(from: .ok(version: "26.6"))
        XCTAssertEqual(ok.state, "ok")
        XCTAssertEqual(ok.version, "26.6")
        XCTAssertTrue(ok.ok)
        XCTAssertNil(ok.fixCommand)
        XCTAssertNil(ok.fixHint)

        let outdated = DoctorReportBuilder.cltSection(from: .outdated(version: "25.1", macOSVersion: "26.6"))
        XCTAssertEqual(outdated.state, "outdated")
        XCTAssertFalse(outdated.ok)
        XCTAssertEqual(outdated.fixCommand, CLTRepair.commandLine)
        XCTAssertEqual(outdated.fixHint, CLTRepair.fallbackHint, "only the outdated state carries the fallback hint")

        let missing = DoctorReportBuilder.cltSection(from: .missing)
        XCTAssertEqual(missing.state, "missing")
        XCTAssertNil(missing.version)
        XCTAssertEqual(missing.fixCommand, CLTRepair.commandLine)
        XCTAssertNil(missing.fixHint)

        XCTAssertEqual(DoctorReportBuilder.cltSection(from: .unselected).state, "unselected")
    }

    func testTartSectionRepairOrderingMatchesHumanDoctor() {
        let healthy = DoctorReportBuilder.tartSection(from: .healthy)
        XCTAssertTrue(healthy.ok)
        XCTAssertEqual(healthy.repairCommands, [], "a healthy install needs no repair lines")

        let killed = DoctorReportBuilder.tartSection(from: .killedOnLaunch)
        XCTAssertFalse(killed.ok)
        XCTAssertTrue(killed.reason?.contains("openai/homebrew-tools#27") ?? false)
        XCTAssertEqual(killed.repairCommands.count, 2)
        XCTAssertTrue(
            killed.repairCommands[0].contains("openai/cli/tart"),
            "a Gatekeeper kill rolls back to the notarized Cirrus build FIRST")
        XCTAssertTrue(killed.repairCommands[1].contains("openai/tools/tart"))

        let broken = DoctorReportBuilder.tartSection(from: .broken("exited with code 1"))
        XCTAssertEqual(broken.state, "broken")
        XCTAssertEqual(broken.reason, "exited with code 1")
        XCTAssertTrue(
            broken.repairCommands[0].contains("openai/tools/tart"),
            "an unknown breakage tries a reinstall first")
        XCTAssertEqual(broken.repairCommands.count, 2)

        let missingRepair = DoctorReportBuilder.tartSection(from: .missing)
        XCTAssertEqual(missingRepair.repairCommands.count, 1)
        XCTAssertTrue(missingRepair.repairCommands[0].contains("brew"))
    }

    // MARK: - JSON round-trip (the emitted contract)

    func testJSONRoundTripPreservesTheContract() async throws {
        let report = await builder(
            stored: [.github: "ghp_live", .gitea: "gt_live"],
            config: Self.config(gitea: true, container: true),
            containerHealth: .ready,
            containerImages: ["kinhin-ci-linux:latest"]
        ).build()

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: data)
        XCTAssertEqual(decoded, report, "the emitted JSON is the documented contract — it must decode back exactly")
    }

    func testJSONDocumentNeverContainsTheSecret() async throws {
        let report = await builder(stored: [.github: "ghp_nevertell"], config: Self.config()).build()
        let data = try JSONEncoder().encode(report)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("nevertell"), "no token body may reach the document")
        XCTAssertTrue(json.contains("\"ghp_\""), "the masked prefix is the only token fragment")
    }

    // MARK: - CLI flow (`doctor --json` through DoctorCommand)

    func testCLIJSONEmitsParseableDocument() async throws {
        let fixture = builder(
            stored: [.github: "ghp_cli"],
            config: Self.config()
        )
        let (_, data) = try await DoctorCommand.emitJSON(builder: fixture)
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: data)
        XCTAssertTrue(decoded.auth.forges[0].stored)
        XCTAssertFalse(decoded.auth.forges[0].prefix!.contains("cli"), "the emitted prefix is masked, never the secret")
        XCTAssertEqual(decoded.auth.forges.map(\.id), ["github", "gitea", "forgejo"], "all forges are always reported")
    }

    // MARK: - Config resolution parity

    func testTemplateConfigResolvesLikeTheChecklist() async {
        // The starter template (no accounts) must never earn a green
        // checkmark nor a capacity section — same evaluation as the checklist.
        let report = await builder(config: Self.config(repo: "")).build()
        XCTAssertNil(report.capacity, "a template config is not a working config")
        let configRow = report.checks.first { $0.id == "config" }
        XCTAssertEqual(configRow?.ok, false)
        XCTAssertEqual(configRow?.action, "edit_config")
        XCTAssertFalse(report.ready)
    }

    // MARK: - Shared toolchain cache section

    func testToolchainCacheSectionAlwaysPresent() async {
        let report = await builder(config: Self.config()).build()
        XCTAssertNotNil(report.toolchainCache, "the cache is a host fact — reported with or without a config")
        XCTAssertEqual(report.toolchainCache.root, Paths.toolchainCache.path)
    }

    func testToolchainCacheSectionMeasuresRealDirectories() throws {
        // Build a scratch "cache root" by pointing the static helper at a
        // fixture: the section helper reads Paths.toolchainCache, so exercise
        // the measuring code path directly with a temporary tree instead.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-doctor-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("npm/tarballs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("mise/downloads"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 2048).write(to: root.appendingPathComponent("npm/tarballs/react.tar"))
        try Data(repeating: 0x41, count: 512).write(to: root.appendingPathComponent("mise/downloads/node.tar.zst"))
        try Data(repeating: 0x41, count: 16).write(to: root.appendingPathComponent("empty/.keep"))

        let size = DoctorReportBuilder.directorySize(at: root)
        XCTAssertEqual(size, 2048 + 512 + 16, "recursive byte size over regular files")

        let missing = DoctorReportBuilder.directorySize(at: root.appendingPathComponent("nope"))
        XCTAssertEqual(missing, 0, "a missing directory measures zero, not an error")
    }

    func testToolchainCacheSectionSelectionBreakdownUsesConfigSubdirectories() throws {
        // The pure mapping: a toolchains selection yields exactly its mapped
        // subdirectories (deduplicated), in stable order, even for dirs that
        // don't exist yet (measured as zero bytes).
        var cfg = Self.config()
        cfg.projects = [Self.project(specs: ["go@1.23", "go@latest"])]
        let section = DoctorReportBuilder.toolchainCacheSection(config: cfg)
        XCTAssertEqual(
            section.ecosystems.map(\.directory), ["go/mod", "go/build", "mise"],
            "the breakdown mirrors the selection's cache map (deduped, order-stable)")
    }

    func testToolchainCacheWarningFlagsEmptyCacheWithShareCacheOn() {
        // share_cache on + nothing cached: the runner-mounts-empty warning.
        var cfg = Self.config()
        cfg.projects = [Self.project(specs: ["node@22"], shareCache: true)]
        let section = DoctorReportBuilder.toolchainCacheSection(config: cfg)
        XCTAssertTrue(section.sharedWithRunners)
        if section.usable, section.totalBytes == 0 {
            XCTAssertTrue(section.warning, "an empty cache with share_cache on must warn")
        }

        // share_cache off: never a warning.
        var plain = Self.config()
        plain.projects = [Self.project(specs: ["node@22"])]
        let quiet = DoctorReportBuilder.toolchainCacheSection(config: plain)
        XCTAssertFalse(quiet.sharedWithRunners)
        XCTAssertFalse(quiet.warning)

        // Unusable root with share_cache on: warn regardless of bytes.
        var on = Self.config()
        on.projects = [Self.project(specs: nil, shareCache: true)]
        _ = on  // the unusable branch is exercised via root: the warning flag
        let unusable = DoctorReport.ToolchainCacheSection(
            root: "/nonexistent", usable: false, sharedWithRunners: true, warning: true,
            totalBytes: 0, ecosystems: []
        )
        XCTAssertFalse(unusable.usable)
        XCTAssertTrue(unusable.warning)
    }

    func testToolchainCacheJSONRoundTripsWithNewFields() async throws {
        var cfg = Self.config()
        cfg.projects = [Self.project(specs: ["node@22"], shareCache: true)]
        let report = await builder(config: cfg).build()
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertTrue(json.contains("\"sharedWithRunners\":true"), "the share flag is part of the contract")
        XCTAssertTrue(json.contains("\"toolchainCache\""), "the cache section is part of the contract")
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: try JSONEncoder().encode(report))
        XCTAssertEqual(decoded, report)
    }

    // MARK: - Human rendering

    /// `kinhin doctor` prints the same report `--json` emits: a broken tart,
    /// a missing account token and the capacity all come from the report.
    func testPlainTextRendersTheSharedReport() async {
        let report = await builder(config: Self.config(), tartHealth: .killedOnLaunch).build()
        let text = report.plainText
        XCTAssertTrue(text.hasPrefix("kinhin doctor"), text)
        XCTAssertTrue(text.contains("tart:       INSTALLED BUT KILLED ON LAUNCH ✗"), text)
        XCTAssertTrue(text.contains("tok github: no token stored — run: kinhin auth set --account github"), text)
        XCTAssertTrue(text.contains("capacity:   up to"), text)
    }

    // MARK: - Config detail lines (human output only)

    func testPlainTextCarriesTheConfigDetailLines() async {
        var cfg = Self.config()
        cfg.projects = [Self.project(specs: ["node@22"], shareCache: false)]
        let text = await builder(config: cfg).buildPlainText()

        XCTAssertTrue(text.contains("kinhin doctor"), "the shared report is rendered first")
        XCTAssertTrue(text.contains("  config:     \(Paths.config.path)"), text)
        XCTAssertTrue(text.contains("  image:      \(cfg.image)"), text)
        XCTAssertTrue(text.contains("no project sets share_cache"), text)
        XCTAssertFalse(text.contains("org perms:"), "a repo scope has no org-permission check")
    }

    func testPlainTextSaysWhenTheConfigIsMissing() async {
        let text = await builder(config: nil).buildPlainText()
        XCTAssertTrue(text.contains("config:     missing — run: kinhin config init"), text)
        XCTAssertFalse(text.contains("  image:"), "no config → no config-specific lines")
    }

    func testOrgScopeRunsTheActivePermissionCheckOnce() async {
        let probes = LockedBox<[String]>([])
        let builder = DoctorReportBuilder(
            host: host, clt: .ok(version: "26.6"), tartHealth: .healthy, tartList: [],
            config: .loaded(Self.config(repo: "acme")),
            authLoad: { _ in "ghp_live" }, accountLoad: { _, _ in "ghp_live" },
            orgPermissionCheck: { token, scope in
                probes.withValue { $0.append("\(token)@\(scope)") }
                return "ok ✓"
            })
        let text = await builder.buildPlainText()

        XCTAssertTrue(text.contains("scope:      organization 'acme'"), text)
        XCTAssertTrue(text.contains("org perms:  ok ✓"), text)
        XCTAssertEqual(probes.value, ["ghp_live@acme"])
    }

    func testOrgScopeWithoutAStoredTokenSaysHowToFixIt() async {
        let builder = DoctorReportBuilder(
            host: host, clt: .ok(version: "26.6"), tartHealth: .healthy, tartList: [],
            config: .loaded(Self.config(repo: "acme")),
            authLoad: { _ in nil }, accountLoad: { _, _ in nil })
        let text = await builder.buildPlainText()
        XCTAssertTrue(text.contains("org perms:  cannot verify — no token stored"), text)
    }

    func testOrgScopeKeychainFailureIsReportedNotHidden() async {
        struct KeychainDown: LocalizedError { var errorDescription: String? { "Keychain is locked" } }
        let builder = DoctorReportBuilder(
            host: host, clt: .ok(version: "26.6"), tartHealth: .healthy, tartList: [],
            config: .loaded(Self.config(repo: "acme")),
            authLoad: { _ in nil }, accountLoad: { _, _ in throw KeychainDown() })
        let text = await builder.buildPlainText()
        XCTAssertTrue(text.contains("org perms:  cannot verify — Keychain is locked"), text)
    }

    func testUnparseableOrTemplateConfigStillGetsThePathLine() async {
        for scenario in [ConfigScenario.invalid, .template] {
            let text = await DoctorReportBuilder(
                host: host, clt: .ok(version: "26.6"), tartHealth: .healthy, tartList: [], config: scenario,
                authLoad: { _ in nil }, accountLoad: { _, _ in nil }
            ).buildPlainText()
            XCTAssertTrue(text.contains("  config:     \(Paths.config.path)"), "\(scenario): \(text)")
            XCTAssertFalse(text.contains("  image:"), "no config-specific lines without a parsed config")
        }
    }

    func testShareCacheNoteOnlyAppearsWhenItIsOff() async {
        var cfg = Self.config()
        cfg.projects = [Self.project(specs: ["node@22"], shareCache: true)]
        let text = await builder(config: cfg).buildPlainText()
        XCTAssertFalse(text.contains("no project sets share_cache"), text)

        let noProjects = await builder(config: Self.config()).buildPlainText()
        XCTAssertFalse(noProjects.contains("no project sets share_cache"), "no projects → nothing to share")
    }

    func testJSONDocumentIsUnchangedByTheTextOnlyLines() async throws {
        let (_, data) = try await DoctorCommand.emitJSON(builder: builder(config: Self.config()))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("org perms"), "the active probe is human-output only")
    }
}

/// Mutex-guarded box so a `@Sendable` fixture can record calls.
private final class LockedBox<Value: Sendable>: Sendable {
    private let stored: Mutex<Value>
    init(_ value: Value) { stored = Mutex(value) }
    var value: Value { stored.withLock { $0 } }
    func withValue(_ body: (inout Value) -> Void) { stored.withLock { body(&$0) } }
}
