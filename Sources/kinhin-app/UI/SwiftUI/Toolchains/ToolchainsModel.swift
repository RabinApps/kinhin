import Foundation
import KinhinKit
import Observation

/// State behind the Advanced → Toolchains tab. The tab is read-only:
/// toolchain versions are declared in each repo's `.kinhin.yml` (or in the
/// `projects:` / `toolchains:` YAML), never edited here. It shows how every
/// configured repo resolves its toolchains, the derived images kinhin has
/// built, and offers the one action that does not edit toolchains: rebuilding
/// the base image.
@MainActor
@Observable
final class ToolchainsModel {
    typealias Line = StatusLine

    /// A runtime that is set up, with the platform its image targets.
    struct ImageRuntime {
        let runtime: RuntimeID
        let platform: ToolchainPlatform
    }

    var configURL: URL = Paths.config

    /// Confirms a rebuild. Injectable so tests never open a modal.
    @ObservationIgnored var confirmRebuild: (_ runtime: RuntimeID) -> Bool = { runtime in
        let text =
            String(
                localized:
                    "This replaces the base image with a fresh one that has only the runner agents. It can take 10–30 minutes and downloads a lot. Per-repo images with toolchains are baked separately, when a job needs them.",
                bundle: .l10n, comment: "Rebuild-image confirmation body")
        return AlertKit.confirm(
            title: String(
                localized: "Rebuild the \(ToolchainsModel.runtimeTitle(runtime))?", bundle: .l10n,
                comment: "Rebuild-image confirmation title; %@ is a runtime image name"), message: text,
            confirmTitle: String(
                localized: "Rebuild Image", bundle: .l10n, comment: "Confirm button of the rebuild-image alert"),
            style: .informational)
    }
    /// Runs the actual image build for a runtime (real implementation below).
    @ObservationIgnored var rebuild: (_ runtime: RuntimeID, _ config: KinhinConfig) async throws -> Void = {
        runtime, cfg in
        try await ImageBuildService.rebuild(runtime, config: cfg)
    }
    /// The derived images kinhin has recorded.
    @ObservationIgnored var loadImageRecords: () -> [ProjectImageRecord] = { ProjectImageStore().all }
    /// The tart images on disk, for sizes. Throws when tart is not installed.
    /// The configured `tart_path:` travels with the call, so the listing asks
    /// for the very binary the fleet runs instead of a PATH lookalike.
    @ObservationIgnored var listTartImages: (_ tartPath: String?) async throws -> [TartVM] = { tartPath in
        try await TartController(configuredPath: tartPath).list()
    }
    /// Puts text on the clipboard. Injectable so tests leave the real one alone.
    @ObservationIgnored var copyToPasteboard: (String) -> Void = ToolchainsGuide.copyToPasteboard

    // MARK: - Display state

    private(set) var overview: ProjectToolchainsOverview?
    /// Disk size of each tart image by name, when known.
    private(set) var imageSizesGB: [String: Int] = [:]
    private(set) var status = Line(text: "")
    private(set) var busy = false
    private(set) var imageRuntimes: [ImageRuntime] = []
    private(set) var copiedID: String?
    private var baseImageValues: [RuntimeID: String] = [:]
    /// The configured tart binary from the last successful load (`tart_path:`;
    /// nil = let the probe search), so sizes list through it too. The runtime
    /// row takes it straight from the config it just loaded.
    private var tartPath: String?

    var rows: [ProjectToolchainsRow] { overview?.rows ?? [] }
    var repoFileImages: [ProjectImageRecord] { overview?.repoFileImages ?? [] }
    var rebuildEnabled: Bool { !busy && overview != nil }

    func baseImage(for runtime: RuntimeID) -> String? { baseImageValues[runtime] }

    // MARK: - Loading

    /// Reads config.yaml and the image index. A config that fails to load is
    /// reported instead of rendering an empty page.
    func reload() {
        let cfg: KinhinConfig
        do {
            cfg = try ConfigLoader.load(from: configURL)
        } catch {
            tartPath = nil
            overview = nil
            imageRuntimes = []
            status = Line(
                text:
                    String(
                        localized:
                            "config.yaml has a problem — \(error.localizedDescription). Use Advanced → App → Open config file.",
                        bundle: .l10n, comment: "Toolchains tab status; %@ is the config error"),
                style: .error)
            return
        }
        tartPath = cfg.tartPath
        overview = ProjectToolchainsOverview.build(config: cfg, images: loadImageRecords())
        refreshRuntimes(cfg)
        if !busy { status = Line(text: "") }
        Task { [weak self] in await self?.refreshImageSizes() }
    }

    /// Fills in image sizes from `tart list`; sizes stay unknown when tart is unavailable.
    func refreshImageSizes() async {
        do {
            let images = try await listTartImages(tartPath)
            imageSizesGB = Dictionary(
                images.compactMap { image in image.diskGB.map { (image.name, $0) } },
                uniquingKeysWith: { first, _ in first })
        } catch is CancellationError {
            return
        } catch {
            // Sizes are cosmetic: without tart the rows simply omit them.
            Log.info("images", "image sizes unavailable: \(error.localizedDescription)")
            imageSizesGB = [:]
        }
    }

    /// One image row per runtime that is actually set up.
    private func refreshRuntimes(_ cfg: KinhinConfig) {
        var runtimes: [ImageRuntime] = []
        if TartController.isInstalled(configuredPath: cfg.tartPath) {
            runtimes.append(ImageRuntime(runtime: .tart, platform: .macOS))
        }
        if let container = cfg.container {
            runtimes.append(ImageRuntime(runtime: .appleContainer, platform: .linux))
            baseImageValues[.appleContainer] = container.baseImage
        }
        if let docker = cfg.docker {
            runtimes.append(ImageRuntime(runtime: .docker, platform: .linux))
            baseImageValues[.docker] = docker.baseImage
        }
        imageRuntimes = runtimes
        baseImageValues = baseImageValues.filter { key, _ in runtimes.contains { $0.runtime == key } }
    }

    // MARK: - Row text

    /// Where a row's toolchains come from, in one line.
    static func sourceTitle(_ row: ProjectToolchainsRow) -> String {
        if row.isDefault {
            return String(localized: "No toolchains baked", bundle: .l10n, comment: "Toolchains tab row source label")
        }
        switch row.source {
        case .repoFile:
            return String(
                localized: ".kinhin.yml honored", bundle: .l10n,
                comment: "Toolchains tab row source label; keep .kinhin.yml verbatim")
        case .projectFallback:
            return String(localized: "Project toolchains", bundle: .l10n, comment: "Toolchains tab row source label")
        case .none: return String(localized: "No toolchains", bundle: .l10n, comment: "Toolchains tab row source label")
        }
    }

    /// The explanation under a row's title.
    static func detail(_ row: ProjectToolchainsRow) -> String {
        switch row.source {
        case .repoFile:
            return row.hasToolchains
                ? String(
                    localized:
                        "Versions come from .kinhin.yml in the repo at each job's branch/tag. Used when a repo has no usable file: the project toolchains below.",
                    bundle: .l10n, comment: "Toolchains tab row explanation; keep .kinhin.yml verbatim")
                : String(
                    localized:
                        "Versions come from .kinhin.yml in the repo at each job's branch/tag. With no usable file, jobs use the base image.",
                    bundle: .l10n, comment: "Toolchains tab row explanation; keep .kinhin.yml verbatim")
        case .projectFallback:
            return String(
                localized: "The repo's .kinhin.yml is ignored (repo_file is off); these versions apply.", bundle: .l10n,
                comment: "Toolchains tab row explanation; keep .kinhin.yml and repo_file verbatim")
        case .none:
            return row.isDefault
                ? String(
                    localized:
                        "No toolchains baked: jobs use the base image (they can still run `kinhin-toolchain install` per job).",
                    bundle: .l10n, comment: "Toolchains tab row explanation; the backticked command stays verbatim")
                : String(
                    localized: "No toolchains on this project entry and repo_file is off: jobs use the base image.",
                    bundle: .l10n, comment: "Toolchains tab row explanation; keep repo_file verbatim")
        }
    }

    /// "name · 12 GB · last used 2 hours ago", leaving out what is unknown.
    func imageLine(_ record: ProjectImageRecord) -> String {
        var parts = [record.name]
        if let size = imageSizesGB[record.name] { parts.append(Self.sizeText(gigabytes: size)) }
        parts.append(
            String(
                localized: "last used \(Self.relativeDate(record.lastUsedAt))", bundle: .l10n,
                comment: "Toolchains tab image row; %@ is a relative time such as 2 hours ago"))
        return parts.joined(separator: " · ")
    }

    /// "name · 33 GB" for the base image on the "other repos" row.
    func baseImageLine(_ name: String) -> String {
        imageSizesGB[name].map { "\(name) · \(Self.sizeText(gigabytes: $0))" } ?? name
    }

    static func relativeDate(_ date: Date, now: Date = Date()) -> String {
        AppFormat.relative(date, to: now)
    }

    /// An image size given in whole gigabytes, formatted for the user's locale ("33 GB").
    static func sizeText(gigabytes: Int) -> String {
        AppFormat.bytes(Int64(gigabytes) * 1_000_000_000)
    }

    // MARK: - Copy

    func copy(_ text: String, id: String) {
        copyToPasteboard(text)
        copiedID = id
    }

    // MARK: - Rebuild base image

    /// The in-flight rebuild's task, so the Cancel button can stop it (the
    /// build then unwinds through its scratch-VM cleanup and keeps the
    /// previous image).
    @ObservationIgnored private(set) var runningTask: Task<Void, Never>?

    @discardableResult
    func startRebuild(_ runtime: RuntimeID) -> Task<Void, Never>? {
        guard !busy, confirmRebuild(runtime) else { return nil }
        let cfg: KinhinConfig
        do {
            cfg = try ConfigLoader.load(from: configURL)
        } catch {
            status = Line(
                text: String(
                    localized: "Not started — \(error.localizedDescription)", bundle: .l10n,
                    comment: "Toolchains tab status; %@ is the reason"), style: .error)
            return nil
        }
        busy = true
        status = Line(
            text: String(
                localized: "Rebuilding the \(Self.runtimeTitle(runtime))… this can take a while.", bundle: .l10n,
                comment: "Toolchains tab status; %@ is a runtime image name"))
        let rebuild = self.rebuild
        let task = Task { [weak self] in
            do {
                try await rebuild(runtime, cfg)
                self?.busy = false
                self?.reload()
                self?.status = Line(
                    text: String(
                        localized: "Rebuilt the \(Self.runtimeTitle(runtime)) ✓", bundle: .l10n,
                        comment: "Toolchains tab status; %@ is a runtime image name"), style: .ok)
            } catch is CancellationError {
                self?.busy = false
                self?.reload()
                self?.status = Line(
                    text: String(
                        localized: "Cancelled — the previous image is untouched", bundle: .l10n,
                        comment: "Toolchains tab status after cancelling"), style: .warn)
            } catch {
                self?.busy = false
                self?.status = Line(
                    text: String(
                        localized: "Not rebuilt — \(error.localizedDescription)", bundle: .l10n,
                        comment: "Toolchains tab status; %@ is the reason"), style: .error)
            }
            self?.runningTask = nil
        }
        runningTask = task
        return task
    }

    /// The Cancel button's action: cancels the in-flight rebuild.
    func cancelRunning() {
        runningTask?.cancel()
    }

    static func runtimeTitle(_ runtime: RuntimeID) -> String {
        switch runtime {
        case .tart:
            return String(localized: "macOS image (tart)", bundle: .l10n, comment: "Name of the macOS runtime image")
        case .appleContainer:
            return String(
                localized: "Linux image (Apple container)", bundle: .l10n,
                comment: "Name of the Apple container runtime image")
        case .docker:
            return String(localized: "Linux image (Docker)", bundle: .l10n, comment: "Name of the Docker runtime image")
        case .host: return String(localized: "host", bundle: .l10n, comment: "Name of the host runtime")
        }
    }

    // MARK: - Test hooks

    var statusTextForTesting: String { status.text }
}
