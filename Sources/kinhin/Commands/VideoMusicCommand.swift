import Foundation
import KinhinKit

/// `kinhin video music search | preview | add | list`: find openly licensed music, put it in a video's config, and see what each
/// video uses. The logic is in KinhinKit (`Video/Music/`); this file is flags and output.
enum VideoMusicCommand {
    private static let valueFlags: Set<String> = [
        "--dir", "--limit", "--min-seconds", "--max-seconds", "--license", "--video", "--volume",
    ]

    /// The operands: every token that is neither a flag nor a flag's value.
    static func operands(in args: [String]) -> [String] {
        var out: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext {
                skipNext = false
            } else if valueFlags.contains(arg) {
                skipNext = true
            } else if !arg.hasPrefix("-") {
                out.append(arg)
            }
        }
        return out
    }

    /// `cc0` (the default) or `cc-by`.
    static func allowsAttribution(_ rest: [String]) throws -> Bool {
        switch flag("--license", in: rest) {
        case nil, "cc0": return false
        case "cc-by": return true
        default: throw CLIError("--license takes cc0 or cc-by", exit: .usage)
        }
    }

    static func number(_ name: String, in rest: [String]) throws -> Double? {
        guard let text = flag(name, in: rest) else { return nil }
        guard let value = Double(text), value >= 0 else {
            throw CLIError("\(name) takes a number of seconds", exit: .usage)
        }
        return value
    }

    static func translate(_ error: Error) -> Error {
        if let error = error as? MusicError {
            switch error {
            case .emptyQuery, .noSearchYet, .notFound, .licenseNotAllowed, .needsVideo, .noVideos:
                return CLIError(error.localizedDescription, exit: .usage)
            case .rateLimited, .network, .downloadRefused:
                return CLIError(error.localizedDescription, exit: .runtime)
            }
        }
        if let error = error as? VideoError { return CLIError(error.localizedDescription, exit: .usage) }
        return error
    }

    static func run(subcommand: String?, _ rest: [String]) async throws {
        do {
            switch subcommand {
            case "search": try await search(rest)
            case "preview": try await preview(rest)
            case "add": try await add(rest)
            default: try list(rest)
            }
        } catch {
            throw translate(error)
        }
    }

    // MARK: search

    static func search(_ rest: [String]) async throws {
        var options = MusicSearchOptions(query: operands(in: rest).joined(separator: " "))
        if let limit = flag("--limit", in: rest) {
            guard let n = Int(limit), (1...50).contains(n) else {
                throw CLIError("--limit takes 1 to 50", exit: .usage)
            }
            options.limit = n
        }
        if let min = try number("--min-seconds", in: rest) { options.minSeconds = min }
        options.maxSeconds = try number("--max-seconds", in: rest)
        options.allowAttribution = try allowsAttribution(rest)

        let outcome = try await VideoMusicService().search(options)
        if let warning = outcome.warning { warn("\(warning). Showing the built-in tracks only.") }
        if hasFlag("--json", in: rest) {
            try emitJSON(outcome.tracks)
            return
        }
        if outcome.tracks.isEmpty {
            print(
                "nothing found for \"\(options.query)\" (CC0 and public domain, at least \(Int(options.minSeconds)) s)."
            )
            print("Try other words, --min-seconds 5, or --license cc-by.")
            return
        }
        print(table(outcome.tracks))
        print("\nListen with `kinhin video music preview <number>`; add one with `kinhin video music add <number>`.")
        print("Licenses are as declared by the source. You are responsible for how you use a track.")
    }

    static func table(_ tracks: [MusicTrack]) -> String {
        func clip(_ text: String, _ width: Int) -> String {
            text.count <= width ? text : String(text.prefix(width - 1)) + "…"
        }
        func pad(_ text: String, _ width: Int) -> String {
            text + String(repeating: " ", count: max(0, width - text.count))
        }
        var lines = [pad("#", 3) + pad("TITLE", 42) + pad("BY", 22) + pad("LENGTH", 8) + pad("SOURCE", 16) + "LICENSE"]
        for (index, track) in tracks.enumerated() {
            let source = track.origin == .builtIn ? "built in" : track.source
            lines.append(
                pad(String(index + 1), 3) + pad(clip(track.title, 40), 42) + pad(clip(track.creator ?? "", 20), 22)
                    + pad(duration(track.seconds), 8) + pad(clip(source, 14), 16)
                    + MusicLicense.displayName(track.license, version: nil))
        }
        return lines.joined(separator: "\n")
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds else { return "" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: preview

    static func preview(_ rest: [String]) async throws {
        guard let reference = operands(in: rest).first else {
            throw CLIError("preview which track? Use a number from `kinhin video music search`", exit: .usage)
        }
        let service = VideoMusicService()
        let track = try await service.resolve(reference)
        if let page = track.landingURL { print("\(track.title): \(page)") }
        guard track.origin == .openverse else {
            print("A built-in track plays from the video image; open the page above to hear it.")
            return
        }
        let file = try await service.fetchForPreview(track)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let code = try await InheritedProcessRunner().runInteractive(["/usr/bin/afplay", file.path])
        if code != 0 { warn("afplay exited \(code)") }
    }

    // MARK: add

    static func add(_ rest: [String]) async throws {
        guard let reference = operands(in: rest).first else {
            throw CLIError("add which track? Use a number from `kinhin video music search`", exit: .usage)
        }
        var volume: Double?
        if let text = flag("--volume", in: rest) {
            guard let v = Double(text), (0...1.5).contains(v) else {
                throw CLIError("--volume takes a number from 0 to 1.5", exit: .usage)
            }
            volume = v
        }
        let repo = VideoCommand.repository(rest)
        let result = try await VideoMusicService().add(
            reference: reference, repo: repo, video: flag("--video", in: rest), volume: volume,
            allowAttribution: try allowsAttribution(rest), editConfig: !hasFlag("--no-config", in: rest))

        let license = MusicLicense.displayName(result.track.license, version: result.track.licenseVersion)
        print("\(result.track.title)\(result.track.creator.map { " by \($0)" } ?? "") (\(license))")
        if let file = result.savedFile { print("saved \(VideoCommand.relative(file, to: repo))") }
        if let video = result.video, result.edited, let configFile = result.configFile {
            print("set music in \(VideoProjects.folder)/\(video) (\(VideoCommand.relative(configFile, to: repo)))")
        } else {
            if let file = result.configFile {
                print("\(VideoCommand.relative(file, to: repo)) is JSON, so it was not edited. Add this by hand:")
            } else {
                print("Add this to a video's config:")
            }
            print(result.snippet)
        }
        if let credit = result.credit { print("\nCredit required in your video description:\n  \(credit)") }
    }

    // MARK: list

    static func list(_ rest: [String]) throws {
        let repo = VideoCommand.repository(rest)
        let listing = VideoMusicService.list(in: repo)
        if hasFlag("--json", in: rest) {
            try emitJSON(listing)
            return
        }
        guard !listing.videos.isEmpty else {
            print("no videos in \(VideoProjects.folder)/. Create one with `kinhin video init`.")
            return
        }
        print("VIDEOS")
        for use in listing.videos {
            let volume = use.volume.map { " (volume \(VideoConfigEditor.formatted($0)))" } ?? ""
            print("  \(use.video): \(use.track)\(volume)")
        }
        if !listing.saved.isEmpty {
            print("\nSAVED TRACKS (\(MusicLibrary.folder)/)")
            for entry in listing.saved {
                let by = entry.track.creator.map { " by \($0)" } ?? ""
                let used = entry.usedBy.isEmpty ? "unused" : "used by \(entry.usedBy.joined(separator: ", "))"
                let license = MusicLicense.displayName(entry.track.license, version: nil)
                print("  \(entry.track.file): \(entry.track.title)\(by), \(license), \(used)")
            }
        }
    }
}
