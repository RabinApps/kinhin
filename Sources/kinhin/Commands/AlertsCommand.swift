import Foundation
import KinhinKit

/// `kinhin alerts test [--webhook NAME]` sends a test message through the configured webhooks;
/// `kinhin alerts set-token NAME` stores the bearer token that a webhook's `headers_keychain: NAME` refers to.
/// Neither needs a daemon.
enum AlertsCommand {
    static let usage = "usage: kinhin alerts test [--webhook NAME] | alerts set-token NAME [--token-stdin]"

    static func run(_ args: [String], subcommand: String?) async throws {
        switch subcommand {
        case "test": try await test(config: loadConfigLeniently().alerts, webhook: flag("--webhook", in: args))
        case "set-token": try setToken(args)
        default: fail(usage, exit: .usage)
        }
    }

    /// Sends the test alert to every webhook (or `webhook`); exit 3 when none is configured or the name is unknown,
    /// 4 when a delivery fails. Each webhook's outcome is printed.
    static func test(
        config: KinhinConfig.AlertsConfig, webhook: String? = nil,
        send: (KinhinConfig.AlertsConfig, String?) async throws -> [String] = {
            try await AlertDelivery.sendTest($0, webhook: $1)
        }
    ) async throws {
        guard !config.webhooks.isEmpty else {
            fail("no alert webhook is configured (alerts.webhooks in the config; see docs/alerts.md)", exit: .config)
        }
        if let webhook, config.webhook(named: webhook) == nil {
            let names = config.webhooks.map(\.name).joined(separator: ", ")
            fail("no alert webhook named '\(webhook)' (configured: \(names))", exit: .config)
        }
        do {
            for line in try await send(config, webhook) { print(line) }
        } catch is CancellationError {
            throw CancellationError()  // the CLI's exit-130 handler reports it
        } catch let failure as AlertDeliveryFailure {
            fail(failure.lines.joined(separator: "\n"), exit: .runtime)
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
        print("alert token '\(name)' stored in Keychain; point the webhook's headers_keychain at it")
    }
}
