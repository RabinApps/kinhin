import Foundation
import KinhinKit
import Observation

/// State and actions behind the Telemetry card (Advanced → App): whether OpenTelemetry export is on, where each
/// signal goes, the Prometheus address and the last export problem, plus the on/off switch and the Prometheus
/// address. The numbers come from whoever owns the exporters (`FleetController.readTelemetry`): this app when it runs
/// the engine itself, otherwise the daemon. The card never starts exporters and never shows header values or
/// credentials (`TelemetryStatus` carries none; endpoints arrive with credentials and query already removed).
///
/// Edits go through `TelemetryConfigEditor` (only the edited key's line changes, validated by `ConfigLoader`), then
/// `onChanged` pushes the file to the engine or daemon, which applies telemetry in place without a restart.
@MainActor
@Observable
final class TelemetryModel: ConfigFormModel {
    /// The config file this card edits (tests point it at a scratch file).
    @ObservationIgnored var configURL: URL = Paths.config
    /// Fired after a successful config write; the app pushes the edit to the fleet.
    @ObservationIgnored var onChanged: (() -> Void)?
    /// Who owns the exporters and what they are doing. The app wires `FleetController.readTelemetry`.
    @ObservationIgnored var read: () async -> TelemetryReading = { .noFleet }
    /// How long after a save to wait before asking again: the config push is debounced, then the owner applies it.
    @ObservationIgnored var settle: Duration = .seconds(2)
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// The file's `telemetry.enabled` (what the switch shows). Nil until loaded or when the file can't be read.
    private(set) var configEnabled: Bool?
    private(set) var reading: TelemetryReading = .noFleet
    /// The text field's content; the file's value until the user types.
    var listenDraft = ""
    /// The outcome of the last load or save.
    private(set) var result = StatusLine(text: "")
    /// A save is waiting for the owner to apply it (the status is read again once it settles).
    private(set) var applying = false
    @ObservationIgnored private(set) var loads = 0
    @ObservationIgnored private var savedListen: String?
    @ObservationIgnored private var configUnreadable = false

    // MARK: - Loading

    /// Reads the file and asks the owner, off the call's thread of control (the daemon call blocks on a socket).
    func reload() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.load() }
    }

    func load() async {
        loads += 1
        loadConfig()
        let answer = await read()
        guard !Task.isCancelled else { return }
        reading = answer
    }

    private func loadConfig() {
        do {
            let snapshot = try TelemetryConfigEditor.snapshot(in: ConfigStore.text(at: configURL))
            configEnabled = snapshot.enabled
            savedListen = snapshot.prometheusListen
            listenDraft = snapshot.prometheusListen ?? ""
            if configUnreadable { result = StatusLine(text: "") }
            configUnreadable = false
        } catch {
            configEnabled = nil
            configUnreadable = true
            result = .unreadableConfig(error)
        }
    }

    // MARK: - Editing

    /// The switch. Writes `telemetry.enabled`, tells the owner, and reads the outcome once it has had time to apply.
    func setEnabled(_ on: Bool) async {
        guard await save(.enabled(on)) else { return }
        result = StatusLine(
            text: on
                ? String(
                    localized: "Telemetry turned on in config.yaml.", bundle: .l10n,
                    comment: "Settings → App → Telemetry status after the switch is turned on")
                : String(
                    localized: "Telemetry turned off in config.yaml.", bundle: .l10n,
                    comment: "Settings → App → Telemetry status after the switch is turned off"), style: .ok)
        await settleAndRead()
    }

    /// Saves the Prometheus address field: empty removes the listener. A bad address is refused and shown.
    func applyListen() async {
        let typed = listenDraft.trimmingCharacters(in: .whitespaces)
        let address: String? = typed.isEmpty ? nil : typed
        guard address != savedListen else { return }
        guard await save(.prometheusListen(address)) else { return }
        result = StatusLine(
            text: address == nil
                ? String(
                    localized: "Prometheus endpoint removed from config.yaml.", bundle: .l10n,
                    comment: "Settings → App → Telemetry status after the Prometheus address is cleared")
                : String(
                    localized: "Prometheus address saved in config.yaml.", bundle: .l10n,
                    comment: "Settings → App → Telemetry status after the Prometheus address is saved"), style: .ok)
        await settleAndRead()
    }

    /// Writes one field; nil (with the reason shown) when the editor refused it and nothing was written.
    private func save(_ field: TelemetryConfigEditor.Field) async -> Bool {
        let url = configURL
        do {
            // Off the main actor: the editor reads, validates and writes the file.
            try await Task.detached { try TelemetryConfigEditor.apply(field, to: url) }.value
            loadConfig()
            onChanged?()
            return true
        } catch {
            result = .notSaved(error)
            return false
        }
    }

    private func settleAndRead() async {
        applying = true
        defer { applying = false }
        if settle > .zero { try? await Task.sleep(for: settle) }  // cancelled only by a newer reload
        await load()
    }

    // MARK: - What the card says

    /// The status block's headline and its tone.
    var headline: StatusLine {
        switch reading {
        case .inProcess(let status), .daemon(let status):
            if status.enabled {
                let signals = status.signals.formatted(.list(type: .and))
                return StatusLine(
                    text: String(
                        localized: "Telemetry is on, exporting \(signals).", bundle: .l10n,
                        comment:
                            "Settings → App → Telemetry status; %@ is a list of signal names such as metrics, traces"
                    ), style: .ok)
            }
            if configEnabled == true {
                return StatusLine(
                    text: String(
                        localized:
                            "Telemetry is turned on in config.yaml but is not running. OTEL_SDK_DISABLED may be set, or the exporters could not start; see the logs.",
                        bundle: .l10n,
                        comment:
                            "Settings → App → Telemetry status; OTEL_SDK_DISABLED is an environment variable and stays verbatim"
                    ), style: .warn)
            }
            return StatusLine(
                text: String(
                    localized: "Telemetry is off.", bundle: .l10n, comment: "Settings → App → Telemetry status"))
        case .daemonUnreachable(let reason):
            return StatusLine(
                text: String(
                    localized: "Couldn't read the daemon's telemetry status: \(reason)", bundle: .l10n,
                    comment: "Settings → App → Telemetry status; %@ is the reason"), style: .warn)
        case .noFleet:
            if configEnabled == true {
                return StatusLine(
                    text: String(
                        localized: "Telemetry is turned on in config.yaml and starts with the fleet.", bundle: .l10n,
                        comment: "Settings → App → Telemetry status while no fleet is running"))
            }
            return StatusLine(
                text: String(
                    localized: "Telemetry is off.", bundle: .l10n, comment: "Settings → App → Telemetry status"))
        }
    }

    /// The exporting process's status, when it answered and telemetry runs.
    var runningStatus: TelemetryStatus? {
        switch reading {
        case .inProcess(let status), .daemon(let status): return status.enabled ? status : nil
        case .daemonUnreachable, .noFleet: return nil
        }
    }

    /// Who exports: this app or the daemon (nil when nothing runs).
    var ownerLine: String? {
        guard runningStatus != nil else { return nil }
        if case .daemon = reading {
            return String(
                localized: "Exported by the daemon.", bundle: .l10n,
                comment: "Settings → App → Telemetry: which process sends the data")
        }
        return String(
            localized: "Exported by this app.", bundle: .l10n,
            comment: "Settings → App → Telemetry: which process sends the data")
    }

    /// One row per signal: its name and the collector URL it goes to (credentials and query already removed).
    var destinations: [(signal: String, endpoint: String)] {
        guard let status = runningStatus else { return [] }
        return status.signals.map { ($0, status.endpoints[$0] ?? "") }
    }

    /// The scrape URL of the local Prometheus endpoint, when one is bound.
    var prometheusURL: String? {
        runningStatus?.prometheus.map { "http://\($0)/metrics" }
    }

    /// The last export problem, with how long ago and how many so far; nil when none was reported.
    var problem: StatusLine? {
        guard let status = runningStatus else { return nil }
        guard let at = status.lastFailureAt, let message = status.lastFailure else {
            return StatusLine(
                text: String(
                    localized: "No export problems reported.", bundle: .l10n,
                    comment: "Settings → App → Telemetry status"), style: .ok)
        }
        let when = AppFormat.relative(at, to: now())
        let count = status.exportFailures
        if status.hasRecentFailure(now: now()) {
            return StatusLine(
                text: String(
                    localized: "Export problem \(when) (\(count) so far): \(message)", bundle: .l10n,
                    comment:
                        "Settings → App → Telemetry status; the time it happened, a number of problems so far, then the redacted problem text from the exporter (English)"
                ), style: .error)
        }
        return StatusLine(
            text: String(
                localized: "Last export problem \(when) (\(count) so far): \(message)", bundle: .l10n,
                comment:
                    "Settings → App → Telemetry status; the time it happened, a number of problems so far, then the redacted problem text from the exporter (English)"
            ), style: .warn)
    }
}
