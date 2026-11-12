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
        guard let raw = alerts.webhookURL else { throw AlertError.notConfigured }
        var secret: String?
        if let name = alerts.headersKeychain {
            guard let found = try token(name) else { throw AlertError.missingToken(name) }
            secret = found
        }
        return WebhookSink(url: try WebhookSink.validate(raw), format: alerts.format, token: secret, http: http)
    }

    /// How long to wait before trying again to build the sink of an `alerts:` config that could not be built
    /// (a token stored after the daemon started is then picked up without a restart).
    static let alertSetupRetry: TimeInterval = 60

    /// Starts the delivery loop (once) when `alerts.enabled`. A broken setup (a bad URL, a Keychain token not stored
    /// yet) is logged and retried every `alertSetupRetry` seconds; it must never stop the fleet. Does nothing once the
    /// engine has stopped, so a `stop()` racing `launch()` cannot leave a task behind.
    func startAlerting() {
        let alerts = config.alerts
        guard alerts.enabled else { return }
        let policy = AlertDispatcher.Policy(
            minSeverity: alerts.minSeverity, cooldown: TimeInterval(alerts.cooldownSeconds),
            notifyOnResolve: alerts.notifyOnResolve)
        alertTask.withLock { task in
            // `stop()` clears `running` before it takes this lock, so either the task installed here is cancelled
            // by that `stopAlerting()`, or this check sees the engine stopped.
            guard task == nil, running else { return }
            task = Task { [weak self] in
                var dispatcher: AlertDispatcher?
                var lastSetupAttempt: Date?
                var lastSetupError: String?
                while !Task.isCancelled {
                    guard let active = await self?.activeAlerts() else { return }
                    if dispatcher == nil,
                        Date().timeIntervalSince(lastSetupAttempt ?? .distantPast) >= Self.alertSetupRetry
                    {
                        lastSetupAttempt = Date()
                        do {
                            dispatcher = AlertDispatcher(sinks: [try Self.makeAlertSink(alerts)], policy: policy)
                            lastSetupError = nil
                            Log.info("alerts", "alerts are on")
                        } catch {
                            let reason = error.localizedDescription
                            if reason != lastSetupError {
                                Log.warn("alerts", "alerts are off until this is fixed: \(reason)")
                                lastSetupError = reason
                            }
                        }
                    }
                    await dispatcher?.observe(active)
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
