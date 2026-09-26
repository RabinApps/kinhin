import Foundation
import os

/// Central logging for kinhin. Writes structured lines to stderr and to a
/// rotating file under the kinhin support directory so `kinhin logs` and the
/// menu bar app can show recent activity.
public enum Log {
    /// One log line.
    public struct Entry: Codable, Sendable, Equatable {
        let timestamp: Date
        public let level: String
        public let component: String
        public let message: String

        static func make(level: String, component: String, message: String) -> Entry {
            Entry(timestamp: Date(), level: level, component: component, message: message)
        }

        public var formatted: String {
            let ts = Self.formatter.string(from: timestamp)
            return "\(ts) [\(level)] [\(component)] \(message)"
        }

        static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f
        }()
    }

    public enum Level: String, Comparable, CaseIterable, Codable {
        case debug, info, warn, error

        var weight: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warn: return 2
            case .error: return 3
            }
        }

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.weight < rhs.weight
        }
    }

    public static var minLevel: Level = .info
    static var echoToStderr = true

    /// In-memory ring buffer of recent entries (also mirrored to disk).
    private static let ring = Runaround<Entry>(capacity: 5000)
    private static let lock = NSLock()
    private static var logFile: RotatingLogFile?
    /// Set once a write to the log file has failed, so a full disk or revoked
    /// permission is reported to stderr a single time instead of every line.
    private static var reportedFileFailure = false

    public static func snapshot(limit: Int = 200) -> [Entry] {
        ring.snapshot(limit: limit)
    }

    public static func debug(_ component: String, _ message: String) {
        emit(.debug, component, message)
    }

    public static func info(_ component: String, _ message: String) {
        emit(.info, component, message)
    }

    public static func warn(_ component: String, _ message: String) {
        emit(.warn, component, message)
    }

    public static func error(_ component: String, _ message: String) {
        emit(.error, component, message)
    }

    /// Configure file logging under the given directory (created if missing).
    /// The file rotates by size (see `RotatingLogFile`). A failure to create
    /// the directory or open the file is reported on stderr and file logging
    /// stays off; it never crashes the caller.
    public static func setLogFile(directory: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard logFile == nil else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            logFile = try RotatingLogFile(url: directory.appendingPathComponent("kinhin.log"))
            reportedFileFailure = false
        } catch {
            reportFileFailure("could not open log file in \(directory.path): \(error.localizedDescription)")
        }
    }

    /// Caller must hold `lock`.
    private static func reportFileFailure(_ message: String) {
        guard !reportedFileFailure else { return }
        reportedFileFailure = true
        FileHandle.standardError.write(Data("kinhin: \(message); continuing without file logging\n".utf8))
    }

    private static func emit(_ level: Level, _ component: String, _ message: String) {
        guard level >= minLevel else { return }
        let entry = Entry.make(level: level.rawValue, component: component, message: LogRedactor.redact(message))

        if echoToStderr {
            FileHandle.standardError.write(Data(entry.formatted.appending("\n").utf8))
        }

        let entryToStore = entry
        ring.append(entryToStore)

        lock.lock()
        defer { lock.unlock() }
        if let logFile {
            do {
                try logFile.append(Data(entryToStore.formatted.appending("\n").utf8))
            } catch {
                reportFileFailure("log file write failed: \(error.localizedDescription)")
            }
        }
    }
}

/// A tiny thread-safe ring buffer.
final class Runaround<T> {
    private var items: [T] = []
    private let capacity: Int
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
    }

    func append(_ item: T) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
        if items.count > capacity {
            items.removeFirst(items.count - capacity)
        }
    }

    func snapshot(limit: Int) -> [T] {
        lock.lock()
        defer { lock.unlock() }
        return Array(items.suffix(limit))
    }
}
