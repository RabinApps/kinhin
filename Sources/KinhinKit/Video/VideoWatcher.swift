import Foundation

/// Notices when a video's files change, for `kinhin video build --watch`: a snapshot of the modification times under
/// `.kinhin/videos/` and the wait for the next change. What a build writes (`out/`, the hidden `.cache/`) is left out,
/// or every build would start the next one.
public enum VideoWatcher {
    /// Folders of `.kinhin/videos/` that a build writes.
    static let ignored: Set<String> = ["out"]

    /// The modification time of every file under `directory`, by path relative to it. A missing folder is an empty snapshot.
    public static func snapshot(of directory: URL) -> [String: Date] {
        guard
            let files = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [:] }
        let base = directory.standardizedFileURL.path
        var result: [String: Date] = [:]
        for case let url as URL in files {
            // A file that cannot be read just does not count: the next poll looks again, and a build never depends on it.
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if values?.isDirectory == true {
                if ignored.contains(relative) { files.skipDescendants() }
            } else if let date = values?.contentModificationDate {
                result[relative] = date
            }
        }
        return result
    }

    /// The paths that were added, removed or modified between two snapshots, sorted.
    public static func changes(from old: [String: Date], to new: [String: Date]) -> [String] {
        Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.sorted()
    }

    /// Waits until something under `directory` differs from `since`, then until the files have been still for `settle` (an editor
    /// saves in bursts), and returns the new snapshot with the paths that changed. Throws `CancellationError` when cancelled.
    public static func waitForChange(
        in directory: URL, since: [String: Date], poll: Duration = .seconds(1), settle: Duration = .milliseconds(500)
    ) async throws -> (snapshot: [String: Date], changed: [String]) {
        var current = since
        while changes(from: since, to: current).isEmpty {
            try await Task.sleep(for: poll)
            current = snapshot(of: directory)
        }
        while true {
            try await Task.sleep(for: settle)
            let latest = snapshot(of: directory)
            if changes(from: current, to: latest).isEmpty { break }
            current = latest
        }
        return (current, changes(from: since, to: current))
    }
}
