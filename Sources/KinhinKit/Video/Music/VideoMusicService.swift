import Foundation
import Yams

public struct MusicSearchOptions: Equatable, Sendable {
    public var query: String
    public var limit = 10
    /// Results shorter than this are dropped: most very short results are sound effects, not music.
    public var minSeconds = 20.0
    public var maxSeconds: Double?
    public var allowAttribution = false

    public init(query: String) { self.query = query }
}

public struct MusicSearchOutcome: Equatable, Sendable {
    public var tracks: [MusicTrack]
    /// Set when the online library could not be reached and only built-in matches are shown.
    public var warning: String?
}

public struct MusicAddResult: Equatable, Sendable {
    public var track: MusicTrack
    /// The downloaded audio and its provenance file (nil for a built-in track).
    public var savedFile: URL?
    public var sidecar: URL?
    /// The video whose config was edited (nil with `--no-config`, or when it is a JSON file).
    public var video: String?
    public var configFile: URL?
    public var edited: Bool
    public var credit: String?
    /// The `music:` block, for a config the user edits by hand.
    public var snippet: String
}

public struct VideoMusicUse: Codable, Equatable, Sendable {
    public var video: String
    /// `none`, `off`, or the track.
    public var track: String
    public var volume: Double?
}

public struct SavedMusicEntry: Codable, Equatable, Sendable {
    public var track: MusicSidecar
    public var usedBy: [String]
}

public struct MusicListing: Codable, Equatable, Sendable {
    public var videos: [VideoMusicUse]
    public var saved: [SavedMusicEntry]
}

/// Search the music library, add a track to a repository's video, and show what each video uses.
public struct VideoMusicService: Sendable {
    let openverse: OpenverseClient
    let library: MusicLibrary
    /// Where the last search is kept, so `add 3` can mean the third result.
    let cacheFile: URL

    public init(
        openverse: OpenverseClient = OpenverseClient(), library: MusicLibrary = MusicLibrary(),
        cacheFile: URL = Paths.stateDirectory.appendingPathComponent("video-music-search.json")
    ) {
        self.openverse = openverse
        self.library = library
        self.cacheFile = cacheFile
    }

    // MARK: search

    /// How many pages of results to read for one search (each one counts against the daily allowance).
    static let maxPages = 3

    /// Long enough, short enough, and a format the pipeline can mix.
    static func fits(_ track: MusicTrack, _ options: MusicSearchOptions) -> Bool {
        guard let seconds = track.seconds, seconds >= options.minSeconds else { return false }
        if let maxSeconds = options.maxSeconds, seconds > maxSeconds { return false }
        guard let type = track.fileType else { return true }
        return MusicLibrary.audioExtensions.contains(type)
    }

    public func search(_ options: MusicSearchOptions) async throws -> MusicSearchOutcome {
        let query = options.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw MusicError.emptyQuery }
        let builtIn = BuiltInMusic.matching(query)
        var warning: String?
        var online: [MusicTrack] = []
        do {
            // Pages of 20 (the anonymous limit); read up to three until enough of them fit.
            let wanted = max(1, options.limit) - builtIn.count
            let codes = MusicLicense.searchCodes(allowAttribution: options.allowAttribution)
            var page = 1
            while online.count < wanted, page <= Self.maxPages {
                let found = try await openverse.search(query: query, licenses: codes, page: page)
                if found.isEmpty { break }
                var seen = Set(online.map(\.id))
                online += found.filter { Self.fits($0, options) && seen.insert($0.id).inserted }
                page += 1
            }
        } catch let error as MusicError {
            guard !builtIn.isEmpty else { throw error }
            warning = error.localizedDescription
        }
        let tracks = Array((builtIn + online).prefix(max(1, options.limit)))
        try remember(tracks)
        return MusicSearchOutcome(tracks: tracks, warning: warning)
    }

    private func remember(_ tracks: [MusicTrack]) throws {
        try FileManager.default.createDirectory(
            at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(tracks).write(to: cacheFile, options: .atomic)
    }

    private func remembered() -> [MusicTrack] {
        (try? Data(contentsOf: cacheFile)).flatMap { try? JSONDecoder().decode([MusicTrack].self, from: $0) } ?? []
    }

    /// `3` (a row of the last search), a built-in name, or an Openverse id.
    public func resolve(_ reference: String) async throws -> MusicTrack {
        if let number = Int(reference) {
            let last = remembered()
            guard !last.isEmpty else { throw MusicError.noSearchYet(reference) }
            guard number >= 1, number <= last.count else {
                throw MusicError.notFound("\(reference) (the last search had \(last.count) results)")
            }
            return last[number - 1]
        }
        if let builtIn = BuiltInMusic.named(reference) { return builtIn }
        guard UUID(uuidString: reference) != nil else { throw MusicError.notFound(reference) }
        return try await openverse.detail(id: reference)
    }

    // MARK: add

    /// Which video to edit: the named one, or the only one there is.
    static func chooseVideo(_ requested: String?, in repo: URL) throws -> String {
        let all = VideoProjects.list(in: repo)
        if let requested {
            guard VideoProjects.file(named: requested, in: repo) != nil else {
                throw VideoError.unknownProject(name: requested, available: all)
            }
            return requested
        }
        switch all.count {
        case 0: throw MusicError.noVideos
        case 1: return all[0]
        default: throw MusicError.needsVideo(all)
        }
    }

    public func add(
        reference: String, repo: URL, video: String?, volume: Double?, allowAttribution: Bool, editConfig: Bool = true
    ) async throws -> MusicAddResult {
        let track = try await resolve(reference)
        if track.origin == .openverse, !MusicLicense.isAllowed(track.license, allowAttribution: allowAttribution) {
            throw MusicError.licenseNotAllowed(title: track.title, license: track.license)
        }
        // Decide the video before downloading anything.
        let chosen = editConfig ? try Self.chooseVideo(video, in: repo) : nil

        var savedFile: URL?
        var sidecar: URL?
        var credit: String?
        let trackValue: String
        if track.origin == .builtIn {
            trackValue = track.id
        } else {
            let saved = try await library.save(track, in: repo)
            savedFile = saved.file
            sidecar = saved.sidecar
            credit = saved.credit
            trackValue = "\(MusicLibrary.folder)/\(saved.file.lastPathComponent)"
        }
        let snippet = Self.snippet(track: trackValue, volume: volume, credit: credit)

        var edited = false
        var configFile: URL?
        var editedVideo: String?
        if let chosen, let file = VideoProjects.file(named: chosen, in: repo), file.pathExtension != "json" {
            let original = try String(contentsOf: file, encoding: .utf8)
            let updated = VideoConfigEditor.setMusic(in: original, track: trackValue, volume: volume, credit: credit)
            try Data(updated.text.utf8).write(to: file, options: .atomic)
            edited = true
            configFile = file
            editedVideo = chosen
        } else if let chosen {
            configFile = VideoProjects.file(named: chosen, in: repo)
            editedVideo = chosen
        }
        return MusicAddResult(
            track: track, savedFile: savedFile, sidecar: sidecar, video: editedVideo, configFile: configFile,
            edited: edited, credit: credit, snippet: snippet)
    }

    static func snippet(track: String, volume: Double?, credit: String?) -> String {
        var lines = ["music:", "  track: \(VideoConfigEditor.quoted(track))"]
        if let volume { lines.append("  volume: \(VideoConfigEditor.formatted(volume))") }
        if let credit { lines.append("  credit: \(VideoConfigEditor.quoted(credit))") }
        return lines.joined(separator: "\n")
    }

    // MARK: preview

    /// Downloads `track` to a temporary file to listen to; the caller deletes it.
    public func fetchForPreview(_ track: MusicTrack) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-music-\(UUID().uuidString)", isDirectory: true)
        return try await library.download(track, to: directory).file
    }

    // MARK: list

    /// What each video in `repo` uses, and the saved tracks with the videos that use them.
    public static func list(in repo: URL) -> MusicListing {
        let uses: [VideoMusicUse] = VideoProjects.list(in: repo).map { name in
            guard let file = VideoProjects.file(named: name, in: repo),
                let text = try? String(contentsOf: file, encoding: .utf8),
                let root = (try? Yams.load(yaml: text)) as? [String: Any]
            else { return VideoMusicUse(video: name, track: "none", volume: nil) }
            return describe(music: root["music"], video: name)
        }
        let saved = MusicLibrary.saved(in: repo).map { sidecar in
            SavedMusicEntry(
                track: sidecar,
                usedBy: uses.filter { $0.track == "\(MusicLibrary.folder)/\(sidecar.file)" }.map(\.video))
        }
        return MusicListing(videos: uses, saved: saved)
    }

    static func describe(music: Any?, video: String) -> VideoMusicUse {
        switch music {
        case nil: return VideoMusicUse(video: video, track: "none", volume: nil)
        case let flag as Bool: return VideoMusicUse(video: video, track: flag ? "none" : "off", volume: nil)
        case let name as String: return VideoMusicUse(video: video, track: name, volume: nil)
        case let table as [String: Any]:
            let off = (table["enabled"] as? Bool) == false
            let track = table["track"] as? String
            let volume = (table["volume"] as? Double) ?? (table["volume"] as? Int).map(Double.init)
            return VideoMusicUse(video: video, track: off ? "off" : (track ?? "none"), volume: volume)
        default: return VideoMusicUse(video: video, track: "none", volume: nil)
        }
    }
}
