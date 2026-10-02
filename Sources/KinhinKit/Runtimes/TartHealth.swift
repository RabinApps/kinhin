import Foundation

/// Result of probing whether the installed `tart` binary actually launches.
///
/// Known failure mode (openai/homebrew-tools#27): Tart bottles from the
/// OpenAI tap can be killed by Gatekeeper/AMFI on launch — "zsh: killed tart",
/// exit 137 — because the binary is un-notarized and its
/// `com.apple.vm.networking` entitlement has no matching profile.
public enum TartHealth: Sendable, Equatable {
    /// No tart binary on PATH (or the configured override).
    case missing
    /// `tart --version` exited 0 with expected output.
    case healthy
    /// The process was killed by a signal at launch (notarization/entitlement).
    case killedOnLaunch
    /// The binary launches but exits with an error for another reason.
    case broken(String)
}

/// A concrete fix for a tart problem: a display title plus the exact commands.
public struct TartRepair: Sendable, Equatable {
    public let title: String
    public let commands: [[String]]

    public init(title: String, commands: [[String]]) {
        self.title = title
        self.commands = commands
    }

    /// The one-line shell rendering of all commands, joined with ` && `.
    public var commandLine: String {
        commands.map { $0.joined(separator: " ") }.joined(separator: " && ")
    }
}

/// Probes the real tart binary so `kinhin doctor` and the setup app can tell
/// "installed and working" apart from "installed but killed on launch".
public struct TartHealthProbe {
    /// The Homebrew command that installs tart (every "install tart" hint).
    public static let installCommand =
        "brew tap openai/tools && brew trust openai/tools && brew install openai/tools/tart"

    let shell: ShellRunning
    let configuredPath: String?

    public init(shell: ShellRunning = Shell(), configuredPath: String? = nil) {
        self.shell = shell
        self.configuredPath = configuredPath
    }

    /// Runs `tart --version` and classifies the outcome. When the launch fails
    /// ambiguously, consults the unified log for an AMFI/code-signature kill.
    public func check(timeout: TimeInterval = 10) async -> TartHealth {
        guard let binary = Paths.findExecutable(named: "tart", override: configuredPath) else {
            return .missing
        }

        let launch: ShellResult?
        do {
            launch = try await shell.run([binary, "--version"], cwd: nil, timeout: timeout)
        } catch {
            // Classified below as an ambiguous launch failure.
            Log.warn("tart", "could not run '\(binary) --version': \(error.localizedDescription)")
            launch = nil
        }
        if let launch, Self.launchLooksHealthy(launch) {
            return .healthy
        }

        // Strongest signal of a Gatekeeper kill: the process died by SIGKILL
        // (Foundation reports the signal number; shells report 128+signal).
        if let launch, launch.terminatedBySignal(9) {
            return .killedOnLaunch
        }

        // Ambiguous launch failure — consult the unified log for AMFI evidence.
        if await Self.systemLogMentionsAMFIKill(shell: shell, timeout: 15) {
            return .killedOnLaunch
        }

        if let launch, let reason = Self.classifyFailure(launch) {
            return .broken(reason)
        }
        // We could not run the probe at all (e.g. log show also failed);
        // treat an unverifiable launch as a kill — the safest repair advice.
        return .killedOnLaunch
    }

    /// True when `tart --version` behaves like a working binary. Older builds print
    /// "tart version 2.32.1"; newer ones (2.40+) print only the bare version number.
    static func launchLooksHealthy(_ result: ShellResult) -> Bool {
        guard result.succeeded else { return false }
        if result.stdout.contains("tart version") { return true }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^[0-9]+\.[0-9]+(\.[0-9]+)?([-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
    }

    /// Maps a failed launch to a short reason. `nil` means "unclassifiable".
    static func classifyFailure(_ result: ShellResult) -> String? {
        if result.exitCode == 137 || result.terminatedBySignal(9) {
            return "terminated by SIGKILL (exit 137) — Gatekeeper kill, see openai/homebrew-tools#27"
        }
        if result.exitCode == 124 {
            return "timed out"
        }
        let detail = !result.stderr.isEmpty ? result.stderr : result.stdout
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "exited with code \(result.exitCode)" }
        return "exited with code \(result.exitCode): \(String(trimmed.prefix(200)))"
    }

    /// Scans the unified log for an AMFI / code-signature kill of tart.
    static func systemLogMentionsAMFIKill(shell: ShellRunning, timeout: TimeInterval) async -> Bool {
        let predicate =
            "eventMessage CONTAINS[c] 'tart' AND " + "(eventMessage CONTAINS[c] 'AMFI' OR "
            + "eventMessage CONTAINS[c] 'Code Signature Invalid' OR " + "eventMessage CONTAINS[c] 'notari')"
        let argv = [
            "/usr/bin/log", "show",
            "--last", "5m",
            "--style", "compact",
            "--predicate", predicate,
        ]
        let result: ShellResult
        do {
            result = try await shell.run(argv, cwd: nil, timeout: timeout)
        } catch {
            Log.warn("tart", "could not read the unified log for AMFI evidence: \(error.localizedDescription)")
            return false
        }
        let text = (result.stdout + "\n" + result.stderr).lowercased()
        return text.contains("amfi") || text.contains("code signature invalid")
    }

    /// Ordered repair plans for a given health state.
    public static func repairs(for health: TartHealth) -> [TartRepair] {
        // Trust the WHOLE tap, not just the formula: tart depends on softnet
        // from the same tap, and brew with formula-only trust dry-runs the
        // install ("Would install…") and exits 0 without installing anything.
        let openaiInstall = TartRepair(
            title: "Install tart via the OpenAI tap",
            commands: [
                ["brew", "tap", "openai/tools"],
                ["brew", "trust", "openai/tools"],
                ["brew", "install", "openai/tools/tart"],
            ]
        )
        let cirrusRollback = TartRepair(
            title: "Roll back to the notarized Cirrus Labs build (openai/cli/tart, known-good 2.32.1)",
            commands: [
                ["brew", "uninstall", "openai/tools/tart", "openai/tools/softnet"],
                ["brew", "tap", "openai/cli"],
                ["brew", "trust", "openai/cli"],
                ["brew", "install", "openai/cli/tart"],
            ]
        )
        let openaiRetry = TartRepair(
            title: "Retry the OpenAI tap (check openai/homebrew-tools#27 for a fixed bottle first)",
            commands: [
                ["brew", "uninstall", "openai/cli/tart"],
                ["brew", "tap", "openai/tools"],
                ["brew", "trust", "openai/tools"],
                ["brew", "install", "openai/tools/tart"],
            ]
        )

        switch health {
        case .missing:
            return [openaiInstall]
        case .healthy:
            return []
        case .killedOnLaunch:
            // Gatekeeper kill: the current bottle will never run. Roll back first.
            return [cirrusRollback, openaiRetry]
        case .broken:
            // Some other breakage: reinstall first, roll back as plan B.
            return [openaiInstall, cirrusRollback]
        }
    }
}

extension ShellResult {
    /// True when the process was terminated by the given POSIX signal
    /// (e.g. SIGKILL 9 → exit code 137 on many shells).
    func terminatedBySignal(_ signal: Int32) -> Bool {
        // Foundation reports signal deaths as exitStatus with the signal in
        // the high bits (128 + signal) for shells; Foundation's
        // terminationReason is unavailable on ShellResult, so accept both
        // encodings conservatively.
        exitCode == signal || exitCode == 128 + signal
    }
}
