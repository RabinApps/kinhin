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
            guard !name.hasPrefix("kinhin-"), !name.hasPrefix("orchard-") else {
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
            result.append(.init(name: name, baseImage: entry.baseImage, labels: entry.labels))
        }
        return result
    }
}
