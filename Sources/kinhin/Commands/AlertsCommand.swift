import Foundation
import KinhinKit

/// `kinhin alerts test` sends a test message through the configured webhook; `kinhin alerts set-token NAME` stores the
/// bearer token that `alerts.webhook.headers_keychain: NAME` refers to. Neither needs a daemon.
enum AlertsCommand {
    static let usage = "usage: kinhin alerts test | alerts set-token NAME [--token-stdin]"

    static func run(_ args: [String], subcommand: String?) async throws {
        switch subcommand {
        case "test": try await test(config: loadConfigLeniently().alerts)
        case "set-token": try setToken(args)
        default: fail(usage, exit: .usage)
        }
    }

    /// Sends the test alert; exit 3 when the webhook is not configured, 4 when delivery fails.
    static func test(
        config: KinhinConfig.AlertsConfig,
        send: (KinhinConfig.AlertsConfig) async throws -> String = {
            try await AlertDelivery.sendTest($0)
        }
    ) async throws {
        guard config.webhookURL != nil else {
            fail("alerts.webhook.url is not set in the config (see docs/alerts.md)", exit: .config)
        }
        do {
            print(try await send(config))
        } catch {
            fail(error.localizedDescription, exit: .runtime)
        }
        if !config.enabled { print("note: alerts.enabled is false, so the daemon sends nothing until you turn it on") }
    }

    /// Stores the token from `--token-stdin` or a hidden prompt under `alerts:NAME` in the Keychain.
    static func setToken(
        _ args: [String], read: () -> String? = { readSecretLine() },
        save: (String, String) throws -> Void = { try KeychainTokenStore.saveAlertsToken($0, account: $1) }
    ) throws {
        let operands = args.dropFirst().filter { !$0.hasPrefix("-") }
        guard operands.count == 2, let name = operands.last else { fail(usage, exit: .usage) }
        if !args.contains("--token-stdin") { print("Paste the token for '\(name)' (input hidden), then press Enter:") }
        guard let token = read()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            fail("no token entered", exit: .auth)
        }
        do {
            try save(token, name)
        } catch {
            fail(error.localizedDescription, exit: .auth)
        }
        print("alert token '\(name)' stored in Keychain; point alerts.webhook.headers_keychain at it")
    }
}
