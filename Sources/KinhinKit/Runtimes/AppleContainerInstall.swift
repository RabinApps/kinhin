import Foundation

/// Where Apple's `container` came from, how it is signed, and where it keeps its data, so `kinhin doctor` can warn
/// about the one combination that breaks quietly: an ad-hoc signed build (the Homebrew formula) with its app root on
/// an external volume.
///
/// kinhin cannot hand its own privacy grants to the container daemons. `container system start` registers the API
/// server with launchd, and the API server registers every container's runtime helper and the network plugin with
/// launchd too, so launchd, not kinhin, is the responsible process for the daemons that open the VM disk images.
/// Each of those binaries needs its own Full Disk Access or Removable Volumes grant. macOS ties a grant to the code
/// signature, and an ad-hoc signature changes with every build, so `brew upgrade container` drops the grants and the
/// next start fails. Apple's signed installer has a stable Developer ID signature, so its grants survive upgrades.
public struct AppleContainerInstall: Codable, Equatable, Sendable {
    /// How the `container` CLI was installed.
    public enum Source: String, Codable, Sendable {
        /// The Homebrew formula (`brew install container`): a binary under a Homebrew Cellar.
        case homebrew
        /// Apple's signed installer package from github.com/apple/container/releases (`/usr/local/bin/container`).
        case installer
        /// Anywhere else (a local build, a copied binary).
        case other
    }

    /// How the `container` CLI is code signed.
    public enum Signature: String, Codable, Sendable {
        /// Developer ID: a stable identity, so privacy grants survive upgrades.
        case developerID
        /// Ad-hoc: the identity changes with every build, so privacy grants break on upgrade.
        case adhoc
        /// Not signed at all.
        case unsigned
        /// Signed some other way, or `codesign` could not say.
        case unknown
    }

    /// The `container` binary, symlinks resolved.
    public let binaryPath: String
    public let source: Source
    public let signature: Signature
    /// The signing team (Developer ID only).
    public let teamID: String?
    /// The container app root (images, containers, kernels), symlinks resolved.
    public let appRoot: String
    /// Whether the app root is on an external or removable volume.
    public let appRootExternal: Bool

    public init(
        binaryPath: String, source: Source, signature: Signature, teamID: String?, appRoot: String,
        appRootExternal: Bool
    ) {
        self.binaryPath = binaryPath
        self.source = source
        self.signature = signature
        self.teamID = teamID
        self.appRoot = appRoot
        self.appRootExternal = appRootExternal
    }

    /// Where Apple publishes the signed installer.
    public static let installerURL = "https://github.com/apple/container/releases"

    /// Whether macOS privacy grants for this build break on every upgrade.
    public var grantsBreakOnUpgrade: Bool { signature == .adhoc || signature == .unsigned }

    /// The warning `kinhin doctor` shows, or nil when there is nothing to warn about. Ad-hoc with the app root on an
    /// external volume is a warning; ad-hoc on the internal disk is only a note, since no grant is needed there.
    public var warning: String? {
        guard grantsBreakOnUpgrade, appRootExternal else { return nil }
        let upgrade = source == .homebrew ? "`brew upgrade container`" : "every upgrade"
        return "container is \(signatureWords) and its data is on an external volume (\(appRoot)). "
            + "Its daemons run under launchd, not kinhin, so each needs its own Full Disk Access or Removable "
            + "Volumes grant, and \(upgrade) drops those grants. Install Apple's signed package instead "
            + "(\(Self.installerURL)), or re-grant after every upgrade."
    }

    /// A softer note for ad-hoc builds whose data is still on the internal disk.
    public var note: String? {
        guard grantsBreakOnUpgrade, !appRootExternal else { return nil }
        return "container is \(signatureWords): if you move its data to an external volume, its daemons "
            + "will need their own Full Disk Access grant after every upgrade. Apple's signed package avoids this."
    }

    /// The signature as words: "ad-hoc signed", "unsigned", "Developer ID (TEAM)", "signature unknown".
    var signatureWords: String {
        switch signature {
        case .developerID: return "Developer ID\(teamID.map { " (\($0))" } ?? "")"
        case .adhoc: return "ad-hoc signed"
        case .unsigned: return "unsigned"
        case .unknown: return "signature unknown"
        }
    }

    /// One line for the human doctor: source, signature, and where the data lives.
    public var summaryLine: String {
        let from: String
        switch source {
        case .homebrew: from = "Homebrew"
        case .installer: from = "signed installer"
        case .other: from = binaryPath
        }
        let data = appRootExternal ? "data on external volume \(appRoot)" : "data on internal disk"
        return "\(from), \(signatureWords), \(data)\(warning == nil ? " ✓" : " ⚠")"
    }

    // MARK: - Classification

    /// The install source from the resolved binary path.
    static func classifySource(ofResolvedPath path: String) -> Source {
        // The formula's binary resolves into a Cellar: /opt/homebrew/Cellar (Apple silicon) or /usr/local/Cellar.
        if path.contains("/Cellar/container/") || path.hasPrefix("/opt/homebrew/") {
            return .homebrew
        }
        if path == "/usr/local/bin/container" || path.hasPrefix("/usr/local/libexec/container/") {
            return .installer
        }
        return .other
    }

    /// The executable a launcher script hands off to, from the script's text: Homebrew's formula installs
    /// `bin/container` as a bash wrapper (`exec "<cellar>/libexec/container" "$@"`), and the wrapper itself is
    /// unsigned, so the signature that matters is the binary it runs. nil when `contents` is not a script or names no
    /// `exec` target.
    static func wrapperTarget(ofScript contents: String) -> String? {
        guard contents.hasPrefix("#!") else { return nil }
        for line in contents.split(whereSeparator: \.isNewline) {
            let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
            guard let index = words.firstIndex(of: "exec"), words.index(after: index) < words.endIndex else { continue }
            let target = words[words.index(after: index)].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if target.hasPrefix("/") { return target }
        }
        return nil
    }

    /// The signature and team from `codesign -dv --verbose=2` output (which `codesign` prints on stderr).
    static func classifySignature(fromCodesign output: String, succeeded: Bool) -> (Signature, String?) {
        if output.contains("not signed at all") { return (.unsigned, nil) }
        guard succeeded else { return (.unknown, nil) }
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0 == "Signature=adhoc" }) { return (.adhoc, nil) }
        if lines.contains(where: { $0.hasPrefix("Authority=Developer ID Application") }) {
            let team = lines.first { $0.hasPrefix("TeamIdentifier=") }
                .map { String($0.dropFirst("TeamIdentifier=".count)) }
                .flatMap { $0 == "not set" ? nil : $0 }
            return (.developerID, team)
        }
        return (.unknown, nil)
    }
}

// MARK: - Probe

extension AppleContainerInstall {
    /// The app root the probe checks: `container_app_root:` when it is set (the root kinhin passes to
    /// `container system start --app-root`), else the CLI's default. Where `container` keeps images, containers and
    /// kernels.
    public static var defaultAppRoot: URL { appRoot(configured: StorageLocations.current.containerAppRoot) }

    /// The app root for a configured `container_app_root:` (nil: the CLI's default).
    static func appRoot(configured: String?) -> URL {
        AppleContainerRuntime.kernels(underAppRoot: configured).deletingLastPathComponent()
    }

    /// Reads the live install: resolves the binary, asks `codesign` for its signature, and checks the app root's
    /// volume. Read-only; never touches the TCC database. nil when the CLI is not installed.
    public static func probe(
        shell: ShellRunning = Shell(), binary: String? = Paths.findExecutable(named: "container"),
        appRoot: URL = defaultAppRoot,
        isExternal: @Sendable (URL) -> Bool = { AppleContainerInstall.isExternalVolume($0) },
        read: @Sendable (String) -> String? = { AppleContainerInstall.scriptHead(at: $0) }
    ) async -> AppleContainerInstall? {
        guard let binary else { return nil }
        let resolved = executable(behind: URL(fileURLWithPath: binary).resolvingSymlinksInPath().path, read: read)
        let root = appRoot.resolvingSymlinksInPath()
        let codesign: (Signature, String?)
        do {
            let result = try await shell.run(
                ["/usr/bin/codesign", "-dv", "--verbose=2", resolved], cwd: nil, timeout: 20)
            codesign = classifySignature(fromCodesign: result.stderr + result.stdout, succeeded: result.succeeded)
        } catch {
            Log.warn("container", "codesign probe failed: \(error.localizedDescription)")
            codesign = (.unknown, nil)
        }
        return AppleContainerInstall(
            binaryPath: resolved, source: classifySource(ofResolvedPath: resolved), signature: codesign.0,
            teamID: codesign.1, appRoot: root.path, appRootExternal: isExternal(root))
    }

    /// The binary that actually runs for `path`: the `exec` target when `path` is a launcher script (followed once,
    /// symlinks resolved), else `path` itself.
    static func executable(behind path: String, read: (String) -> String?) -> String {
        guard let contents = read(path), let target = wrapperTarget(ofScript: contents) else { return path }
        return URL(fileURLWithPath: target).resolvingSymlinksInPath().path
    }

    /// The first 4 KB of a file as text, or nil when it cannot be read or is not text (a Mach-O binary).
    public static func scriptHead(at path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        // A close failure after reading changes nothing about what was read.
        defer { try? handle.close() }
        // An unreadable file is treated like a binary: there is no script to follow.
        guard let data = try? handle.read(upToCount: 4096) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether `url` lives on a volume other than the internal boot disk: under `/Volumes/`, or a volume macOS
    /// reports as removable, ejectable or not internal. A path that does not exist yet is judged by its prefix.
    public static func isExternalVolume(_ url: URL) -> Bool {
        if url.path.hasPrefix("/Volumes/") { return true }
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        // A path that cannot be read (it does not exist yet) is not known to be external.
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        return values.volumeIsRemovable == true || values.volumeIsEjectable == true || values.volumeIsInternal == false
    }
}
