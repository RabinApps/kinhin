import Foundation
import Synchronization

// Every machine-readable document the CLI prints goes through here, so the
// encoder is configured once: pretty-printed, sorted keys. A caller that has
// `Date`s in its document opts into ISO-8601; one that always encoded dates
// as numbers (the fleet status) keeps the default so its contract is stable.

enum CLIJSON {
    static func encoder(dates: JSONEncoder.DateEncodingStrategy = .deferredToDate) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = dates
        return encoder
    }

    static func data<T: Encodable>(_ value: T, dates: JSONEncoder.DateEncodingStrategy = .deferredToDate) throws
        -> Data
    {
        try encoder(dates: dates).encode(value)
    }

    static func string<T: Encodable>(_ value: T, dates: JSONEncoder.DateEncodingStrategy = .deferredToDate) throws
        -> String
    {
        String(decoding: try data(value, dates: dates), as: UTF8.self)
    }
}

/// Prints `value` as the command's JSON document on stdout and returns the
/// bytes it printed (so tests can decode the emitted contract).
@discardableResult
func emitJSON<T: Encodable>(_ value: T, dates: JSONEncoder.DateEncodingStrategy = .deferredToDate) throws -> Data {
    let data = try CLIJSON.data(value, dates: dates)
    print(String(decoding: data, as: UTF8.self))
    return data
}

// MARK: - Errors under --json

/// What a failing command prints on stdout when `--json` was asked for:
/// `{"code": 2, "error": "…"}`. The exit code is the same one the process ends with.
struct ErrorDocument: Codable, Equatable {
    var error: String
    var code: Int32
}

/// Process-wide switch for how `fail` reports: prose on stderr, or (when the
/// command line carried `--json`) an `ErrorDocument` on stdout so a script
/// parsing stdout always gets JSON.
enum ErrorReporter {
    private static let jsonMode = Mutex(false)

    static func useJSON(_ enabled: Bool) {
        jsonMode.withLock { $0 = enabled }
    }

    static var isJSON: Bool { jsonMode.withLock { $0 } }

    /// The text for one failure, split by stream (pure, for tests).
    static func render(_ message: String, code: CLIExit, json: Bool) -> (stdout: String?, stderr: String?) {
        guard json else { return (nil, "kinhin: \(message)") }
        let document = ErrorDocument(error: message, code: code.rawValue)
        // Encoding two plain fields cannot fail; the fallback still carries the exit code.
        return ((try? CLIJSON.string(document)) ?? "{\"code\":\(code.rawValue)}", nil)
    }

    static func report(_ message: String, code: CLIExit) {
        let out = render(message, code: code, json: isJSON)
        if let stdout = out.stdout { print(stdout) }
        if let stderr = out.stderr { printError(stderr) }
    }
}
