import Foundation

/// Append-only log file that rotates by size: when a write would push it past
/// `maxBytes`, `kinhin.log` becomes `kinhin.log.1`, the previous `.1` becomes
/// `.2`, and so on up to `keep` archives (the oldest is dropped). Not
/// thread-safe on its own; `Log` serializes access with its lock.
final class RotatingLogFile {
    static let defaultMaxBytes: UInt64 = 5 * 1024 * 1024
    static let defaultKeep = 3

    private let url: URL
    private let maxBytes: UInt64
    private let keep: Int
    private var handle: FileHandle?
    private var size: UInt64 = 0

    /// Opens (creating if needed) the log at `url`. Throws when the file
    /// cannot be created or opened so the caller can report it.
    init(url: URL, maxBytes: UInt64 = defaultMaxBytes, keep: Int = defaultKeep) throws {
        self.url = url
        self.maxBytes = maxBytes
        self.keep = max(1, keep)
        try open()
    }

    deinit {
        try? handle?.close()  // best-effort at teardown: nothing can act on a failed close
    }

    func append(_ data: Data) throws {
        if size > 0, size + UInt64(data.count) > maxBytes {
            try rotate()
        }
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        try handle.write(contentsOf: data)
        size += UInt64(data.count)
    }

    private func open() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        // A log left world-readable by an older build gets tightened on open.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let opened = try FileHandle(forWritingTo: url)
        size = try opened.seekToEnd()
        handle = opened
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let fm = FileManager.default
        func archive(_ index: Int) -> URL { URL(fileURLWithPath: url.path + ".\(index)") }
        // Drop the oldest, then shift .n-1 -> .n ... .1 -> .2, then live -> .1.
        if fm.fileExists(atPath: archive(keep).path) { try fm.removeItem(at: archive(keep)) }
        if keep > 1 {
            for index in stride(from: keep - 1, through: 1, by: -1) where fm.fileExists(atPath: archive(index).path) {
                try fm.moveItem(at: archive(index), to: archive(index + 1))
            }
        }
        try fm.moveItem(at: url, to: archive(1))
        try open()
    }
}
