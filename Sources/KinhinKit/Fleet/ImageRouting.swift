import Foundation

/// Which named `images:` entry serves a job: the one whose labels the job
/// requests in `runs-on`. Jobs matching none run on the main `image:`.
enum ImageRouting {
    /// The entry whose labels are all requested by `jobLabels` (case-insensitive,
    /// as the forges compare them). When several match, the one with the most
    /// labels wins (the most specific), then config order. Entries without
    /// labels are never selected by a job.
    static func image(for jobLabels: [String]?, in images: [KinhinConfig.ImageConfig]) -> KinhinConfig.ImageConfig? {
        guard let jobLabels, !jobLabels.isEmpty else { return nil }
        let requested = Set(jobLabels.map { $0.lowercased() })
        var best: KinhinConfig.ImageConfig?
        for image in images {
            guard let labels = image.labels, !labels.isEmpty else { continue }
            guard Set(labels.map { $0.lowercased() }).isSubset(of: requested) else { continue }
            if best == nil || labels.count > (best?.labels?.count ?? 0) { best = image }
        }
        return best
    }
}
