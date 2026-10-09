import Foundation

/// Bakes the runner image a lane needs, once per test process.
///
/// `kinhin image prepare` installs a forge's runner agent only when a token for that forge is stored, so the baker
/// hands each account a placeholder token (the agent downloads do not need a real one). The image is named per lane
/// and forge set so lanes never share or clobber one, and it is removed again by `ImageBaker.removeAll()`.
public actor ImageBaker {
    public static let shared = ImageBaker()
    private var baked: [String: String] = [:]
    private var inFlight: [String: Task<String, Error>] = [:]

    /// The image tag for `runtime` carrying the agents of `accounts`' forges.
    public func ensure(_ runtime: RuntimeKind, accounts: [FleetConfig.Account]) async throws -> String {
        let forges = Set(accounts.map(\.forge)).sorted()
        let key = "\(runtime.rawValue)-\(forges.joined(separator: "+"))"
        if let tag = baked[key] { return tag }
        if let task = inFlight[key] { return try await task.value }
        let tag = "ke2e-\(key.replacingOccurrences(of: "+", with: "-"))-\(E2E.randomID())"
        let task = Task { try await Self.bake(runtime, accounts: accounts, tag: tag) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let result = try await task.value
        baked[key] = result
        return result
    }

    private static func bake(_ runtime: RuntimeKind, accounts: [FleetConfig.Account], tag: String) async throws
        -> String
    {
        let sandbox = try Sandbox()
        defer { sandbox.dispose() }
        for account in accounts { sandbox.setToken("e2e-placeholder-token", account: account.name) }
        var config = FleetConfig(accounts: accounts, runtime: runtime, image: tag)
        config.minRunners = 0
        try sandbox.writeConfig(config.yaml())
        guard runtime != .tartMacOS else { return try await bakeTart(sandbox: sandbox, tag: tag) }
        let result = try await sandbox.kinhin(
            ["image", "prepare"] + runtime.imageFlags + ["--target", tag], timeout: 1200)
        guard result.ok else {
            throw E2EError.failed(
                "image prepare for \(runtime) failed (\(result.status)):\n\(result.output.suffix(2000))")
        }
        return tag
    }

    private static func bakeTart(sandbox: Sandbox, tag: String) async throws -> String {
        guard let base = E2E.flag("KINHIN_E2E_TART_BASE") else {
            throw E2EError.unavailable(RuntimeKind.tartMacOS.unavailableReason)
        }
        // `base_image` is what prepare starts from (a local tart VM name works); the result is `image: tag`.
        var config = try String(contentsOf: sandbox.configURL, encoding: .utf8)
        config += "base_image: \"\(base)\"\n"
        try sandbox.writeConfig(config)
        let result = try await sandbox.kinhin(["image", "prepare"], timeout: 3600)
        guard result.ok else {
            throw E2EError.failed("tart image prepare failed (\(result.status)):\n\(result.output.suffix(2000))")
        }
        return tag
    }

    /// Removes every image this process baked.
    public func removeAll() async {
        for (key, tag) in baked {
            if key.hasPrefix(RuntimeKind.docker.rawValue) {
                _ = try? await Shell.run("docker", ["rmi", "-f", tag], timeout: 120)
            } else if key.hasPrefix(RuntimeKind.appleContainer.rawValue) {
                _ = try? await Shell.run("container", ["image", "delete", tag], timeout: 120)
            } else {
                _ = try? await Shell.run("tart", ["delete", tag], timeout: 300)
            }
        }
        baked.removeAll()
    }
}
