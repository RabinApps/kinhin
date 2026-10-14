import Foundation
import Yams

/// The set of keys `config.yaml` accepts, section by section, so a typo such
/// as `max_runner:` is reported instead of silently ignored (Yams drops keys
/// the typed decode does not know). The key lists come from the `Partial*`
/// types' `CodingKeys`, the same enums the loader decodes with, so a key
/// cannot be accepted by one and unknown to the other.
struct ConfigSchema {
    /// What lives under a key.
    indirect enum Child {
        /// A mapping with its own known keys.
        case object(ConfigSchema)
        /// A list of mappings that each follow the schema.
        case list(ConfigSchema)
    }

    /// Keys valid at this level.
    let keys: [String]
    let children: [String: Child]

    init<K: CaseIterable & RawRepresentable>(_ keys: K.Type, _ children: [String: Child] = [:])
    where K.RawValue == String {
        self.keys = K.allCases.map(\.rawValue)
        self.children = children
    }

    /// The whole `config.yaml` document.
    static let root = ConfigSchema(
        PartialConfig.CodingKeys.self,
        [
            "vm": .object(.init(PartialConfig.PartialVM.CodingKeys.self)),
            "reserve": .object(.init(PartialConfig.PartialReserve.CodingKeys.self)),
            "healing": .object(.init(PartialConfig.PartialHealing.CodingKeys.self)),
            "container": .object(.init(PartialConfig.PartialContainer.CodingKeys.self)),
            "docker": .object(.init(PartialConfig.PartialDocker.CodingKeys.self)),
            "toolchain_cache": .object(.init(PartialConfig.PartialCachePolicy.CodingKeys.self)),
            "runtimes": .object(
                .init(
                    PartialConfig.PartialRuntimes.CodingKeys.self,
                    // `budget:` maps runtime names to weights; those names are validated by the loader.
                    ["routes": .list(.init(PartialConfig.PartialRoute.CodingKeys.self))])),
            "images": .list(.init(PartialConfig.PartialImage.CodingKeys.self)),
            "accounts": .list(
                .init(
                    PartialConfig.PartialAccount.CodingKeys.self,
                    ["scale_set": .object(.init(ConfigLoader.PartialScaleSet.CodingKeys.self))])),
            "projects": .list(
                .init(
                    PartialConfig.PartialProject.CodingKeys.self,
                    ["toolchains": .object(.init(PartialConfig.PartialToolchains.CodingKeys.self))])),
        ])

    /// One key the schema does not know.
    struct UnknownKey: Equatable {
        /// Dotted path to the key, list items indexed: `accounts[0].scop`.
        let path: String
        /// The suggested replacement's path, when one is close.
        let suggestion: String?
        /// The keys valid at that level, for the message when nothing is close.
        let known: [String]

        var message: String {
            if let suggestion { return "unknown key '\(path)' — did you mean '\(suggestion)'?" }
            return "unknown key '\(path)'"
        }
    }

    /// Top-level keys starting with this are reserved for the user (YAML
    /// anchors for reuse, notes) and never reported.
    static let userPrefix = "x-"

    /// Every key in `yaml` the schema does not know, in document order.
    /// Throws `ConfigError` when the text is not YAML.
    static func unknownKeys(in yaml: String) throws -> [UnknownKey] {
        let node: Node?
        do {
            node = try Yams.compose(yaml: yaml)
        } catch {
            throw ConfigError.invalid("not valid YAML — \(error)")
        }
        guard let node else { return [] }
        var found: [UnknownKey] = []
        root.collect(node, path: "", isRoot: true, into: &found)
        return found
    }

    private func collect(_ node: Node, path: String, isRoot: Bool, into found: inout [UnknownKey]) {
        guard let mapping = node.mapping else { return }
        for (keyNode, value) in mapping {
            guard let key = keyNode.string, key != "<<" else { continue }
            let full = path.isEmpty ? key : "\(path).\(key)"
            guard keys.contains(key) else {
                if isRoot && key.hasPrefix(Self.userPrefix) { continue }
                let near = ConfigSuggestion.closest(to: key, in: keys)
                found.append(
                    UnknownKey(path: full, suggestion: near.map { path.isEmpty ? $0 : "\(path).\($0)" }, known: keys))
                continue
            }
            switch children[key] {
            case .object(let schema):
                schema.collect(value, path: full, isRoot: false, into: &found)
            case .list(let schema):
                guard let items = value.sequence else { continue }
                for (index, item) in items.enumerated() {
                    schema.collect(item, path: "\(full)[\(index)]", isRoot: false, into: &found)
                }
            case nil:
                break
            }
        }
    }
}
