import Foundation

/// Which container CLI a `ContainerManager` drives.
public enum ContainerTool: String, CaseIterable, Sendable {
    case docker
    case appleContainer

    public var title: String {
        switch self {
        case .docker: return "Docker"
        case .appleContainer: return "Apple container"
        }
    }

    /// Executable name looked up on PATH / known install locations.
    public var binaryName: String {
        switch self {
        case .docker: return "docker"
        case .appleContainer: return "container"
        }
    }

    public var isInstalled: Bool { Paths.findExecutable(named: binaryName) != nil }
}

public struct ManagedContainer: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let image: String
    /// Lowercased lifecycle state ("running", "exited", "stopped", "created"…).
    public let state: String
    /// Human status text where the tool provides one ("Up 2 hours").
    public let status: String

    public init(id: String, name: String, image: String, state: String, status: String = "") {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
    }

    public var isRunning: Bool { state == "running" }
    /// Containers kinhin itself created for CI jobs (deleting one cancels a job).
    public var isKinhinRunner: Bool { name.hasPrefix("kinhin") }
}

public struct ManagedVolume: Equatable, Sendable, Identifiable {
    public let name: String
    public let driver: String

    public var id: String { name }

    public init(name: String, driver: String = "") {
        self.name = name
        self.driver = driver
    }
}

public enum ContainerManagerError: LocalizedError, Equatable {
    case toolMissing(ContainerTool)
    case invalidName(String)
    case invalidImage(String)
    case commandFailed(what: String, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .toolMissing(let tool):
            return "\(tool.title) is not installed (\(tool.binaryName) was not found)."
        case .invalidName(let name):
            return "'\(name)' is not a valid name. Use letters, numbers, '.', '_' or '-', starting with a letter or number."
        case .invalidImage(let image):
            return "'\(image)' is not a valid image reference."
        case .commandFailed(let what, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "\(what) failed." : "\(what) failed: \(detail.prefix(400))"
        }
    }
}

/// Lists, creates, and deletes containers and volumes through the Docker or
/// Apple `container` CLI. All work goes through an injectable shell so it is
/// unit-testable; names and images are validated first so a value can never
/// be mistaken for a command-line option.
public struct ContainerManager: Sendable {
    public let tool: ContainerTool
    let binary: String?
    let shell: ShellRunning

    public init(tool: ContainerTool, shell: ShellRunning = Shell(), binary: String? = nil) {
        self.tool = tool
        self.shell = shell
        self.binary = binary ?? Paths.findExecutable(named: tool.binaryName)
    }

    // MARK: Validation

    public static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil
    }

    public static func isValidImage(_ image: String) -> Bool {
        image.range(of: "^[A-Za-z0-9][A-Za-z0-9_.:/@-]{0,255}$", options: .regularExpression) != nil
    }

    // MARK: Reading

    public func containers() async throws -> [ManagedContainer] {
        switch tool {
        case .docker:
            let out = try await run(["ps", "--all", "--no-trunc", "--format", "{{json .}}"], what: "listing containers")
            return Self.parseDockerContainers(out)
        case .appleContainer:
            let out = try await run(["list", "--all", "--format", "json"], what: "listing containers")
            return Self.parseAppleContainers(out)
        }
    }

    public func volumes() async throws -> [ManagedVolume] {
        switch tool {
        case .docker:
            let out = try await run(["volume", "ls", "--format", "{{json .}}"], what: "listing volumes")
            return Self.parseDockerVolumes(out)
        case .appleContainer:
            let out = try await run(["volume", "list", "--format", "json"], what: "listing volumes")
            return Self.parseAppleVolumes(out)
        }
    }

    // MARK: Creating & deleting

    /// Creates (does not start) a container from an image.
    public func createContainer(name: String, image: String) async throws {
        guard Self.isValidName(name) else { throw ContainerManagerError.invalidName(name) }
        guard Self.isValidImage(image) else { throw ContainerManagerError.invalidImage(image) }
        _ = try await run(["create", "--name", name, image], what: "creating container '\(name)'")
    }

    public func createVolume(name: String) async throws {
        guard Self.isValidName(name) else { throw ContainerManagerError.invalidName(name) }
        _ = try await run(["volume", "create", name], what: "creating volume '\(name)'")
    }

    /// Deletes a container; `force` also stops it first if it is running.
    public func deleteContainer(id: String, force: Bool) async throws {
        guard Self.isValidName(id) else { throw ContainerManagerError.invalidName(id) }
        var args: [String]
        switch tool {
        case .docker: args = ["rm"] + (force ? ["--force"] : []) + [id]
        case .appleContainer: args = ["delete"] + (force ? ["--force"] : []) + [id]
        }
        _ = try await run(args, what: "deleting container '\(id)'")
    }

    public func startContainer(id: String) async throws {
        guard Self.isValidName(id) else { throw ContainerManagerError.invalidName(id) }
        _ = try await run(["start", id], what: "starting container '\(id)'")
    }

    public func stopContainer(id: String) async throws {
        guard Self.isValidName(id) else { throw ContainerManagerError.invalidName(id) }
        _ = try await run(["stop", id], what: "stopping container '\(id)'")
    }

    /// Docker has a native restart; Apple's CLI does not, so it is stop → start.
    public func restartContainer(id: String) async throws {
        guard Self.isValidName(id) else { throw ContainerManagerError.invalidName(id) }
        switch tool {
        case .docker:
            _ = try await run(["restart", id], what: "restarting container '\(id)'")
        case .appleContainer:
            _ = try await run(["stop", id], what: "restarting container '\(id)'")
            _ = try await run(["start", id], what: "restarting container '\(id)'")
        }
    }

    public func deleteVolume(name: String) async throws {
        guard Self.isValidName(name) else { throw ContainerManagerError.invalidName(name) }
        let verb = tool == .docker ? "rm" : "delete"
        _ = try await run(["volume", verb, name], what: "deleting volume '\(name)'")
    }

    // MARK: Plumbing

    private func run(_ args: [String], what: String) async throws -> String {
        guard let binary else { throw ContainerManagerError.toolMissing(tool) }
        let result = try await shell.run([binary] + args, cwd: nil, timeout: 60)
        guard result.succeeded else {
            throw ContainerManagerError.commandFailed(what: what, stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result.stdout
    }

    // MARK: Parsing (internal for tests)

    /// One JSON object per line (`--format '{{json .}}'`).
    static func jsonLines(_ text: String) -> [[String: Any]] {
        text.split(whereSeparator: \.isNewline).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    /// A JSON array of objects, tolerating an empty/blank document.
    static func jsonArray(_ text: String) -> [[String: Any]] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else { return [] }
        return (object as? [[String: Any]]) ?? []
    }

    static func parseDockerContainers(_ text: String) -> [ManagedContainer] {
        jsonLines(text).compactMap { row in
            guard let id = row["ID"] as? String else { return nil }
            let name = (row["Names"] as? String)?.split(separator: ",").first.map(String.init) ?? id
            return ManagedContainer(
                id: id,
                name: name,
                image: row["Image"] as? String ?? "",
                state: (row["State"] as? String ?? "").lowercased(),
                status: row["Status"] as? String ?? ""
            )
        }
    }

    static func parseDockerVolumes(_ text: String) -> [ManagedVolume] {
        jsonLines(text).compactMap { row in
            guard let name = row["Name"] as? String else { return nil }
            return ManagedVolume(name: name, driver: row["Driver"] as? String ?? "")
        }
    }

    /// Apple `container list --format json`, verified against apple/container
    /// source: each object has `id` and `configuration.id`, the image at
    /// `configuration.image.reference`, and the state either as a plain string
    /// `status` ("running", "stopped", …; older releases) or as an object
    /// `status.state` (newer releases). All shapes are accepted.
    static func parseAppleContainers(_ text: String) -> [ManagedContainer] {
        jsonArray(text).compactMap { row in
            let configuration = row["configuration"] as? [String: Any]
            guard let id = (configuration?["id"] as? String) ?? (row["id"] as? String) else { return nil }
            let imageObject = configuration?["image"] as? [String: Any]
            let image = (imageObject?["reference"] as? String) ?? (configuration?["image"] as? String) ?? ""
            let statusObject = row["status"] as? [String: Any]
            let state = ((statusObject?["state"] as? String) ?? (row["status"] as? String) ?? (row["state"] as? String) ?? "").lowercased()
            return ManagedContainer(id: id, name: id, image: image, state: state, status: state)
        }
    }

    /// Apple `container volume list --format json`: `{id, configuration:
    /// {name, driver, …}}` (top-level `name` accepted too).
    static func parseAppleVolumes(_ text: String) -> [ManagedVolume] {
        jsonArray(text).compactMap { row in
            let configuration = row["configuration"] as? [String: Any]
            guard let name = (configuration?["name"] as? String) ?? (row["name"] as? String) ?? (row["id"] as? String) else { return nil }
            let driver = (configuration?["driver"] as? String) ?? (row["driver"] as? String) ?? ""
            return ManagedVolume(name: name, driver: driver)
        }
    }
}
