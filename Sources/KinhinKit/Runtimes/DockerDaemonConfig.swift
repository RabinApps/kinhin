import Foundation

/// A runner image's `/etc/docker/daemon.json` with the Docker Hub cache merged in. Pure, so the merge is testable
/// without a container.
enum DockerDaemonConfig {
    /// The merged file, or why the image's file could not be merged (it is then left as it is).
    enum Merge: Equatable {
        case merged(String)
        case invalid(String)
    }

    /// `text` (the image's daemon.json; empty when it has none) with `registry-mirrors` set to `[mirror]`. Every other
    /// key is kept as it is. Any mirror the image already lists is replaced, not kept beside it: a stale entry (the
    /// GitHub ubuntu image ships one for an address that no longer exists) would make dockerd try a dead mirror before
    /// each pull. Keys come out sorted and pretty-printed, slashes unescaped.
    static func merging(mirror: String, into text: String) -> Merge {
        var settings: [String: Any] = [:]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let parsed: Any
            do {
                parsed = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
            } catch {
                return .invalid("it is not valid JSON (\(Self.reason(error)))")
            }
            guard let object = parsed as? [String: Any] else { return .invalid("its top level is not a JSON object") }
            settings = object
        }
        settings["registry-mirrors"] = [mirror]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return .merged(String(decoding: data, as: UTF8.self))
        } catch {
            return .invalid("it could not be written back (\(Self.reason(error)))")
        }
    }

    /// Foundation's JSON errors carry the useful part (where it broke) in their debug description.
    private static func reason(_ error: any Error) -> String {
        (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
    }
}
