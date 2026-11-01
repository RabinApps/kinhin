import Foundation

// MARK: - Extra `container run` flags (container.flags)

extension ConfigLoader {
    /// A `container run` option kinhin passes itself (or one that would keep `container run` from starting a runner
    /// container), in every spelling Apple container accepts, with why a user flag may not set it.
    struct ManagedRunFlag: Sendable {
        let spellings: [String]
        let reason: String
    }

    /// The options `container.flags` may not set. Spellings are Apple container 1.6.1's (`container run --help`).
    static let managedContainerRunFlags: [ManagedRunFlag] = [
        .init(spellings: ["--name"], reason: "kinhin names each runner container"),
        .init(spellings: ["--rm", "--remove"], reason: "kinhin already removes each runner container when it stops"),
        .init(spellings: ["--detach", "-d"], reason: "kinhin already starts each runner container detached"),
        .init(spellings: ["--cpus", "-c"], reason: "kinhin sets it from cpus"),
        .init(spellings: ["--memory", "-m"], reason: "kinhin sets it from memory_gb"),
        .init(spellings: ["--platform"], reason: "Apple container runs linux/arm64 only"),
        .init(spellings: ["--arch", "-a"], reason: "Apple container runs linux/arm64 only"),
        .init(spellings: ["--os"], reason: "Apple container runs linux/arm64 only"),
        .init(spellings: ["--help", "-h", "--version"], reason: "container run would print it and start nothing"),
        .init(spellings: ["--"], reason: "it would turn kinhin's own arguments into the container's command"),
    ]

    /// `flags` (the list at `key`, e.g. `container.flags`) checked and returned; nil reads as none. Every element is
    /// one argv element, never seen by a shell, so nothing needs quoting. Rejected: empty elements, control characters
    /// (the config editors write each element back as one quoted YAML scalar), a first element that is not an option
    /// (a stray value would be read as the image), and any option in `managedContainerRunFlags` in any spelling:
    /// `--cpus 2`, `--cpus=2`, `-c 2`, `-c2`, or grouped with other short flags (`-dt`).
    static func validatedContainerRunFlags(_ flags: [String]?, key: String) throws -> [String] {
        guard let flags else { return [] }
        if let empty = flags.firstIndex(where: \.isEmpty) {
            throw ConfigError.invalid("\(key)[\(empty)] must not be empty")
        }
        if let index = flags.firstIndex(where: {
            $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }) {
            throw ConfigError.invalid("\(key)[\(index)] must not contain control characters (newlines, tabs)")
        }
        if let first = flags.first, !first.hasPrefix("-") {
            throw ConfigError.invalid(
                "\(key) must start with an option such as \"--shm-size\", not \"\(first)\" "
                    + "(give each flag and each value as its own list element)")
        }
        for flag in flags {
            if let managed = managedContainerRunFlag(in: flag) {
                throw ConfigError.invalid("\(key) must not set \(managed.spelling): \(managed.reason)")
            }
        }
        return flags
    }

    /// The managed option `argument` sets, as spelled there, and why it is managed; nil for any other option or a
    /// value. A short option counts anywhere in a leading run of letters, since `-dt` is `-d -t` and `-c2` is `-c 2`.
    static func managedContainerRunFlag(in argument: String) -> (spelling: String, reason: String)? {
        func managed(_ spelling: String) -> (spelling: String, reason: String)? {
            managedContainerRunFlags.first { $0.spellings.contains(spelling) }.map { (spelling, $0.reason) }
        }
        if argument.hasPrefix("--") {
            let name = argument.prefix { $0 != "=" }
            return managed(String(name))
        }
        guard argument.hasPrefix("-") else { return nil }
        for letter in argument.dropFirst().prefix(while: \.isLetter) {
            if let found = managed("-\(letter)") { return found }
        }
        return nil
    }
}
