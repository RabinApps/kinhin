import Foundation

/// State of Apple's Command Line Tools on this machine.
public enum CLTState: Equatable, Sendable {
    /// Receipt present and its version satisfies the current OS.
    case ok(version: String)
    /// Receipt present but older than the running macOS — Homebrew refuses
    /// to build ("Your Command Line Tools are too outdated").
    case outdated(version: String, macOSVersion: String)
    /// No receipt at all — CLT never installed (or wiped).
    case missing
    /// xcode-select points nowhere (rare; breaks shims like `clang`).
    case unselected

    var isOK: Bool {
        if case .ok = self { return true }
        return false
    }

    /// Human-readable one-liner for the checklist detail.
    public var detail: String {
        switch self {
        case .ok(let version):
            return "version \(version) — up to date"
        case .outdated(let version, let macOS):
            return "version \(version) is older than macOS \(macOS) — Homebrew will refuse to build"
        case .missing:
            return "not installed — Homebrew needs it to build from source"
        case .unselected:
            return "xcode-select points nowhere — reinstall and re-select"
        }
    }
}

/// Probes Apple Command Line Tools via the package receipt, which is the
/// same signal Homebrew itself uses. All commands are injectable so tests
/// never shell out.
public struct CLTProbe: Sendable {
    public struct Commands: Sendable {
        var selectedDir: String
        var receiptInfo: String

        public init(
            selectedDir: String = "xcode-select -p",
            receiptInfo: String = "pkgutil --pkg-info=com.apple.pkg.CLTools_Executables"
        ) {
            self.selectedDir = selectedDir
            self.receiptInfo = receiptInfo
        }
    }

    let shell: ShellRunning
    let commands: Commands
    /// The running macOS version as `sw_vers -productVersion` prints it
    /// ("27.0", "26.6.1"); read in-process, no spawn.
    let osVersion: @Sendable () -> String

    public init(
        shell: ShellRunning = Shell(), commands: Commands = .init(),
        osVersion: @escaping @Sendable () -> String = CLTProbe.currentOSVersion
    ) {
        self.shell = shell
        self.commands = commands
        self.osVersion = osVersion
    }

    /// `major.minor`, plus `.patch` only when non-zero (sw_vers's shape).
    public static func currentOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion > 0 ? "\(base).\(version.patchVersion)" : base
    }

    /// "26.6.0.0.1781586589" → "26.6.0" (strip build suffix).
    static func displayVersion(_ receiptVersion: String) -> String {
        var parts = receiptVersion.split(separator: ".").map(String.init)
        if parts.count > 3 { parts = Array(parts.prefix(3)) }
        return parts.joined(separator: ".")
    }

    /// "27.0.1" → "27.0": the major.minor release line.
    static func releaseLine(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// Compare dotted numeric versions; true when `version` satisfies `required`
    /// (segment-wise, missing segments are zeros). "26.6" satisfies "27.0"? No.
    /// "27.0" satisfies "27.0"? Yes.
    static func isVersion(_ version: String, atLeast required: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = required.split(separator: ".").map { Int($0) ?? 0 }
        let width = max(a.count, b.count)
        for i in 0..<width {
            let ai = i < a.count ? a[i] : 0
            let bi = i < b.count ? b[i] : 0
            if ai != bi { return ai > bi }
        }
        return true
    }

    /// The CLT state. Throws only `CancellationError`: a probe that could not
    /// run is logged and reads as "tool absent", but a cancelled one stops.
    public func check() async throws -> CLTState {
        func run(_ command: String) async throws -> ShellResult? {
            // The probe commands are fixed strings; run through the shell so
            // plain argv tools work with the same ShellRunning abstraction.
            do {
                return try await shell.run(["/bin/bash", "-c", command], cwd: nil, timeout: 15)
            } catch let cancelled as CancellationError {
                throw cancelled
            } catch {
                Log.warn("devtools", "probe `\(command)` could not run: \(error.localizedDescription)")
                return nil
            }
        }

        // 1. The receipt is the ground truth for "are CLT installed at all"
        // (the same package receipt Homebrew reads).
        guard let receipt = try await run(commands.receiptInfo), receipt.succeeded else {
            return .missing
        }
        var version: String?
        for line in receipt.stdout.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "version" {
                version = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let receiptVersion = version, !receiptVersion.isEmpty else {
            return .missing
        }

        // 2. With a receipt present, a broken/absent xcode-select target
        // means the tools exist but nothing is selected to use them.
        if let dir = try await run(commands.selectedDir) {
            let path = dir.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !dir.succeeded || path.isEmpty
                || path.contains("error: unable to get active developer directory")
            {
                return .unselected
            }
        }

        // 3. Compare the receipt version against the running macOS version.
        let macOS = osVersion()
        let clt = Self.displayVersion(receiptVersion)
        // Compared by release line (major.minor): Apple ships Command Line
        // Tools per macOS release, not per macOS patch, so CLT 27.0.0 is the
        // current tools for macOS 27.0.1 and reinstalling them would change nothing.
        if Self.isVersion(Self.releaseLine(clt), atLeast: Self.releaseLine(macOS)) {
            return .ok(version: clt)
        }
        return .outdated(version: clt, macOSVersion: macOS)
    }
}

/// Public extension so every surface prints the same repair instructions.
public enum CLTRepair {
    /// One-liner shown in CLI output and copied by the app's fix button.
    /// Reinstalling requires sudo, so the app hands the command to Terminal
    /// where the user can approve the prompt.
    public static let commandLine = "sudo rm -rf /Library/Developer/CommandLineTools && sudo xcode-select --install"

    /// Fallback when Software Update shows nothing (Homebrew's own advice).
    public static let fallbackHint =
        "If no update appears, download \"Command Line Tools for Xcode\" from https://developer.apple.com/download/all/"
}
