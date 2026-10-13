import AppKit
import Foundation
import KinhinKit
import Observation

/// State behind the "Make a Video…" sheet: a repository, the videos in its `.kinhin/videos/`, a build with live output, and a
/// music search that adds a track to the selected video. It is the same code `kinhin video` runs (KinhinKit `Video/`).
@MainActor
@Observable
final class VideosModel {
    enum Phase: Equatable {
        case idle
        case building
        case succeeded
        case failed(String)
    }

    /// Pick the repository folder. Tests inject a stub; the app uses `NSOpenPanel`.
    @ObservationIgnored var chooseFolder: () async -> URL? = { @MainActor in
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Makes the runner for one build; its output goes to `onLine`.
    @ObservationIgnored var makeRunner: (@escaping @Sendable (String) -> Void) -> VideoRunner = { onLine in
        VideoRunner(process: CapturingProcessRunner(onLine: onLine))
    }

    @ObservationIgnored var music = VideoMusicService()

    private(set) var repository: URL?
    private(set) var videos: [String] = []
    var selected: String?
    var fast = true
    var newVideoName = ""
    private(set) var phase: Phase = .idle
    /// The last lines of the build's output.
    private(set) var log: [String] = []
    private(set) var outputDirectory: URL?
    /// An error or notice for the user (shown as an alert); cleared when dismissed.
    var message: String?

    var musicQuery = ""
    private(set) var musicResults: [MusicTrack] = []
    private(set) var musicSearching = false
    /// What the last search or add said (a warning, or what was set in which video).
    private(set) var musicNotice: String?
    private(set) var addingMusic = false

    @ObservationIgnored private var buildTask: Task<Void, Never>?
    static let logLimit = 300

    init() {}

    var isBuilding: Bool { phase == .building }
    var canBuild: Bool { repository != nil && selected != nil && !isBuilding }

    // MARK: repository and videos

    func chooseRepository() async {
        guard let url = await chooseFolder() else { return }
        setRepository(url)
    }

    func setRepository(_ url: URL) {
        repository = url
        phase = .idle
        log = []
        outputDirectory = nil
        reload()
    }

    func reload() {
        guard let repository else { return }
        videos = VideoProjects.list(in: repository)
        if let selected, videos.contains(selected) { return }
        selected = videos.first
    }

    func createVideo() {
        guard let repository else { return }
        let name = newVideoName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try VideoStarter.write(name: name.isEmpty ? "launch" : name, in: repository)
            newVideoName = ""
            reload()
            selected = name.isEmpty ? "launch" : name
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: build

    func build() {
        guard canBuild, let repository, let selected else { return }
        phase = .building
        log = []
        outputDirectory = nil
        var options = VideoBuildOptions(project: selected)
        options.fast = fast
        buildTask = Task { [weak self] in
            await self?.run(options: options, repository: repository)
        }
    }

    func cancelBuild() {
        buildTask?.cancel()
    }

    /// The build itself, awaitable so tests can drive it.
    func run(options: VideoBuildOptions, repository: URL) async {
        let runner = makeRunner { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }
        do {
            let plan = try await runner.plan(options: options, repo: repository, runtime: nil, image: nil)
            append("==> \(options.project): \(plan.runtime.rawValue), image \(plan.image)")
            let code = try await runner.build(plan: plan)
            if code == 0 {
                outputDirectory = plan.outputDirectory
                phase = .succeeded
            } else {
                phase = .failed(
                    String(
                        localized: "The build failed (exit \(code)). The output above says why.", bundle: .l10n,
                        comment: "Videos sheet: a build exited non-zero; %lld is its exit code"))
            }
        } catch is CancellationError {
            phase = .failed(
                String(localized: "Cancelled.", bundle: .l10n, comment: "Videos sheet: the user stopped a build"))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func append(_ line: String) {
        log.append(line)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    // MARK: music

    func searchMusic() async {
        let query = musicQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        musicSearching = true
        musicNotice = nil
        defer { musicSearching = false }
        do {
            let outcome = try await music.search(MusicSearchOptions(query: query))
            musicResults = outcome.tracks
            musicNotice = outcome.warning
        } catch {
            musicResults = []
            musicNotice = error.localizedDescription
        }
    }

    /// Adds result `index` (0-based, as listed) to the selected video.
    func addMusic(at index: Int) async {
        guard let repository, let selected, musicResults.indices.contains(index) else { return }
        addingMusic = true
        defer { addingMusic = false }
        do {
            let result = try await music.add(
                reference: String(index + 1), repo: repository, video: selected, volume: nil, allowAttribution: false)
            let title = result.track.title
            musicNotice =
                result.edited
                ? String(
                    localized: "Added “\(title)” to \(selected).", bundle: .l10n,
                    comment: "Videos sheet: a music track was added to a video; %1$@ is its title, %2$@ the video")
                : String(
                    localized: "Saved “\(title)”. Add this to the video's config:\n\(result.snippet)", bundle: .l10n,
                    comment:
                        "Videos sheet: a track was saved but the config is JSON and was not edited; %1$@ is the title, %2$@ the music: block"
                )
        } catch {
            musicNotice = error.localizedDescription
        }
    }
}
