import Foundation

/// A repository's video configs: one file per video in `<repo>/.kinhin/videos/`
/// (YAML or JSON, subfolders allowed). This mirrors how the video suite finds
/// them (`projectFile` in `video/scripts/project.mjs`), so what `list` shows is
/// what `build` can build.
public enum VideoProjects {
    public static let folder = ".kinhin/videos"
    public static let configExtensions = ["yml", "yaml", "json"]

    /// Folders inside `.kinhin/videos/` that hold something other than configs.
    private static let nonProjectFolders: Set<String> = ["adapters", "out", ".cache", "fonts"]

    public static func directory(in repo: URL) -> URL {
        repo.appendingPathComponent(folder, isDirectory: true)
    }

    /// The project names in `repo`, sorted ("launch", "social/vertical").
    public static func list(in repo: URL) -> [String] {
        let root = directory(in: repo)
        var names: [String] = []
        func walk(_ dir: URL, prefix: String) {
            let entries =
                (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]))
                ?? []
            for entry in entries {
                let name = entry.lastPathComponent
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory {
                    if prefix.isEmpty && nonProjectFolders.contains(name) { continue }
                    walk(entry, prefix: prefix + name + "/")
                } else if configExtensions.contains(entry.pathExtension.lowercased()) {
                    names.append(prefix + entry.deletingPathExtension().lastPathComponent)
                }
            }
        }
        walk(root, prefix: "")
        return names.sorted()
    }

    /// Whether `name` is a plain relative project name (no absolute path, no `..`).
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasSuffix("/") else { return false }
        return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    /// The config file for `name`, or nil when there is none.
    public static func file(named name: String, in repo: URL) -> URL? {
        guard isValidName(name) else { return nil }
        let base = directory(in: repo).appendingPathComponent(name)
        for ext in configExtensions {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
