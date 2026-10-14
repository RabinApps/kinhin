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

    /// Recent registration material (registration tokens, JIT configs, per-runner
    /// tokens), newest last. Minted for every spawn, so bounded: an evicted one
    /// has long since expired or been used.
    private static let registrationSecrets = Mutex<[String]>([])
    static let registrationSecretLimit = 256

    /// Shortest value worth masking: anything shorter would mangle ordinary text.
    private static let minimumSecretLength = 8

    static func registerSecret(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumSecretLength else { return }
        _ = knownSecrets.withLock { $0.insert(trimmed) }
    }

    /// Masks short-lived registration material, keeping only the newest
    /// `registrationSecretLimit` values so a long-running fleet does not grow
    /// the per-line scan without bound.
    static func registerRegistrationSecret(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumSecretLength else { return }
        registrationSecrets.withLock { secrets in
            secrets.removeAll { $0 == trimmed }
            secrets.append(trimmed)
            if secrets.count > registrationSecretLimit { secrets.removeFirst(secrets.count - registrationSecretLimit) }
        }
    }

    static func forgetAllSecretsForTesting() {
        knownSecrets.withLock { $0.removeAll() }
        registrationSecrets.withLock { $0.removeAll() }
    }

    /// A redaction rule plus the cheap literals any match must contain. The
    /// regex only runs on lines that contain one (`caseInsensitive` triggers
    /// are compared against the lowercased line).
    private struct Rule {
        let pattern: NSRegularExpression
        let template: String
        let triggers: [String]
        let caseInsensitive: Bool
    }

    private static let rules: [Rule] = {
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
        // Literals any match of the rule (same order as `specs`) must contain.
        let triggers: [(literals: [String], caseInsensitive: Bool)] = [
            (["ghp_", "gho_", "ghu_", "ghs_", "ghr_"], false),
            (["github_pat_"], false),
            (["glpat-", "glrt-", "glcbt-", "glptt-", "gloas-"], false),
            (["ATCTT", "ATATT"], false),
            (["bkua_"], false),
            (["private-token"], true),
            (["authorization"], true),
            (["--token", "--pat", "--password"], true),
            (["bearer"], true),
            (["ATBB"], false),
            (["GR1"], false),
            (["://"], false),
            (["token", "pat", "password", "secret", "apikey", "api_key"], true),
        ]
        precondition(triggers.count == specs.count, "every redaction rule needs its trigger literals")
        // The patterns are constants; a failure to compile is a programmer error.
        return zip(specs, triggers).map { spec, trigger in
            // Not ignored: a failure stops with preconditionFailure below.
            guard let regex = try? NSRegularExpression(pattern: spec.0) else {
                preconditionFailure("invalid redaction pattern: \(spec.0)")
            }
            return Rule(
                pattern: regex, template: spec.1, triggers: trigger.literals, caseInsensitive: trigger.caseInsensitive)
        }
    }()

    static func redact(_ text: String) -> String {
        var result = applyRules(to: text, gated: true)
        // Longest first, so a secret that contains another is masked whole.
        let secrets = knownSecrets.withLock { Array($0) } + registrationSecrets.withLock { $0 }
        for secret in secrets.sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: secret, with: mask)
        }
        return result
    }

    /// Every rule, with or without the literal pre-check (the tests prove the
    /// gate never changes a result).
    static func applyRules(to text: String, gated: Bool) -> String {
        var result = text
        var lowered: String?
        for rule in rules {
            if gated {
                let haystack: String
                if rule.caseInsensitive {
                    if lowered == nil { lowered = result.lowercased() }
                    haystack = lowered ?? result
                } else {
                    haystack = result
                }
                guard rule.triggers.contains(where: { haystack.contains($0) }) else { continue }
            }
            let range = NSRange(result.startIndex..., in: result)
            let replaced = rule.pattern.stringByReplacingMatches(in: result, range: range, withTemplate: rule.template)
            if replaced != result {
                result = replaced
                lowered = nil
            }
        }
        return result
    }
}
