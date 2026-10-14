import Foundation

/// Reads kinhin's own JSON state files (fleet records, project images, scale-set
/// sessions). A missing file is simply "no state". A file that exists but can't
/// be read or decoded is moved aside to `<name>.corrupt-<UTC timestamp>` in the
/// same directory before the caller starts empty, so the next save cannot
/// overwrite the evidence, and the loss is logged as an error naming the copy.
enum StateFile {
    enum Load<Value> {
        /// No file: nothing was ever saved (or it was cleared).
        case missing
        case loaded(Value)
        /// The file was unreadable. `keptAt` is where its bytes are now: the
        /// quarantined copy, or the original path when the move failed.
        case corrupt(keptAt: URL)
    }

    static func load<Value>(
        _ file: URL, component: String, now: Date = Date(), decode: (Data) throws -> Value
    ) -> Load<Value> {
        guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
        let failure: Error
        do {
            return .loaded(try decode(Data(contentsOf: file)))
        } catch {
            failure = error
        }
        let kept = quarantine(file, component: component, now: now) ?? file
        Log.error(
            component,
            "could not read \(file.path) (\(failure.localizedDescription)); starting empty, unreadable copy kept at \(kept.path)"
        )
        return .corrupt(keptAt: kept)
    }

    /// Moves `file` to a free `<name>.corrupt-<timestamp>` sibling; nil (and a
    /// logged warning) when the move fails.
    static func quarantine(_ file: URL, component: String, now: Date = Date()) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let base = "\(file.lastPathComponent).corrupt-\(formatter.string(from: now))"
        let directory = file.deletingLastPathComponent()
        var target = directory.appendingPathComponent(base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }
        var moved: URL?
        bestEffort(component, "moving unreadable \(file.path) aside") {
            try FileManager.default.moveItem(at: file, to: target)
            moved = target
        }
        return moved
    }
}
