import Foundation
import Synchronization

/// Masks credentials before a log line reaches stderr, the in-memory ring, or
/// `kinhin.log`. Errors and script fragments can carry tokens (forge API
/// bodies, registration commands); the log must never be a place to find one.
enum LogRedactor {
    static let mask = "[REDACTED]"

    /// Exact token values loaded from the Keychain or entered in this process.
    /// Patterns cannot catch unprefixed tokens (Gitea hex, Azure base32), so any
    /// occurrence of a known value is masked literally.
    private static let knownSecrets = Mutex<Set<String>>([])

    /// Shortest value worth masking: anything shorter would mangle ordinary text.
    private static let minimumSecretLength = 8

    static func registerSecret(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumSecretLength else { return }
        _ = knownSecrets.withLock { $0.insert(trimmed) }
    }

    static func forgetAllSecretsForTesting() {
        knownSecrets.withLock { $0.removeAll() }
    }

    private static let rules: [(pattern: NSRegularExpression, template: String)] = {
        let specs: [(String, String)] = [
            // GitHub token families: ghp_, gho_, ghu_, ghs_, ghr_ and fine-grained PATs.
            (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, mask),
            (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, mask),
            // GitLab personal/runner tokens, Bitbucket (Atlassian) tokens, Buildkite API tokens.
            (#"\bgl(?:pat|rt|cbt|ptt|oas)-[A-Za-z0-9_-]{10,}"#, mask),
            (#"\bAT(?:CTT|ATT)[A-Za-z0-9_=.-]{20,}"#, mask),
            (#"\bbkua_[A-Za-z0-9]{20,}"#, mask),
            // GitLab's header-style credential.
            (#"(?i)(private-token:?\s*)[^\s'"]+"#, "$1" + mask),
            // Authorization headers (token/Bearer/Basic schemes).
            (#"(?i)(authorization:?\s*(?:token|bearer|basic)\s+)[^\s'"]+"#, "$1" + mask),
            // Runner registration / CLI flags: --token abc, --token 'abc', --token=abc.
            (#"(?i)(--(?:token|pat|password)[\s=]+)(?:'[^']*'|"[^"]*"|[^\s'"]+)"#, "$1" + mask),
            // Bearer credentials outside an Authorization header.
            (#"(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{16,}"#, "$1" + mask),
            // Bitbucket app passwords and GitLab legacy runner registration tokens.
            (#"\bATBB[A-Za-z0-9]{20,}"#, mask),
            (#"\bGR1[0-9a-f]{20,}"#, mask),
            // Credentials embedded in a URL: scheme://user:secret@host.
            (#"(://[^/\s:@]+:)[^@\s/]+(@)"#, "$1" + mask + "$2"),
            // key=value / key: value style secrets, including JSON-quoted keys
            // ("token": "x") and environment-style names (GITHUB_TOKEN=x).
            (
                #"(?i)(\b(?:[A-Za-z0-9]+[_-])*(?:access_?token|api_?key|password|secret|token|pat)["']?\s*[=:]\s*)(?:'[^']*'|"[^"]*"|[^\s,;'"}]+)"#,
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
        for secret in knownSecrets.withLock({ $0 }) {
            result = result.replacingOccurrences(of: secret, with: mask)
        }
        return result
    }
}
