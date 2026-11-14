import Foundation

// FleetEngine — forwards the fleet's active problems to the alert webhook (`alerts:` in the config).
extension FleetEngine {
    /// How often the active problems are compared with what was last sent.
    static let alertInterval: Duration = .seconds(15)

    /// Builds the sink of one webhook, reading its bearer token from the Keychain.
    static func makeAlertSink(
        _ webhook: KinhinConfig.AlertsConfig.Webhook, http: any AlertHTTP = URLSessionAlertHTTP(),
        token: (String) throws -> String? = { try KeychainTokenStore.loadAlertsToken(account: $0) }
    ) throws -> WebhookSink {
        var secret: String?
        if let name = webhook.headersKeychain {
            guard let found = try token(name) else { throw AlertError.missingToken(name) }
            secret = found
        }
        return WebhookSink(
            url: try WebhookSink.validate(webhook.url), format: webhook.format, token: secret, http: http)
    }

    /// The delivery policy of one webhook: its own overrides over the `alerts:` defaults.
    static func alertPolicy(
        _ webhook: KinhinConfig.AlertsConfig.Webhook, in alerts: KinhinConfig.AlertsConfig
    ) -> AlertDispatcher.Policy {
        AlertDispatcher.Policy(
            minSeverity: webhook.minSeverity ?? alerts.minSeverity, kinds: webhook.events,
            cooldown: TimeInterval(alerts.cooldownSeconds), notifyOnResolve: alerts.resolves(webhook))
    }

    /// How long to wait before trying again to build the sink of a webhook that could not be built
    /// (a token stored after the daemon started is then picked up without a restart).
    static let alertSetupRetry: TimeInterval = 60

    /// Starts the delivery loop (once) when `alerts.enabled`, with one dispatcher per webhook so each keeps its own
    /// filter, cooldown and delivery record. A broken webhook (a bad URL, a Keychain token not stored yet) is logged
    /// and retried every `alertSetupRetry` seconds without holding back the others; it must never stop the fleet.
    /// Does nothing once the engine has stopped, so a `stop()` racing `launch()` cannot leave a task behind.
    func startAlerting() {
        let alerts = config.alerts
        guard alerts.enabled, !alerts.webhooks.isEmpty else { return }
        alertTask.withLock { task in
            // `stop()` clears `running` before it takes this lock, so either the task installed here is cancelled
            // by that `stopAlerting()`, or this check sees the engine stopped.
            guard task == nil, running else { return }
            task = Task { [weak self] in
                var dispatchers: [String: AlertDispatcher] = [:]
                var lastSetupAttempt: [String: Date] = [:]
                var lastSetupError: [String: String] = [:]
                while !Task.isCancelled {
                    guard let active = await self?.activeAlerts() else { return }
                    for webhook in alerts.webhooks where dispatchers[webhook.name] == nil {
                        guard
                            Date().timeIntervalSince(lastSetupAttempt[webhook.name] ?? .distantPast)
                                >= Self.alertSetupRetry
                        else { continue }
                        lastSetupAttempt[webhook.name] = Date()
                        do {
                            dispatchers[webhook.name] = AlertDispatcher(
                                sinks: [try Self.makeAlertSink(webhook)], policy: Self.alertPolicy(webhook, in: alerts))
                            lastSetupError[webhook.name] = nil
                            Log.info("alerts", "alert webhook '\(webhook.name)' is on")
                        } catch {
                            let reason = error.localizedDescription
                            if reason != lastSetupError[webhook.name] {
                                Log.warn(
                                    "alerts", "alert webhook '\(webhook.name)' is off until this is fixed: \(reason)")
                                lastSetupError[webhook.name] = reason
                            }
                        }
                    }
                    for dispatcher in dispatchers.values { await dispatcher.observe(active) }
                    do {
                        try await Task.sleep(for: Self.alertInterval)
                    } catch {
                        return  // cancelled: the engine stopped
                    }
                }
            }
        }
    }

    /// Tells the webhooks that the fleet could not start (`prepareStart()` found no usable forge). The alert loop only
    /// runs for a started fleet, so without this the problem a person most needs to hear about would stay silent.
    /// Sent once, in the background: a slow endpoint must not delay the daemon's startup.
    func alertStartupFailure() async {
        let alerts = config.alerts
        guard alerts.enabled else { return }
        let message =
            await statusBox.get().alerts?.first { $0.source == "startup" }?.message ?? "the fleet could not start"
        Task.detached {
            await bestEffortAsync("alerts", "delivering the startup alert") {
                try await Self.sendStartupAlert(alerts, message: message)
            }
        }
    }

    /// Sends the startup alert to every webhook that wants it. A webhook that cannot be set up is skipped (and
    /// logged) so the others still hear about it; throws the last such error only when none could be reached.
    static func sendStartupAlert(
        _ alerts: KinhinConfig.AlertsConfig, message: String, http: any AlertHTTP = URLSessionAlertHTTP(),
        token: (String) throws -> String? = { try KeychainTokenStore.loadAlertsToken(account: $0) }
    ) async throws {
        let event = AlertEvent(
            source: "startup", severity: .critical, state: .firing, message: message,
            host: ProcessInfo.processInfo.hostName, timestamp: Date())
        var failure: Error?
        var delivered = false
        for webhook in alerts.webhooks
        where webhook.accepts(event, defaultMinSeverity: alerts.minSeverity) {
            do {
                try await makeAlertSink(webhook, http: http, token: token).send(event)
                delivered = true
            } catch {
                Log.warn(
                    "alerts", "delivering the startup alert to '\(webhook.name)' failed: \(error.localizedDescription)")
                failure = error
            }
        }
        if !delivered, let failure { throw failure }
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
