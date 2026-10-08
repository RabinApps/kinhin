import Foundation

// MARK: - Registration script inputs

/// Where a registration script runs. The same forge registers differently in
/// each: paths (`$HOME/...`, `/opt/...`, the host's agent directory), the
/// runtime marker some agents need, and who owns the work directory.
enum RegistrationGuest {
    /// A tart VM. The guest may be macOS or Linux, so paths use `$HOME/...`.
    case tartVM
    /// An Apple container or Docker container (`/opt/<agent>` layout, root).
    case linuxContainer
    /// The Mac itself, through the host runtime that owns the agent
    /// directory and the per-instance work directory.
    case host(HostRuntime)
}

/// Everything a registration script is built from, passed to
/// `ForgeDescriptor.registrationScript(for:_:)`.
struct RegistrationRequest {
    let forge: Forge
    /// The shared registration token (`sharedShortLived`/`sharedLongLived`).
    let token: String
    /// Per-runner credentials (`perRunner`/`jitConfig`), keyed by runner name.
    let runnerTokens: [String: String]
    /// The instance name.
    let name: String
    let runnerCount: Int
    let route: RepoRoute
    /// The pool's labels, when it overrides the forge's own.
    let labels: [String]?
}
