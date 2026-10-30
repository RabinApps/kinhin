import Foundation
import Security

/// The collector's CA bundle (`telemetry.ca_file`, `OTEL_EXPORTER_OTLP_CERTIFICATE`): parsing a PEM file into
/// certificates and judging a server's trust against them alone (the system roots are not consulted).
enum TelemetryCABundle {
    enum Problem: LocalizedError, Equatable {
        case notAbsolute(String)
        case unreadable(String, String)
        case noCertificates(String)
        case invalidCertificate(String)

        var errorDescription: String? {
            switch self {
            case .notAbsolute(let path): return "'\(path)' is not an absolute path (use /full/path or ~/path)"
            case .unreadable(let path, let reason): return "cannot read '\(path)': \(reason)"
            case .noCertificates(let path): return "'\(path)' contains no PEM certificate (-----BEGIN CERTIFICATE-----)"
            case .invalidCertificate(let path): return "'\(path)' contains a certificate that does not parse"
            }
        }
    }

    private static let begin = "-----BEGIN CERTIFICATE-----"
    private static let end = "-----END CERTIFICATE-----"

    /// `~` expanded; the result must be absolute.
    static func resolvedPath(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let path = (trimmed as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw Problem.notAbsolute(trimmed) }
        return path
    }

    /// Reads and parses the bundle at `raw` (a path with `~` allowed). Throws a `Problem` that names the path.
    static func load(path raw: String) throws -> [SecCertificate] {
        let path = try resolvedPath(raw)
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw Problem.unreadable(path, error.localizedDescription)
        }
        return try certificates(fromPEM: data, path: path)
    }

    /// Every `CERTIFICATE` block of a PEM bundle (other blocks, such as keys, are ignored).
    static func certificates(fromPEM data: Data, path: String = "the CA file") throws -> [SecCertificate] {
        let text = String(decoding: data, as: UTF8.self)
        var certificates: [SecCertificate] = []
        var rest = text[...]
        while let start = rest.range(of: begin),
            let stop = rest.range(of: end, range: start.upperBound..<rest.endIndex)
        {
            let body = rest[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
            guard let der = Data(base64Encoded: String(body)),
                let certificate = SecCertificateCreateWithData(nil, der as CFData)
            else { throw Problem.invalidCertificate(path) }
            certificates.append(certificate)
            rest = rest[stop.upperBound...]
        }
        guard !certificates.isEmpty else { throw Problem.noCertificates(path) }
        return certificates
    }

    /// Whether `trust` chains to one of `anchors` (and only those). `verifyDate` pins the clock (tests).
    static func evaluate(trust: SecTrust, anchors: [SecCertificate], verifyDate: Date? = nil) -> Bool {
        guard SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess else { return false }
        SecTrustSetAnchorCertificatesOnly(trust, true)
        if let verifyDate { SecTrustSetVerifyDate(trust, verifyDate as CFDate) }
        return SecTrustEvaluateWithError(trust, nil)
    }
}

/// A URLSession delegate that accepts a server only when its certificate chains to the configured CA bundle.
final class TelemetryTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let anchors: [SecCertificate]

    init(anchors: [SecCertificate]) {
        self.anchors = anchors
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if TelemetryCABundle.evaluate(trust: trust, anchors: anchors) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
