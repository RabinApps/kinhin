import Foundation

// MARK: - Section validators (base_image, images)

extension ConfigLoader {
    /// `base_image:` is optional; when present it must be usable as a bare
    /// image reference (see `LinuxBaseImage.problem(with:)`).
    static func validatedBaseImage(_ value: String?, key: String) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let problem = LinuxBaseImage.problem(with: trimmed) {
            throw ConfigError.invalid("\(key) \(problem) (an image like ubuntu:24.04 or debian:12)")
        }
        return trimmed
    }

    /// Validates the `images:` list: unique, safe names distinct from `image:`.
    /// Names starting with `kinhin-` or `orchard-` are rejected because fleet
    /// recovery and `kinhin cleanup` treat such VMs as runners and delete them.
    static func parseImages(
        _ entries: [PartialConfig.PartialImage], primary: String, fleetLabels: [String]
    ) throws -> [KinhinConfig.ImageConfig] {
        var seen: Set<String> = [primary]
        var seenLabelSets: Set<Set<String>> = []
        let fleet = Set(fleetLabels.map { $0.lowercased() })
        var result: [KinhinConfig.ImageConfig] = []
        for (index, entry) in entries.enumerated() {
            let position = "images[\(index)]"
            guard let name = entry.name, !name.isEmpty else {
                throw ConfigError.invalid("\(position).name is required")
            }
            guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil else {
                throw ConfigError.invalid(
                    "\(position).name '\(name)' is not valid. Use letters, numbers, '.', '_' or '-', starting with a letter or number"
                )
            }
            guard !InstanceNaming.isOurs(name) else {
                throw ConfigError.invalid(
                    "\(position).name '\(name)' must not start with 'kinhin-' or 'orchard-': those names are reserved for runner VMs"
                )
            }
            guard seen.insert(name).inserted else {
                throw ConfigError.invalid(
                    "\(position).name '\(name)' is already used (image: or another images: entry)")
            }
            if let base = entry.baseImage, let problem = TartBaseImage.problem(with: base) {
                throw ConfigError.invalid("\(position).base_image \(problem)")
            }
            if let labels = entry.labels, labels.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                throw ConfigError.invalid("\(position).labels must not contain empty labels")
            }
            if let base = entry.baseImage, let labels = entry.labels,
                TartBaseImage.isLinux(base), labels.contains(where: { $0.lowercased() == "macos" })
            {
                throw ConfigError.invalid(
                    "\(position).labels must not include 'macos' on a Linux base_image: its "
                        + "runners cannot advertise macOS-only labels, so a job asking for them could never land on it")
            }
            if let labels = entry.labels, !labels.isEmpty {
                let own = Set(labels.map { $0.lowercased() })
                guard !own.isSubset(of: fleet) else {
                    throw ConfigError.invalid(
                        "\(position).labels must include a label that is not already in the fleet labels:, or every job would match this image"
                    )
                }
                guard seenLabelSets.insert(own).inserted else {
                    throw ConfigError.invalid(
                        "\(position).labels duplicate another image's labels, so jobs could not tell them apart")
                }
            }
            let warm = entry.warmPool ?? 0
            if warm < 0 { throw ConfigError.invalid("\(position).warm_pool must be >= 0") }
            let minIdle = entry.minIdle ?? 0
            if minIdle < 0 { throw ConfigError.invalid("\(position).min_idle must be >= 0") }
            result.append(
                .init(name: name, baseImage: entry.baseImage, labels: entry.labels, warmPool: warm, minIdle: minIdle))
        }
        return result
    }

    /// Labels for the default `image:` (`image_labels:`). Same rules as an `images:` entry's
    /// labels: no empty values, at least one label outside the fleet labels (or every job
    /// requesting the fleet labels would match the default image specifically), and no label
    /// set shared with a named `images:` entry (jobs could not tell them apart). A Linux
    /// default base additionally rejects `macos`: its runners never advertise macOS-only
    /// labels, so a job asking for the image's `macos` label could never land on it.
    static func validatedImageLabels(
        _ labels: [String], fleetLabels: [String], images: [KinhinConfig.ImageConfig], linuxBase: Bool
    ) throws -> [String] {
        if labels.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw ConfigError.invalid("image_labels must not contain empty labels")
        }
        if linuxBase, labels.contains(where: { $0.lowercased() == "macos" }) {
            throw ConfigError.invalid(
                "image_labels must not include 'macos' when base_image is a Linux image: its runners "
                    + "cannot advertise macOS-only labels, so a job asking for them could never land on it")
        }
        let own = Set(labels.map { $0.lowercased() })
        let fleet = Set(fleetLabels.map { $0.lowercased() })
        guard !own.isSubset(of: fleet) else {
            throw ConfigError.invalid(
                "image_labels must include a label that is not already in the fleet labels:, or every job would match the default image"
            )
        }
        for image in images {
            guard let imageLabels = image.labels, !imageLabels.isEmpty else { continue }
            if Set(imageLabels.map { $0.lowercased() }) == own {
                throw ConfigError.invalid(
                    "image_labels duplicate the labels of images: \(image.name), so jobs could not tell them apart")
            }
        }
        return labels
    }
}
