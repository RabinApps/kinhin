import Foundation

/// The tracks that ship in the video image (`video/music/catalog.json`), searched offline. A built-in track is selected by
/// name (`music: first-light-particles`) and needs no download. A test keeps this list equal to the catalog file.
public enum BuiltInMusic {
    public static let tracks: [MusicTrack] = [
        MusicTrack(
            origin: .builtIn, id: "first-light-particles", title: "First Light Particles", creator: "Yoiyami",
            license: "cc0", licenseVersion: "1.0", licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/",
            source: "opengameart", landingURL: "https://opengameart.org/node/182244", fileType: "wav",
            summary: "calm atmospheric piano and pads, no percussion")
    ]

    public static func named(_ name: String) -> MusicTrack? {
        tracks.first { $0.id == name.lowercased() }
    }

    /// Built-in tracks whose title, creator or description contain every word of `query`.
    public static func matching(_ query: String) -> [MusicTrack] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return [] }
        return tracks.filter { track in
            let haystack = [track.title, track.creator ?? "", track.summary ?? "", track.id].joined(separator: " ")
                .lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}
