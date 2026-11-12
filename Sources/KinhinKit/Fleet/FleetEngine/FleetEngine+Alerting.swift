import Foundation

// FleetEngine — forwards the fleet's active problems to the alert webhook (`alerts:` in the config).
extension FleetEngine {
    /// How often the active problems are compared with what was last sent.
    static let alertInterval: Duration = .seconds(15)

    /// Builds the webhook sink of an `alerts:` config, reading its bearer token from the Keychain.
    static func makeAlertSink(
        _ alerts: KinhinConfig.AlertsConfig, http: any AlertHTTP = URLSessionAlertHTTP(),
        token: (String) throws -> String? = { try KeychainTokenStore.loadAlertsToken(account: $0) }
    ) throws -> WebhookSink {
        guard let raw = alerts.webhookURL else { throw AlertError.notHTTPS("") }
        var secret: String?
        if let name = alerts.headersKeychain {
            guard let found = try token(name) else { throw AlertError.missingToken(name) }
            secret = found
        }
        return WebhookSink(url: try WebhookSink.validate(raw), format: alerts.format, token: secret, http: http)
    }

    /// Starts the delivery loop (once) when `alerts.enabled`. A broken setup is logged and leaves alerting off:
    /// it must never stop the fleet.
    func startAlerting() {
        let alerts = config.alerts
        guard alerts.enabled else { return }
        let sink: WebhookSink
        do {
            sink = try Self.makeAlertSink(alerts)
        } catch {
            Log.warn("alerts", "alerts are off: \(error.localizedDescription)")
            return
        }
        let dispatcher = AlertDispatcher(
            sinks: [sink],
            policy: .init(
                minSeverity: alerts.minSeverity, cooldown: TimeInterval(alerts.cooldownSeconds),
                notifyOnResolve: alerts.notifyOnResolve))
        alertTask.withLock { task in
            guard task == nil else { return }
            task = Task { [weak self] in
                while !Task.isCancelled {
                    guard let active = await self?.activeAlerts() else { return }
                    await dispatcher.observe(active)
                    do {
                        try await Task.sleep(for: Self.alertInterval)
                    } catch {
                        return  // cancelled: the engine stopped
                    }
                }
            }
        }
    }

    func stopAlerting() {
        let task = alertTask.withLock { task -> Task<Void, Never>? in
            defer { task = nil }
            return task
        }
        task?.cancel()
    }

    private func activeAlerts() async -> [FleetStatusAlert] {
        await statusBox.get().alerts ?? []
    }
}
