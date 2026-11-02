import Foundation

/// How a configured OCI image reference (an Apple container pool's or the Docker image) relates to a local image name.
extension ImageInventory {
    /// The `name:tag` form a configured image reference can match (`x` also
    /// matches `x:latest` and every tag of `x`).
    static func ociMatches(name: String, wanted: String) -> Bool {
        name == wanted || name.hasPrefix("\(wanted):")
    }

    /// The one tag runner containers actually start from: the name itself, or
    /// `:latest` when the config carries no tag or digest.
    static func ociUses(name: String, wanted: String) -> Bool {
        if name == wanted { return true }
        return !ociHasTagOrDigest(wanted) && name == "\(wanted):latest"
    }

    /// The tag a runner started from `reference` runs: the reference itself, or `:latest` when it names neither a tag
    /// nor a digest. `runner` and `runner:latest` are one image to `container run` and to a bake.
    static func ociRunnableReference(_ reference: String) -> String {
        ociHasTagOrDigest(reference) ? reference : "\(reference):latest"
    }

    /// Whether a reference names a tag or digest. A `:` before the last `/` is
    /// a registry port (`localhost:5000/runner` has no tag), so only the last
    /// path component is looked at.
    static func ociHasTagOrDigest(_ reference: String) -> Bool {
        if reference.contains("@") { return true }
        let lastComponent = reference.split(separator: "/").last ?? Substring(reference)
        return lastComponent.contains(":")
    }
}
