import Foundation

/// Masks credentials before a log line reaches stderr, the in-memory ring, or
/// `kinhin.log`. Errors and script fragments can carry tokens (forge API
/// bodies, registration commands); the log must never be a place to find one.
enum LogRedactor {
    static let mask = "[REDACTED]"

    private static let rules: [(pattern: NSRegularExpression, template: String)] = {
        let specs: [(String, String)] = [
            // GitHub token families: ghp_, gho_, ghu_, ghs_, ghr_ and fine-grained PATs.
            (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, mask),
            (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, mask),
            // Authorization headers (token/Bearer/Basic schemes).
            (#"(?i)(authorization:?\s*(?:token|bearer|basic)\s+)[^\s'"]+"#, "$1" + mask),
            // Runner registration / CLI flags: --token abc, --token 'abc', --token=abc.
            (#"(?i)(--(?:token|pat|password)[\s=]+)(?:'[^']*'|"[^"]*"|[^\s'"]+)"#, "$1" + mask),
            // key=value / key: value style secrets.
            (
                #"(?i)\b((?:access_?token|api_?key|password|secret|token|pat)\s*[=:]\s*)(?:'[^']*'|"[^"]*"|[^\s,;'"]+)"#,
                "$1" + mask
            ),
        ]
        // The patterns are constants; a failure to compile is a programmer error.
        return specs.map { spec in
            guard let regex = try? NSRegularExpression(pattern: spec.0) else {
                preconditionFailure("invalid redaction pattern: \(spec.0)")
            }
            return (regex, spec.1)
        }
    }()

    static func redact(_ text: String) -> String {
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.pattern.stringByReplacingMatches(in: result, range: range, withTemplate: rule.template)
        }
        return result
    }
}
