import Foundation
import Synchronization

/// Caches the short-lived runner registration token (GitHub: 1 h), refreshing
/// it `refreshMargin` before it expires. Thread-safe. Under concurrent
/// contention it may fetch twice — harmless against the GitHub API.
///
/// The forge reports when the token expires (`expires_at`); that is trusted
/// when given. `ttl` is the fallback for a forge that does not say.
final class RegistrationTokenCache: Sendable {
    private struct Entry: Sendable {
        let token: String
        let expiresAt: Date
    }

    private let entry = Mutex<Entry?>(nil)
    private let ttl: TimeInterval
    private let refreshMargin: TimeInterval

    init(ttl: TimeInterval = 50 * 60, refreshMargin: TimeInterval = 5 * 60) {
        self.ttl = ttl
        self.refreshMargin = refreshMargin
    }

    /// Returns the cached token while fresh; otherwise invokes `fetch` and
    /// keeps the token for `ttl`.
    func token(fetch: () async throws -> String) async throws -> String {
        try await resolve {
            (token: try await fetch(), expiresAt: nil)
        }
    }

    /// Returns the cached token while fresh; otherwise invokes `fetch`. The
    /// token stays fresh until `refreshMargin` before the `expiresAt` the forge
    /// reported (`ttl` from now when it reported none).
    func token(fetchExpiring fetch: () async throws -> (token: String, expiresAt: Date?)) async throws -> String {
        try await resolve(fetch)
    }

    private func resolve(_ fetch: () async throws -> (token: String, expiresAt: Date?)) async throws -> String {
        let now = Date()
        if let current = entry.withLock({ $0 }),
            now < current.expiresAt.addingTimeInterval(-refreshMargin)
        {
            return current.token
        }
        let fresh = try await fetch()
        let expiry = fresh.expiresAt ?? now.addingTimeInterval(ttl)
        entry.withLock { $0 = Entry(token: fresh.token, expiresAt: expiry) }
        return fresh.token
    }

    func invalidate() {
        entry.withLock { $0 = nil }
    }
}
