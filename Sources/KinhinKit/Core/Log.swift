import Foundation
import Synchronization
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
        /// Monotonic per-process sequence number: a consumer that has seen
        /// entry N only needs the entries after it. 0 when decoded from a
        /// sender that predates the field.
        public let seq: UInt64

        init(timestamp: Date, level: String, component: String, message: String, seq: UInt64 = 0) {
            self.timestamp = timestamp
            self.level = level
            self.component = component
            self.message = message
            self.seq = seq
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            timestamp = try container.decode(Date.self, forKey: .timestamp)
            level = try container.decode(String.self, forKey: .level)
            component = try container.decode(String.self, forKey: .component)
            message = try container.decode(String.self, forKey: .message)
            seq = try container.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
        }

        private static let nextSeq = Atomic<UInt64>(1)

        static func make(level: String, component: String, message: String) -> Entry {
            let seq = nextSeq.add(1, ordering: .relaxed).oldValue
            return Entry(timestamp: Date(), level: level, component: component, message: message, seq: seq)
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

    public enum Level: String, Comparable, CaseIterable, Codable, Sendable {
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

    private static let _minLevel = Mutex(Level.info)
    public static var minLevel: Level {
        get { _minLevel.withLock { $0 } }
        set { _minLevel.withLock { level in level = newValue } }
    }
    private static let _echoToStderr = Mutex(true)
    static var echoToStderr: Bool {
        get { _echoToStderr.withLock { $0 } }
        set { _echoToStderr.withLock { flag in flag = newValue } }
    }

    /// In-memory ring buffer of recent entries (also mirrored to disk).
    private static let ring = Runaround<Entry>(capacity: 5000)
    /// The log-file target plus its failure state, guarded by one mutex.
    private static let fileTarget = Mutex(FileTarget())

    private struct FileTarget {
        var file: RotatingLogFile?
        /// Set once a write to the log file has failed, so a full disk or revoked
        /// permission is reported to stderr a single time instead of every line.
        var reportedFailure = false
    }

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

    /// Masks tokens and credentials in arbitrary text (support bundles, copied reports).
    public static func redact(_ text: String) -> String {
        LogRedactor.redact(text)
    }

    public static func error(_ component: String, _ message: String) {
        emit(.error, component, message)
    }

    /// Configure file logging under the given directory (created if missing).
    /// The file rotates by size (see `RotatingLogFile`). A failure to create
    /// the directory or open the file is reported on stderr and file logging
    /// stays off; it never crashes the caller.
    public static func setLogFile(directory: URL) {
        fileTarget.withLock { target in
            guard target.file == nil else { return }
            do {
                try Paths.createPrivateDirectory(directory)
                target.file = try RotatingLogFile(url: directory.appendingPathComponent("kinhin.log"))
                target.reportedFailure = false
            } catch {
                reportFileFailure(
                    "could not open log file in \(directory.path): \(error.localizedDescription)", to: &target)
            }
        }
    }

    /// Mutates `target` (the caller holds the mutex): reports a file-logging
    /// failure on stderr once instead of on every line.
    private static func reportFileFailure(_ message: String, to target: inout FileTarget) {
        guard !target.reportedFailure else { return }
        target.reportedFailure = true
        FileHandle.standardError.write(Data("kinhin: \(message); continuing without file logging\n".utf8))
    }

    private static func emit(_ level: Level, _ component: String, _ message: String) {
        guard level >= minLevel else { return }
        let entry = Entry.make(level: level.rawValue, component: component, message: LogRedactor.redact(message))

        // Formatted once: the timestamp formatting is the costly part.
        let line = Data(entry.formatted.appending("\n").utf8)
        if echoToStderr {
            FileHandle.standardError.write(line)
        }

        ring.append(entry)

        fileTarget.withLock { target in
            guard let logFile = target.file else { return }
            do {
                try logFile.append(line)
            } catch {
                reportFileFailure("log file write failed: \(error.localizedDescription)", to: &target)
            }
        }
    }
}

/// A thread-safe fixed-capacity ring buffer: appends overwrite the oldest
/// item in O(1).
final class Runaround<T: Sendable>: Sendable {
    private struct State: Sendable {
        var items: [T] = []
        /// Index of the oldest item once the buffer is full.
        var head = 0
        let capacity: Int
    }

    private let state: Mutex<State>

    init(capacity: Int) {
        self.state = Mutex(State(capacity: max(1, capacity)))
    }

    func append(_ item: T) {
        state.withLock { s in
            if s.items.count < s.capacity {
                s.items.append(item)
            } else {
                s.items[s.head] = item
                s.head = (s.head + 1) % s.capacity
            }
        }
    }

    /// The newest `limit` items, oldest first.
    func snapshot(limit: Int) -> [T] {
        state.withLock { s in
            let count = s.items.count
            let take = max(0, min(limit, count))
            guard take > 0 else { return [] }
            let start = s.head + (count - take)
            return (0..<take).map { s.items[(start + $0) % count] }
        }
    }
}
