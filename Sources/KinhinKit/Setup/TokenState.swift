import Foundation

/// What the setup checklist knows about one forge token. `unreadable` is kept
/// apart from `missing`: a locked or denied Keychain must not tell the user to
/// enter a token they have already saved.
enum TokenState: Equatable, Sendable {
    case stored
    case missing
    case unreadable(String)

    /// Reads the token through `body`, mapping a thrown Keychain error to `.unreadable`.
    init(reading body: () throws -> String?) {
        do {
            self = try body() != nil ? .stored : .missing
        } catch {
            self = .unreadable(error.localizedDescription)
        }
    }
}
