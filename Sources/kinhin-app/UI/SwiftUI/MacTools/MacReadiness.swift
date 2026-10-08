import Foundation

/// The "is this Mac ready to run jobs" rule, as a value: tart with its base
/// image, or an enabled Linux runtime (Docker / Apple container) that is
/// actually installed. Tart is optional; a Linux-only Mac is a valid setup.
struct MacReadiness: Equatable {
    /// tart is installed and its base image is prepared.
    var tartReady = false
    var containerEnabled = false
    var containerInstalled = false
    var dockerEnabled = false
    var dockerInstalled = false

    /// Enabled *and* installed Linux runtimes, by display name.
    var activeLinuxRuntimes: [String] {
        var active: [String] = []
        if containerEnabled, containerInstalled { active.append("Apple container") }
        if dockerEnabled, dockerInstalled { active.append("Docker") }
        return active
    }

    var isReady: Bool { tartReady || !activeLinuxRuntimes.isEmpty }

    /// Plain-language summary of what jobs can run here (for the final step).
    var runsOnDescription: String {
        let linux = activeLinuxRuntimes.joined(separator: ", ")
        switch (tartReady, activeLinuxRuntimes.isEmpty) {
        case (true, true): return "macOS jobs (tart)"
        case (true, false): return "macOS jobs (tart) and Linux jobs (\(linux))"
        case (false, false): return "Linux jobs only (\(linux)) — macOS jobs need tart, which isn't set up"
        case (false, true): return "nothing yet"
        }
    }
}
