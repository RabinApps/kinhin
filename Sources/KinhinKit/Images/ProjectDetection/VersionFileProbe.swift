import Foundation

/// Explicit version pins: `.tool-versions`, `mise.toml` and the per-language
/// `.xxx-version` files. These win over every other source.
struct VersionFileProbe: ToolchainProbe {
    let name = "version files"

    /// Ecosystem names that differ from the catalog id.
    static let aliases: [String: String] = ["nodejs": "node", "golang": "go", "tofu": "opentofu"]

    private static let singleFiles: [(file: String, tool: String)] = [
        (".nvmrc", "node"), (".node-version", "node"), (".python-version", "python"),
        (".ruby-version", "ruby"), (".go-version", "go"), (".java-version", "java"),
    ]

    func hits(in reader: ProjectFileReading) throws -> [ToolchainHit] {
        var out: [ToolchainHit] = []
        for (file, tool) in Self.singleFiles {
            guard let text = try reader.text(file) else { continue }
            let version = text.split(whereSeparator: \.isNewline).first.map { String($0).trimmed() }
            out.append(hit(tool, version, file))
        }
        if let text = try reader.text(".tool-versions") {
            for line in text.split(whereSeparator: \.isNewline) {
                let line = String(line).strippingComment()
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count >= 1, !parts[0].isEmpty else { continue }
                out.append(hit(parts[0], parts.count > 1 ? parts[1] : nil, ".tool-versions"))
            }
        }
        for file in ["mise.toml", ".mise.toml"] {
            guard let text = try reader.text(file) else { continue }
            out.append(contentsOf: Self.miseTools(text).map { hit($0.0, $0.1, file) })
        }
        return out
    }

    private func hit(_ tool: String, _ version: String?, _ file: String) -> ToolchainHit {
        let id = Self.aliases[tool] ?? tool
        return ToolchainHit(
            id, version: version, source: file,
            reason: version.map { "\(file) pins \(tool) \($0)" } ?? "\(file) lists \(tool)", precedence: .versionFile)
    }

    /// `[tools]` entries: `node = "22"`, `node = ["22", "20"]`, `go = { version = "1.22" }`.
    static func miseTools(_ text: String) -> [(String, String?)] {
        var inTools = false
        var out: [(String, String?)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).strippingComment()
            if line.hasPrefix("[") {
                inTools = line == "[tools]"
                continue
            }
            guard inTools, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmed().trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !key.isEmpty else { continue }
            let value = String(line[line.index(after: eq)...])
            out.append((key, firstQuoted(in: value, after: value.contains("version") ? "version" : nil)))
        }
        return out
    }

    /// The first quoted string in `value`, optionally only after `marker`.
    private static func firstQuoted(in value: String, after marker: String?) -> String? {
        var text = Substring(value)
        if let marker, let range = text.range(of: marker) { text = text[range.upperBound...] }
        guard let open = text.firstIndex(where: { $0 == "\"" || $0 == "'" }) else {
            let bare = text.trimmed()
            return bare.isEmpty || bare.hasPrefix("{") || bare.hasPrefix("[") ? nil : bare
        }
        let quote = text[open]
        let rest = text[text.index(after: open)...]
        guard let close = rest.firstIndex(of: quote) else { return nil }
        return String(rest[..<close])
    }
}

extension StringProtocol {
    func trimmed() -> String { trimmingCharacters(in: .whitespaces) }

    /// Drops a trailing `# comment`.
    func strippingComment() -> String {
        guard let hash = firstIndex(of: "#") else { return trimmed() }
        return self[..<hash].trimmed()
    }
}
