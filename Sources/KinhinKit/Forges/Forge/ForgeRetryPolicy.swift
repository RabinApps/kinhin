import Foundation

// MARK: - ForgeRetryPolicy

/// The one retry policy every forge HTTP path follows (`ForgeTransport`,
/// `GitHubClient`, `GitHubScaleSetClient`):
///
/// - network errors and 5xx retry with exponential backoff and jitter;
/// - 429, and a 403 that is a real rate limit (it carries `Retry-After`, or
///   `X-RateLimit-Remaining: 0`), wait as long as the server asks, provided
///   that wait is at most `maxDelay`; a longer wait is surfaced to the caller
///   instead of stalling a poll for minutes;
/// - any other 403 is a permissions error and never retries — retrying it
///   only delayed the message the user needs to see.
///
/// Callers stay in charge of building requests and mapping statuses to their
/// own errors; they report each attempt's outcome to `run`.
struct ForgeRetryPolicy: Sendable {
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    /// Attempts beyond the first.
    var retries: Int = 2
    /// Backoff base: retry n waits about `baseDelay * 2^(n-1)` seconds.
    var baseDelay: TimeInterval = 1
    /// Ceiling for one backoff wait and for a server-requested wait.
    var maxDelay: TimeInterval = 30
    /// Whether a transient `URLError` thrown by an attempt retries. The scale-set
    /// long-poll turns this off: its caller treats a timeout as "poll again".
    var retriesNetworkErrors = true
    /// A value in 0..<1, the source of jitter (injectable for tests).
    var random: @Sendable () -> Double = { Double.random(in: 0..<1) }
    var sleep: Sleep = { seconds in try await Task.sleep(for: .seconds(seconds)) }

    /// What an attempt reports.
    enum Attempt<T> {
        case done(T)
        /// A transient failure: `error` is thrown if retries run out; `after`
        /// is the server-requested wait, if any.
        case retry(Error, after: TimeInterval?)
    }

    /// The decision for one HTTP response.
    enum Verdict: Equatable {
        case fail
        case retry(after: TimeInterval?)
    }

    // MARK: Running

    /// Runs `attempt` until it is done, fails with a non-retryable error, or
    /// retries are exhausted (then the last retry error is thrown). A
    /// transient `URLError` thrown by `attempt` retries too (unless
    /// `retriesNetworkErrors` is off); cancellation never does.
    func run<T>(_ attempt: () async throws -> Attempt<T>) async throws -> T {
        var retried = 0
        while true {
            let failure: Error
            let requested: TimeInterval?
            do {
                switch try await attempt() {
                case .done(let value): return value
                case .retry(let error, let after): (failure, requested) = (error, after)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error where retriesNetworkErrors && ForgeHTTP.isTransientNetworkError(error) {
                (failure, requested) = (error, nil)
            }
            guard retried < retries else { throw failure }
            retried += 1
            try await sleep(delay(forRetry: retried, requested: requested))
        }
    }

    /// How long retry number `n` (1-based) waits. A server-requested wait is
    /// honored (plus a little jitter so a fleet doesn't wake in lockstep);
    /// otherwise exponential backoff with "equal jitter" (half fixed, half random).
    func delay(forRetry n: Int, requested: TimeInterval?) -> TimeInterval {
        let jitter = min(max(random(), 0), 1)
        if let requested {
            let wait = min(max(requested, 0), maxDelay)
            return wait + jitter * min(1, max(0.05, wait * 0.1))
        }
        let backoff = min(maxDelay, baseDelay * pow(2, Double(max(n, 1) - 1)))
        return backoff * (0.5 + 0.5 * jitter)
    }

    // MARK: Classifying

    /// Whether (and how long) to wait before retrying `http`. The caller maps
    /// `.fail` to its own error.
    func verdict(for http: HTTPURLResponse, now: Date = Date()) -> Verdict {
        switch http.statusCode {
        case 429, 403:
            if let wait = Self.requestedWait(http, now: now) {
                return wait <= maxDelay ? .retry(after: wait) : .fail
            }
            return http.statusCode == 429 ? .retry(after: nil) : .fail
        case 500...599:
            if let wait = Self.requestedWait(http, now: now), wait <= maxDelay { return .retry(after: wait) }
            return .retry(after: nil)
        default:
            return .fail
        }
    }

    /// The wait a rate-limited response asks for: `Retry-After` (seconds or an
    /// HTTP date), else the time until `X-RateLimit-Reset` when the budget is
    /// spent (`X-RateLimit-Remaining: 0`). Nil when the response asks for none.
    static func requestedWait(_ http: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        if let raw = http.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) {
            if let seconds = TimeInterval(raw) { return max(0, seconds) }
            if let date = retryAfterDateFormatter.date(from: raw) { return max(0, date.timeIntervalSince(now)) }
        }
        if let reset = rateLimitReset(http) { return max(0, reset.timeIntervalSince(now)) }
        return nil
    }

    /// When an exhausted budget (`X-RateLimit-Remaining: 0`) refills; nil if
    /// the response doesn't say the budget is spent.
    static func rateLimitReset(_ http: HTTPURLResponse) -> Date? {
        guard http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
            let seconds = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static var retryAfterDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }
}
