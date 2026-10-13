import Foundation

/// The themes that ship in the video image (`video/themes/*.json`), and `kinhin video theme new`: a starter file for a theme of
/// your own in `.kinhin/videos/themes/`. A test keeps this table equal to the theme files.
public enum VideoThemes {
    public struct BuiltIn: Equatable, Sendable {
        public let name: String
        public let summary: String
        public let font: String
        public let ink: String
        public let paper: String
        public let accent: String
    }

    public static let folder = "\(VideoProjects.folder)/themes"

    public static let builtIn: [BuiltIn] = [
        BuiltIn(
            name: "paper", summary: "Soft white to pale blue, black ink. The kinhin launch look.", font: "Inter",
            ink: "#000000",
            paper: "#ffffff", accent: "#000000"),
        BuiltIn(
            name: "clean", summary: "Flat near-white with one blue accent.", font: "Inter", ink: "#1d1d1f",
            paper: "#ffffff",
            accent: "#0a84ff"),
        BuiltIn(
            name: "midnight", summary: "Deep navy with a periwinkle accent.", font: "Inter", ink: "#f5f7ff",
            paper: "#0b1020",
            accent: "#7aa2ff"),
        BuiltIn(
            name: "blueprint", summary: "White line work on blueprint blue, monospaced.", font: "DejaVu Sans Mono",
            ink: "#eaf3ff",
            paper: "#0b3a6b", accent: "#ffd166"),
        BuiltIn(
            name: "chalk", summary: "Chalk on a green board, handwritten.", font: "Comic Neue", ink: "#f4f1e6",
            paper: "#1f3a2e",
            accent: "#ffd9a0"),
    ]

    public static func builtIn(named name: String) -> BuiltIn? {
        builtIn.first { $0.name == name.lowercased() }
    }

    public static func directory(in repo: URL) -> URL {
        repo.appendingPathComponent(folder, isDirectory: true)
    }

    /// The names of the themes in `<repo>/.kinhin/videos/themes/` (their file names).
    public static func own(in repo: URL) -> [String] {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: directory(in: repo), includingPropertiesForKeys: nil))
            ?? []
        return files.filter { VideoProjects.configExtensions.contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    /// Letters, digits, `-` and `_`: the same rule the video suite applies to a theme's file name.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII, CharacterSet.alphanumerics.contains(first) else {
            return false
        }
        return name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0))
        }
    }

    /// The starter file: it extends `base` and lists the values most people change, commented out with the base theme's own values.
    public static func template(name: String, base: BuiltIn) -> String {
        """
        # \(name): your own theme. Use it with `theme: \(name)` in a video, or `kinhin video build <video> --theme \(name)`.
        # It starts from the built-in "\(base.name)" theme (\(base.summary)) and changes only what you write here.
        extends: \(base.name)

        # Uncomment and edit what you want to change. Colors are #rrggbb.
        # colors:
        #   accent: "\(base.accent)"   # highlights, marks and the active step
        #   ink: "\(base.ink)"      # text
        #   paper: "\(base.paper)"    # the page behind the cards
        # font:
        #   family: "\(base.font)"   # put the font file in .kinhin/videos/fonts/ and it is installed for the build
        #   fallback: "Helvetica, Arial, sans-serif"
        # background:
        #   from: "\(base.paper)"
        #   to: "\(base.paper)"
        # device:
        #   terminal: dark        # light or dark: which terminal recording to use
        # caption:
        #   text: "#ffffff"
        #   outline: "#000000"
        # Every other value (the laptop and window look, caption size, the rest of the colors) comes from "\(base.name)".

        """
    }

    /// Writes `<repo>/.kinhin/videos/themes/<name>.yml`. Never overwrites a theme of that name, whatever its extension.
    @discardableResult
    public static func write(name: String, from baseName: String = "paper", in repo: URL) throws -> URL {
        guard isValidName(name) else { throw VideoError.invalidName(name) }
        guard let base = builtIn(named: baseName) else {
            throw VideoError.unknownTheme(name: baseName, available: builtIn.map(\.name))
        }
        let directory = directory(in: repo)
        for ext in VideoProjects.configExtensions {
            let existing = directory.appendingPathComponent(name).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: existing.path) { throw VideoError.alreadyExists(existing.path) }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name).appendingPathExtension("yml")
        try Data(template(name: name, base: base).utf8).write(to: target, options: .withoutOverwriting)
        return target
    }
}
