import Foundation
import KinhinKit

/// The one assembly of the fleet's status text, shared by the Fleet screen and the status-bar menu so the two can't
/// drift: the state word, the counters and detail lines from `FleetStatusFormatter`, the engine mode, the stale-daemon
/// warning and the app-side problems. Pure: it takes a snapshot (`Input`) and renders nothing itself.
struct FleetStatusPresenter: Equatable {
    /// What the fleet is doing, as the header chip says it.
    enum State: Equatable {
        case needsSetup, checking, unreachable, stopped, running, paused, starting, stopping
    }

    /// Everything the text is built from; `FleetController.statusPresenter(...)` fills it.
    struct Input: Equatable {
        var status: FleetStatus?
        /// Whether a fleet service (engine or daemon) exists; false while setup is unfinished.
        var hasService = true
        /// Why the last poll failed; nil while polls succeed.
        var unreachableReason: String?
        /// "in-process engine" / "background daemon"; nil when no backend is attached.
        var mode: String?
        /// A LaunchAgent whose binary is gone (a warning line); nil when there is none.
        var staleDaemon: String?
        /// App-side failures (launch, config push), in a stable order.
        var problems: [String] = []
        /// A start/stop command in flight.
        var pending: FleetAction?
    }

    let state: State
    /// The header chip: "Running", "Paused", "Needs setup", "Stopping…".
    let stateWord: String
    let stateStyle: StatusStyle
    /// The summary lines: the counters first ("Running — queue 3 · …"), then queue age, host load, queued and running
    /// work. One entry per line, without the leading indent of the multi-line text.
    let summaryLines: [String]
    let mode: String?
    let staleDaemon: String?
    let problems: [String]
    private let pending: FleetAction?

    init(_ input: Input) {
        pending = input.pending
        mode = input.mode
        staleDaemon = input.staleDaemon
        problems = input.problems

        let base: String
        if let status = input.status {
            base = FleetStatusFormatter.summary(status)
        } else if !input.hasService {
            base = FleetStatusFormatter.summary(nil)  // setup unfinished
        } else if let reason = input.unreachableReason {
            base = String(
                localized: "Fleet not responding — \(reason)", bundle: .l10n,
                comment: "Status line when the fleet can't be reached; %@ is the reason")
        } else {
            base = String(
                localized: "Checking the fleet…", bundle: .l10n, comment: "Status line while the first poll is pending")
        }
        summaryLines = base.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }

        switch input.pending {
        case .start?: state = .starting
        case .stop?: state = .stopping
        default:
            if let status = input.status {
                state = !status.running ? .stopped : (status.paused ? .paused : .running)
            } else if !input.hasService {
                state = .needsSetup
            } else if input.unreachableReason != nil {
                state = .unreachable
            } else {
                state = .checking
            }
        }
        (stateWord, stateStyle) = Self.chip(for: state)
    }

    // MARK: - Text

    /// The first summary line: the counters, or the reason there are none.
    var headline: String { summaryLines.first ?? "" }

    /// The summary lines after the headline.
    var detailLines: [String] { Array(summaryLines.dropFirst()) }

    /// The multi-line state text: summary, then the engine mode and the stale-daemon warning, indented. What
    /// `FleetController.statusLine` returns.
    var stateText: String {
        var text = summaryLines.enumerated().map { $0.offset == 0 ? $0.element : "  \($0.element)" }
            .joined(separator: "\n")
        if let mode { text += "\n  \(mode)" }
        if let staleDaemon { text += "\n  ⚠ \(staleDaemon)" }
        return text
    }

    /// The status-bar menu's text: "Starting…"/"Stopping…" while a command runs (the polled state is stale until it
    /// completes), otherwise the state text, with each app-side problem under it.
    var menuText: String {
        switch pending {
        case .start?:
            return String(
                localized: "Starting…", bundle: .l10n, comment: "Status line while a start command runs")
        case .stop?:
            return String(
                localized: "Stopping…", bundle: .l10n, comment: "Status line while a stop command runs")
        default:
            return problems.reduce(stateText) { $0 + "\n  ⚠ \($1)" }
        }
    }

    /// Problem and warning lines for the Fleet screen's banners: each app-side failure as an error, then the
    /// stale-daemon warning.
    var banners: [StatusLine] {
        var lines = problems.map { StatusLine(text: $0, style: .error) }
        if let staleDaemon { lines.append(StatusLine(text: staleDaemon, style: .warn)) }
        return lines
    }

    // MARK: - Chip

    private static func chip(for state: State) -> (String, StatusStyle) {
        switch state {
        case .running:
            return (String(localized: "Running", bundle: .l10n, comment: "Fleet state chip"), .ok)
        case .paused:
            return (String(localized: "Paused", bundle: .l10n, comment: "Fleet state chip"), .warn)
        case .stopped:
            return (String(localized: "Stopped", bundle: .l10n, comment: "Fleet state chip"), .secondary)
        case .needsSetup:
            return (String(localized: "Needs setup", bundle: .l10n, comment: "Fleet state chip"), .warn)
        case .unreachable:
            return (String(localized: "Not responding", bundle: .l10n, comment: "Fleet state chip"), .error)
        case .checking:
            return (String(localized: "Checking…", bundle: .l10n, comment: "Fleet state chip"), .secondary)
        case .starting:
            return (String(localized: "Starting…", bundle: .l10n, comment: "Fleet state chip"), .warn)
        case .stopping:
            return (String(localized: "Stopping…", bundle: .l10n, comment: "Fleet state chip"), .warn)
        }
    }
}
