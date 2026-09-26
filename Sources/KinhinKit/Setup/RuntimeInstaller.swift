import Foundation

/// The tools kinhin can help install.
public enum InstallableTool: String, CaseIterable, Sendable {
    case tart
    case appleContainer
    case docker

    public var title: String {
        switch self {
        case .tart: return "tart"
        case .appleContainer: return "Apple container"
        case .docker: return "Docker"
        }
    }

    /// Executable that proves the tool is installed.
    var binaryName: String {
        switch self {
        case .tart: return "tart"
        case .appleContainer: return "container"
        case .docker: return "docker"
        }
    }

    public var isInstalled: Bool { Paths.findExecutable(named: binaryName) != nil }
}

/// One way to install a tool. Commands are argv lists whose first element may
/// be a bare tool name ("brew", "container", "colima"); it is resolved to an
/// absolute path when the plan runs (the process runner does not search PATH).
public struct InstallOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// What to expect: size, prompts, follow-up steps.
    public let detail: String
    /// Install commands (need Homebrew when `needsBrew`).
    public let commands: [[String]]
    /// Commands run after a successful install (e.g. start the service).
    let postInstall: [[String]]
    public let needsBrew: Bool
    /// Where to download it by hand when Homebrew is not available.
    public let manualURL: URL?

    public init(
        id: String, title: String, detail: String, commands: [[String]], postInstall: [[String]] = [],
        needsBrew: Bool = true, manualURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.commands = commands
        self.postInstall = postInstall
        self.needsBrew = needsBrew
        self.manualURL = manualURL
    }

    /// Short name picked with `kinhin setup repair <tool> --method`: the id
    /// after the tool prefix ("desktop", "orbstack", "colima", "brew").
    public var method: String { id.split(separator: "-").last.map(String.init) ?? id }

    /// The exact commands, as a user could paste them into Terminal.
    public var commandLine: String {
        (commands + postInstall).map { $0.joined(separator: " ") }.joined(separator: " && ")
    }
}

/// Tool output is mostly noise (Homebrew prints auto-update chatter first and
/// the real error last). Keep the lines that say what went wrong.
func summarize(_ output: String) -> String {
    let lines = output.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    let errors = lines.filter { $0.lowercased().hasPrefix("error") || $0.lowercased().contains("error:") }
    let chosen = errors.isEmpty ? Array(lines.suffix(4)) : Array(errors.suffix(4))
    return String(chosen.joined(separator: " ").prefix(500))
}

enum RuntimeInstallerError: LocalizedError, Equatable {
    case brewMissing
    case commandFailed(command: String, output: String)
    case notInstalledAfterwards(InstallableTool)
    case unsupportedHost(String)
    case unknownMethod(method: String, tool: InstallableTool, valid: [String])

    public var errorDescription: String? {
        switch self {
        case .brewMissing:
            return "Homebrew isn't installed. Install it from https://brew.sh, or download the tool by hand."
        case .commandFailed(let command, let output):
            let detail = summarize(output)
            return "\(command) failed\(detail.isEmpty ? "." : ": \(detail)")"
        case .notInstalledAfterwards(let tool):
            return
                "The install finished but \(tool.binaryName) still isn't on this Mac's PATH. Open a new Terminal or restart kinhin."
        case .unsupportedHost(let reason):
            return reason
        case .unknownMethod(let method, let tool, let valid):
            return "'\(method)' is not a way to install \(tool.title). Use one of: \(valid.joined(separator: ", "))."
        }
    }
}

public enum RuntimeInstaller {
    public static var brewPath: String? { Paths.findExecutable(named: "brew") }

    /// Install options for a tool, best first.
    public static func options(for tool: InstallableTool) -> [InstallOption] {
        switch tool {
        case .tart:
            let repair = TartHealthProbe.repairs(for: .missing)[0]
            return [
                InstallOption(
                    id: "tart-brew",
                    title: "tart via Homebrew",
                    detail:
                        "Runs macOS jobs in virtual machines. Adds the openai/tools tap, then installs tart. Takes a minute or two.",
                    commands: repair.commands,
                    manualURL: URL(string: "https://tart.run/")
                )
            ]
        case .appleContainer:
            return [
                InstallOption(
                    id: "container-brew",
                    title: "Apple container via Homebrew",
                    detail:
                        "Linux containers as lightweight VMs (Apple silicon, recent macOS). Installs the container CLI, then starts its system service.",
                    commands: [["brew", "install", "container"]],
                    postInstall: [["container", "system", "start", "--enable-kernel-install"]],
                    manualURL: URL(string: "https://github.com/apple/container/releases")
                )
            ]
        case .docker:
            return [
                InstallOption(
                    id: "docker-desktop",
                    title: "Docker Desktop",
                    detail:
                        "The standard choice (large download). Open Docker once after installing to finish its setup.",
                    commands: [["brew", "install", "--cask", "docker-desktop"]],
                    manualURL: URL(string: "https://www.docker.com/products/docker-desktop/")
                ),
                InstallOption(
                    id: "docker-orbstack",
                    title: "OrbStack",
                    detail: "A faster, lighter Docker for Mac. Open OrbStack once after installing.",
                    commands: [["brew", "install", "--cask", "orbstack"]],
                    manualURL: URL(string: "https://orbstack.dev/download")
                ),
                InstallOption(
                    id: "docker-colima",
                    title: "Colima + Docker CLI",
                    detail: "Command-line only, no app. Installs colima and docker, then starts colima.",
                    commands: [["brew", "install", "colima", "docker"]],
                    postInstall: [["colima", "start"]],
                    manualURL: URL(string: "https://github.com/abiosoft/colima")
                ),
            ]
        }
    }

    /// The option to install with: the named method, or the first one this
    /// Mac supports. Throws when the method is unknown or can't run here.
    public static func option(
        for tool: InstallableTool, method: String?, on host: HostFacts
    ) throws -> InstallOption {
        try HostRequirements.ensureSupported(tool, on: host)
        let offered = HostRequirements.offeredOptions(for: tool, on: host)
        guard let method else {
            guard let first = offered.first else {
                throw RuntimeInstallerError.unsupportedHost("\(tool.title) has no install option for this Mac.")
            }
            return first
        }
        let all = options(for: tool)
        guard let known = all.first(where: { $0.method == method }) else {
            throw RuntimeInstallerError.unknownMethod(method: method, tool: tool, valid: all.map(\.method))
        }
        guard let chosen = offered.first(where: { $0.method == method }) else {
            throw RuntimeInstallerError.unsupportedHost(
                HostRequirements.verdict(for: known, on: host).reason ?? "\(known.title) can't run on this Mac.")
        }
        return chosen
    }

    /// Replaces a bare tool name at the start of a command with its absolute
    /// path (nil when it cannot be found).
    static func resolve(_ command: [String], brew: String?) -> [String]? {
        guard let first = command.first else { return nil }
        if first.hasPrefix("/") { return command }
        let path = first == "brew" ? brew : Paths.findExecutable(named: first)
        guard let path else { return nil }
        return [path] + command.dropFirst()
    }

    /// Runs the option's commands in order (install, then post-install), then
    /// checks the tool is really there. Throws with the failing command and
    /// its output so the UI can show it. Refuses up front when this Mac cannot
    /// run what the option installs.
    public static func install(
        _ option: InstallOption, tool: InstallableTool,
        shell: ShellRunning = Shell(), brew: String? = RuntimeInstaller.brewPath,
        host: HostFacts = .current(),
        isInstalled: (InstallableTool) -> Bool = { $0.isInstalled }
    ) async throws {
        if case .unsupported(let reason) = HostRequirements.verdict(for: option, on: host) {
            throw RuntimeInstallerError.unsupportedHost(reason)
        }
        if option.needsBrew, brew == nil { throw RuntimeInstallerError.brewMissing }
        for command in option.commands + option.postInstall {
            guard let argv = resolve(command, brew: brew) else {
                throw RuntimeInstallerError.commandFailed(
                    command: command.joined(separator: " "), output: "\(command[0]) was not found")
            }
            let result = try await shell.run(argv, cwd: nil, timeout: 1800)
            guard result.succeeded else {
                throw RuntimeInstallerError.commandFailed(
                    command: command.joined(separator: " "),
                    output: result.stderr.isEmpty ? result.stdout : result.stderr)
            }
        }
        guard isInstalled(tool) else { throw RuntimeInstallerError.notInstalledAfterwards(tool) }
    }
}
