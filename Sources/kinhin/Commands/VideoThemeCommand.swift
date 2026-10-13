import Foundation
import KinhinKit

/// `kinhin video theme list | new`: the themes a video can use, and a starter file for a theme of your own. The logic is in
/// KinhinKit (`Video/VideoThemes.swift`); this file is flags and output.
enum VideoThemeCommand {
    static func run(subcommand: String?, _ rest: [String]) throws {
        switch subcommand {
        case "new": try create(rest)
        default: try list(rest)
        }
    }

    struct ListDocument: Codable, Equatable {
        struct Entry: Codable, Equatable {
            var name: String
            var summary: String
            var builtIn: Bool
        }
        var themes: [Entry]
    }

    static func list(_ rest: [String]) throws {
        let repo = VideoCommand.repository(rest)
        let own = VideoThemes.own(in: repo)
        let builtIn = VideoThemes.builtIn
        var entries = builtIn.map {
            ListDocument.Entry(name: $0.name, summary: $0.summary, builtIn: !own.contains($0.name))
        }
        entries += own.filter { name in !builtIn.contains { $0.name == name } }.map {
            ListDocument.Entry(name: $0, summary: "yours (\(VideoThemes.folder)/)", builtIn: false)
        }
        if hasFlag("--json", in: rest) {
            try emitJSON(ListDocument(themes: entries))
            return
        }
        let width = (entries.map(\.name.count).max() ?? 0) + 2
        for entry in entries {
            let replaced = !entry.builtIn && builtIn.contains { $0.name == entry.name }
            let note = replaced ? "yours, replacing the built-in" : entry.summary
            print(entry.name + String(repeating: " ", count: width - entry.name.count) + note)
        }
    }

    static func create(_ rest: [String]) throws {
        guard let name = VideoCommand.operand(in: rest) else {
            throw CLIError(
                "what should the theme be called? For example: kinhin video theme new brand --from midnight",
                exit: .usage)
        }
        do {
            let repo = VideoCommand.repository(rest)
            let file = try VideoThemes.write(name: name, from: flag("--from", in: rest) ?? "paper", in: repo)
            print("wrote \(VideoCommand.relative(file, to: repo))")
            print(
                "Edit it, then use it with `theme: \(name)` in a video or `kinhin video build <video> --theme \(name)`."
            )
        } catch let error as VideoError {
            throw CLIError(error.localizedDescription, exit: .usage)
        }
    }
}
