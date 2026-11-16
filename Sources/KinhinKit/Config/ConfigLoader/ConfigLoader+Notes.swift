import Foundation

// MARK: - Notes on a valid config

extension ConfigLoader {
    /// Things a valid config does that its author may not have meant, for `kinhin config validate` to print beside
    /// its OK line. Never an error: the config loads as it is. Empty when the YAML does not decode (the loader's own
    /// error says why).
    public static func notes(forYAML yaml: String) -> [String] {
        guard let partial = try? decode(yaml) else { return [] }  // not decodable: parse() reports the real error
        var notes: [String] = []
        if partial.image == nil {
            notes.append(Self.defaultImageNote)
        }
        return notes
    }

    /// `notes(forYAML:)` for the file at `url`; empty when it cannot be read.
    public static func notes(at url: URL) -> [String] {
        guard let yaml = try? String(contentsOf: url, encoding: .utf8) else { return [] }  // load() reports it
        return notes(forYAML: yaml)
    }

    /// `image:` left out: macOS runners clone the default image, which the file never names.
    static var defaultImageNote: String {
        "image: is not set, so macOS runners use the default image '\(KinhinConfig.default.image)'; "
            + "set image: to name the image you prepared"
    }
}
