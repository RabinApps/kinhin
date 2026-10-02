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
            "This replaces the base image with a fresh one that has only the runner agents. It can take 10–30 minutes and downloads a lot. Per-repo images with toolchains are baked separately, when a job needs them."
        return AlertKit.confirm(
            title: "Rebuild the \(ToolchainsModel.runtimeTitle(runtime))?", message: text,
            confirmTitle: "Rebuild Image", style: .informational)
    }
    /// Runs the actual image build for a runtime (real implementation below).
    @ObservationIgnored var rebuild: (_ runtime: RuntimeID, _ config: KinhinConfig) async throws -> Void = {
        runtime, cfg in
        try await ImageBuildService.rebuild(runtime, config: cfg)
    }
    /// The derived images kinhin has recorded.
    @ObservationIgnored var loadImageRecords: () -> [ProjectImageRecord] = { ProjectImageStore().all }
    /// The tart images on disk, for sizes. Throws when tart is not installed.
    @ObservationIgnored var listTartImages: () async throws -> [TartVM] = {
        try await TartController(configuredPath: nil).list()
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
            overview = nil
            imageRuntimes = []
            status = Line(
                text:
                    "config.yaml has a problem — \(error.localizedDescription). Use Advanced → App → Open config file.",
                style: .error)
            return
        }
        overview = ProjectToolchainsOverview.build(config: cfg, images: loadImageRecords())
        refreshRuntimes(cfg)
        if !busy { status = Line(text: "") }
        Task { [weak self] in await self?.refreshImageSizes() }
    }

    /// Fills in image sizes from `tart list`; sizes stay unknown when tart is unavailable.
    func refreshImageSizes() async {
        do {
            let images = try await listTartImages()
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
        if TartController.isInstalled() { runtimes.append(ImageRuntime(runtime: .tart, platform: .macOS)) }
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
        if row.isDefault { return "No toolchains baked" }
        switch row.source {
        case .repoFile: return ".kinhin.yml honored"
        case .projectFallback: return "Project toolchains"
        case .none: return "No toolchains"
        }
    }

    /// The explanation under a row's title.
    static func detail(_ row: ProjectToolchainsRow) -> String {
        switch row.source {
        case .repoFile:
            var text = "Versions come from .kinhin.yml in the repo at each job's branch/tag."
            text +=
                row.hasToolchains
                ? " Used when a repo has no usable file: the project toolchains below."
                : " With no usable file, jobs use the base image."
            return text
        case .projectFallback:
            return "The repo's .kinhin.yml is ignored (repo_file is off); these versions apply."
        case .none:
            return row.isDefault
                ? "No toolchains baked: jobs use the base image (they can still run `kinhin-toolchain install` per job)."
                : "No toolchains on this project entry and repo_file is off: jobs use the base image."
        }
    }

    /// "name · 12 GB · last used 2 hours ago", leaving out what is unknown.
    func imageLine(_ record: ProjectImageRecord) -> String {
        var parts = [record.name]
        if let size = imageSizesGB[record.name] { parts.append("\(size) GB") }
        parts.append("last used " + Self.relativeDate(record.lastUsedAt))
        return parts.joined(separator: " · ")
    }

    /// "name · 33 GB" for the base image on the "other repos" row.
    func baseImageLine(_ name: String) -> String {
        imageSizesGB[name].map { "\(name) · \($0) GB" } ?? name
    }

    static func relativeDate(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    // MARK: - Copy

    func copy(_ text: String, id: String) {
        copyToPasteboard(text)
        copiedID = id
    }

    // MARK: - Rebuild base image

    @discardableResult
    func startRebuild(_ runtime: RuntimeID) -> Task<Void, Never>? {
        guard !busy, confirmRebuild(runtime) else { return nil }
        let cfg: KinhinConfig
        do {
            cfg = try ConfigLoader.load(from: configURL)
        } catch {
            status = Line(text: "Not started — \(error.localizedDescription)", style: .error)
            return nil
        }
        busy = true
        status = Line(text: "Rebuilding the \(Self.runtimeTitle(runtime))… this can take a while.")
        let rebuild = self.rebuild
        return Task { [weak self] in
            do {
                try await rebuild(runtime, cfg)
                self?.busy = false
                self?.reload()
                self?.status = Line(text: "Rebuilt the \(Self.runtimeTitle(runtime)) ✓", style: .ok)
            } catch {
                self?.busy = false
                self?.status = Line(text: "Not rebuilt — \(error.localizedDescription)", style: .error)
            }
        }
    }

    static func runtimeTitle(_ runtime: RuntimeID) -> String {
        switch runtime {
        case .tart: return "macOS image (tart)"
        case .appleContainer: return "Linux image (Apple container)"
        case .docker: return "Linux image (Docker)"
        case .host: return "host"
        }
    }

    // MARK: - Test hooks

    var statusTextForTesting: String { status.text }
}
