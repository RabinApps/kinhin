import Foundation

// MARK: - Telemetry: sampling, log level, credentials, TLS, persistence

extension ConfigLoader {
    /// Longest accepted `telemetry.headers_keychain` account name.
    static let telemetryKeychainNameLimit = 128

    /// Validates the `telemetry:` keys that shape what leaves the machine, naming the key in every error.
    static func parseTelemetryExporterKeys(
        _ partial: PartialConfig.PartialTelemetry, into telemetry: inout KinhinConfig.TelemetryConfig
    ) throws {
        if let ratio = partial.samplingRatio {
            guard ratio.isFinite, (0...1).contains(ratio) else {
                throw ConfigError.invalid("telemetry.sampling_ratio must be between 0 and 1, got \(ratio)")
            }
            telemetry.samplingRatio = ratio
        }
        if let raw = partial.logLevel {
            guard let level = Log.Level(rawValue: raw) else {
                throw ConfigError.invalid("telemetry.log_level must be debug, info, warn or error, got '\(raw)'")
            }
            telemetry.logLevel = level
        }
        if let raw = partial.headersKeychain {
            let name = raw.trimmingCharacters(in: .whitespaces)
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            guard !name.isEmpty, name.count <= telemetryKeychainNameLimit,
                name.unicodeScalars.allSatisfy({ allowed.contains($0) })
            else {
                throw ConfigError.invalid(
                    "telemetry.headers_keychain must be a Keychain account name of letters, digits, '.', '_' or '-' "
                        + "(at most \(telemetryKeychainNameLimit) characters), got '\(raw)'")
            }
            telemetry.headersKeychain = name
        }
        if let raw = partial.caFile {
            do {
                // Parsed here so a bad file fails the config load, not the first export.
                _ = try TelemetryCABundle.load(path: raw)
                telemetry.caFile = try TelemetryCABundle.resolvedPath(raw)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                throw ConfigError.invalid("telemetry.ca_file: \(reason)")
            }
        }
        if let persist = partial.persist { telemetry.persist = persist }
    }
}
