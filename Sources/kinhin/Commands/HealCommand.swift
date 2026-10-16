import Foundation
import KinhinKit

/// `kinhin heal`: what the healing agent fixed, what waits for approval and
/// what only the user can fix; `heal approve ID` and `heal dismiss ID` act on
/// one entry. Talks to the daemon (the agent runs with the fleet). Exits 0
/// when nothing waits on the user, 1 when something does or no daemon runs.
enum HealCommand {
    static let usage = "usage: kinhin heal [--json] | kinhin heal approve ID | kinhin heal dismiss ID"
    static let noDaemon = "no daemon running; the healing agent runs with the daemon (kinhin daemon install)"

    /// The `--json` document.
    struct Document: Codable, Equatable {
        /// False when no daemon answered (everything else is then empty).
        var daemon: Bool
        var enabled: Bool
        var automatic: Bool
        var advisor: String?
        var pending: [HealingEvent]
        var surfaced: [HealingEvent]
        /// The journal, newest first.
        var events: [HealingEvent]
        var message: String?

        init(_ snapshot: HealingSnapshot) {
            daemon = true
            enabled = snapshot.enabled
            automatic = snapshot.automatic
            advisor = snapshot.advisor
            pending = snapshot.pending
            surfaced = snapshot.surfaced
            events = snapshot.events
        }

        /// No daemon: the history the last one left, nothing open.
        init(noDaemon message: String, stored: HealingSnapshot) {
            daemon = false
            enabled = stored.enabled
            automatic = stored.automatic
            pending = []
            surfaced = []
            events = stored.events
            self.message = message
        }
    }

    static func run(_ args: [String], subcommand: String?) async throws {
        switch subcommand {
        case "approve", "dismiss":
            try await decide(args, approve: subcommand == "approve")
        default:
            try await show(args)
        }
    }

    // MARK: - Show

    /// The `--json` document without printing anything (the MCP `heal_status` tool).
    static func document(backend: (any FleetServing)? = nil) async throws -> Document {
        guard let backend = await backendOrNil(backend) else {
            return Document(noDaemon: noDaemon, stored: HealingSnapshot.stored(policy: loadConfigLeniently().healing))
        }
        return Document(try await backend.healingStatus())
    }

    static func show(_ args: [String], backend: (any FleetServing)? = nil) async throws {
        let json = args.contains("--json")
        let quiet = args.contains("--quiet") || args.contains("-q")
        guard let backend = await backendOrNil(backend) else {
            let stored = HealingSnapshot.stored(policy: loadConfigLeniently().healing)
            if json, !quiet { try emitJSON(Document(noDaemon: noDaemon, stored: stored), dates: .iso8601) }
            if !json, !quiet {
                print(noDaemon)
                let history = stored.events.prefix(10)
                if !history.isEmpty {
                    print("")
                    print("last run:")
                    for event in history { print(line(event, now: Date())) }
                }
            }
            ExitRule.finish(healthy: false)
            return
        }
        let snapshot: HealingSnapshot
        do {
            snapshot = try await backend.healingStatus()
        } catch {
            fail(error.localizedDescription, exit: .runtime)
        }
        if !quiet {
            if json { try emitJSON(Document(snapshot), dates: .iso8601) } else { print(render(snapshot)) }
        }
        ExitRule.finish(healthy: snapshot.healthy)
    }

    /// The human view: policy, what waits on the user, then recent history.
    static func render(_ snapshot: HealingSnapshot, now: Date = Date(), recent: Int = 10) -> String {
        guard snapshot.enabled else { return "healing is off (healing.enabled: false in config.yaml)" }
        var lines: [String] = []
        let mode = snapshot.automatic ? "safe fixes run on their own" : "every fix waits for approval"
        let advisor = snapshot.advisor.map { "; \($0) advises on the rest" } ?? "; rules only"
        lines.append("healing: \(mode)\(advisor)")
        if !snapshot.pending.isEmpty {
            lines.append("")
            lines.append("waiting for approval (kinhin heal approve ID):")
            for event in snapshot.pending { lines.append(line(event)) }
        }
        if !snapshot.surfaced.isEmpty {
            lines.append("")
            lines.append("needs you (kinhin heal dismiss ID once handled):")
            for event in snapshot.surfaced { lines.append(line(event)) }
        }
        let history = snapshot.events.filter { !$0.isOpen }.prefix(recent)
        if !history.isEmpty {
            lines.append("")
            lines.append("recent:")
            for event in history { lines.append(line(event, now: now)) }
        }
        if snapshot.events.isEmpty {
            lines.append("nothing to heal")
        }
        return lines.joined(separator: "\n")
    }

    static func line(_ event: HealingEvent, now: Date? = nil) -> String {
        var text = "  \(event.id)  "
        if let now { text += "\(event.outcome.rawValue) \(age(event.updatedAt, now: now)) ago  " }
        text += event.detail
        if event.source == .advisor, let why = event.explanation, !why.isEmpty { text += "\n      advisor: \(why)" }
        return text
    }

    static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    // MARK: - Approve / dismiss

    static func decide(_ args: [String], approve: Bool, backend: (any FleetServing)? = nil) async throws {
        guard let id = args.dropFirst(2).first(where: { !$0.hasPrefix("-") }) else { fail(usage, exit: .usage) }
        guard let backend = await backendOrNil(backend) else {
            print(noDaemon)
            ExitRule.finish(healthy: false)
            return
        }
        do {
            if approve { try await backend.approveHealing(id: id) } else { try await backend.dismissHealing(id: id) }
        } catch {
            let message = error.localizedDescription
            // An id that names nothing is the caller's mistake; anything else is the daemon's answer.
            // In process the error is typed; through the daemon's socket only its text arrives.
            let unknownID: Bool
            if let engine = error as? EngineError {
                if case .unknownHealingEvent = engine { unknownID = true } else { unknownID = false }
            } else {
                unknownID = message.contains("is not a healing event")
            }
            fail(message, exit: unknownID ? .usage : .runtime)
        }
        print(approve ? "approved \(id); it runs in the background — follow it with kinhin heal" : "dismissed \(id)")
    }

    private static func backendOrNil(_ injected: (any FleetServing)?) async -> (any FleetServing)? {
        if let injected { return injected }
        return await FleetBackend.attachToDaemon()
    }
}
