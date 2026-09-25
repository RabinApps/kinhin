import Foundation
import Synchronization

/// Reference box for `GitHubClient`'s sticky runs-read mode. GitHub grants
/// fine-grained tokens runs access only through the repository Actions
/// permission, so org scopes that 404 on `/orgs/{org}/actions/runs` fall
/// back to per-repository reads; the flag survives because the client is a
/// struct copied by value while this box is shared.
final class RunsModeBox: Sendable {
    private let state = Mutex(false)

    var viaRepos: Bool { state.withLock { $0 } }

    func setViaRepos() { state.withLock { $0 = true } }
}
