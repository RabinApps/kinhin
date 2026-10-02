import Foundation

/// Read-only view of a project checkout, so probes can run against a temp
/// directory or an in-memory fake.
protocol ProjectFileReading: Sendable {
    /// The file's bytes, or nil when it is missing, a symlink or over the size cap.
    func read(_ path: String) throws -> Data?
    /// Entry names directly inside `directory` ("" is the root); empty when missing.
    func list(_ directory: String) throws -> [String]
}

extension ProjectFileReading {
    func exists(_ path: String) -> Bool {
        (try? read(path)) != nil
    }

    func text(_ path: String) throws -> String? {
        try read(path).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Root entries ending in one of `suffixes`, case-sensitively.
    func rootFiles(withSuffix suffixes: String...) throws -> [String] {
        try list("").filter { name in suffixes.contains { name.hasSuffix($0) } }
    }
}

struct FileSystemProjectReader: ProjectFileReading {
    /// Manifests are small; anything bigger is not worth parsing.
    static let maxFileBytes = 2 * 1024 * 1024

    let root: URL

    func read(_ path: String) throws -> Data? {
        let url = root.appendingPathComponent(path)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true,
            (values?.fileSize ?? 0) <= Self.maxFileBytes
        else { return nil }
        return try Data(contentsOf: url)
    }

    func list(_ directory: String) throws -> [String] {
        let url = directory.isEmpty ? root : root.appendingPathComponent(directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
}
