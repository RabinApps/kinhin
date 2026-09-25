import Foundation

enum EngineError: LocalizedError {
    case registrationFailed(vm: String, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .registrationFailed(let vm, let stderr):
            return "runner registration failed on \(vm): \(stderr.prefix(300))"
        }
    }
}
