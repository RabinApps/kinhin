import Foundation
import KinhinKit

/// The container pool sheet's fields as typed, and the `container.pools:` entry they make. A blank field leaves its
/// key out, so the pool inherits the `container:` section's value; keys the sheet does not show (`fleet_labels`)
/// are carried over from the pool being edited.
struct ContainerPoolDraft: Equatable {
    typealias Pool = ContainerPoolsConfigEditor.Pool

    /// Docker inside the pool's runners: the section's setting, or on or off for this pool alone.
    enum DockerChoice: Hashable {
        case inherit, on, off
    }

    var name = ""
    /// Comma- or space-separated.
    var labels = ""
    var cpus = ""
    var memoryGB = ""
    var max = ""
    var minIdle = ""
    var docker = DockerChoice.inherit
    var image = ""
    var baseImage = ""
    /// Extra `container run` arguments, one per line (so an argument may hold spaces).
    var flags = ""

    init() {}

    /// The fields for a pool as written.
    init(pool: Pool) {
        name = pool.name
        labels = (pool.labels ?? []).joined(separator: ", ")
        cpus = pool.cpus.map(String.init) ?? ""
        memoryGB = pool.memoryGB.map(String.init) ?? ""
        max = pool.max.map(String.init) ?? ""
        minIdle = pool.minIdle.map(String.init) ?? ""
        switch pool.docker {
        case true?: docker = .on
        case false?: docker = .off
        case nil: docker = .inherit
        }
        image = pool.image ?? ""
        baseImage = pool.baseImage ?? ""
        flags = (pool.flags ?? []).joined(separator: "\n")
    }

    // MARK: - Checking

    /// What is wrong with the fields, first problem first; nil when they can be saved. The loader checks the rest
    /// when the pool is written (labels another pool already has, `max` below `min_idle`, flags kinhin sets itself).
    var problem: String? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty {
            return String(localized: "Enter a pool name.", bundle: .l10n, comment: "Container pool sheet validation")
        }
        if !KinhinConfig.ContainerConfig.Pool.isValidName(trimmedName) {
            return String(
                localized:
                    "A pool name is lowercase letters, digits and inner hyphens, up to 32 characters (it becomes part of a runner label).",
                bundle: .l10n, comment: "Container pool sheet validation")
        }
        if !Self.isNumber(cpus, atLeast: 1) {
            return String(
                localized: "CPUs must be a whole number, 1 or more.", bundle: .l10n,
                comment: "Container pool sheet validation")
        }
        if !Self.isNumber(memoryGB, atLeast: 1) {
            return String(
                localized: "Memory must be a whole number of GB, 1 or more.", bundle: .l10n,
                comment: "Container pool sheet validation")
        }
        if !Self.isNumber(max, atLeast: 1) {
            return String(
                localized: "Max runners must be a whole number, 1 or more.", bundle: .l10n,
                comment: "Container pool sheet validation")
        }
        if !Self.isNumber(minIdle, atLeast: 0) {
            return String(
                localized: "Idle runners must be a whole number, 0 or more.", bundle: .l10n,
                comment: "Container pool sheet validation")
        }
        return nil
    }

    /// Blank, or a whole number of at least `minimum`.
    private static func isNumber(_ text: String, atLeast minimum: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        guard let value = Int(trimmed) else { return false }
        return value >= minimum
    }

    // MARK: - The entry

    /// The entry to write (check `problem` first: a field that is not a number is left out). `original` is the pool
    /// being edited, whose `fleet_labels` the sheet does not show and so keeps.
    func pool(keeping original: Pool?) -> Pool {
        func text(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        func number(_ value: String) -> Int? { text(value).flatMap { Int($0) } }
        let labelList = labels.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        let flagList = flags.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let dockerValue: Bool?
        switch docker {
        case .inherit: dockerValue = nil
        case .on: dockerValue = true
        case .off: dockerValue = false
        }
        return Pool(
            name: name.trimmingCharacters(in: .whitespaces), image: text(image), baseImage: text(baseImage),
            cpus: number(cpus), memoryGB: number(memoryGB), labels: labelList.isEmpty ? nil : labelList,
            fleetLabels: original?.fleetLabels, minIdle: number(minIdle), docker: dockerValue,
            flags: flagList.isEmpty ? nil : flagList, max: number(max))
    }
}
