import Foundation
import Synchronization

/// A forge's API budget as its last response reported it (GitHub's
/// `X-RateLimit-*` headers). The engine stretches its poll cadence and drops
/// cosmetic reads as the budget runs low, instead of running into the wall.
public struct ForgeRateLimit: Sendable, Equatable {
    public var remaining: Int
    public var limit: Int
    public var resetAt: Date

    /// Below this share of the budget, cosmetic reads (running-job
    /// attribution) stop and the poll cadence stretches the most.
    static let lowFraction = 0.10
    /// Below this share, the poll cadence starts stretching.
    static let tightFraction = 0.25

    var fractionRemaining: Double {
        limit > 0 ? Double(remaining) / Double(limit) : 1
    }

    var isLow: Bool { fractionRemaining < Self.lowFraction }

    /// Parses the rate-limit headers; nil when the response carries none.
    init?(headers response: HTTPURLResponse) {
        guard let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap({ Int($0) }),
            let limit = response.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap({ Int($0) }),
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap({ TimeInterval($0) })
        else { return nil }
        self.init(remaining: remaining, limit: limit, resetAt: Date(timeIntervalSince1970: reset))
    }

    init(remaining: Int, limit: Int, resetAt: Date) {
        self.remaining = remaining
        self.limit = limit
        self.resetAt = resetAt
    }
}

/// The last rate limit a client saw, shared across copies of the client
/// (a struct copied by value, like `RunsModeBox`).
final class RateLimitBox: Sendable {
    private let state = Mutex<ForgeRateLimit?>(nil)

    var current: ForgeRateLimit? { state.withLock { $0 } }

    func record(_ limit: ForgeRateLimit) {
        state.withLock { $0 = limit }
    }
}
