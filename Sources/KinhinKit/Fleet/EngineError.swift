import Foundation

enum EngineError: LocalizedError {
    case registrationFailed(vm: String, stderr: String)
    /// An account couldn't be attached (no instance URL, failed verification).
    case accountUnverified(String)

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let vm, let stderr):
            return "runner registration failed on \(vm): \(stderr.prefix(300))"
        case .accountUnverified(let reason):
            return reason
        }
    }
}
