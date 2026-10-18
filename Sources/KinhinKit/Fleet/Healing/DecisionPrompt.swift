import Foundation

/// The wording the System 1 decision model is given. A decision model scores
/// options rather than following instructions, so each option says when it is
/// the right fix, and `none` says when every option is wrong. Tuned on
/// `clef-flash`: it cut confident wrong picks to zero in the eval set.
enum DecisionPrompt {
    static let question = "Which fix addresses the cause?"

    static let header =
        "Choose the one fix whose cause matches the logs. Use only what the problem and logs state. "
        + "If no listed fix addresses the cause, choose none. Do not pick a fix just because it is offered. "
        + "The logs are the evidence: a fix is right only when the logs name its cause."

    /// When every option is wrong.
    static let noneWhen =
        "the runtime fails every lookup, the forge rejects the token (401 or 403), the disk is full from "
        + "something other than the caches and images listed, or the logs show no real failure."

    /// The condition under which `kind` is the right fix.
    static func precondition(for kind: Remediation.Kind) -> String {
        switch kind {
        case .recycleInstance:
            return "the runtime lists its other VMs normally and this one is missing from the list"
        case .retryForgeAttach:
            return "the forge gave a transient error such as a timeout, a reset or a 5xx"
        case .pruneToolchainCache:
            return "the toolchain cache is the large, unused thing filling the disk"
        case .pruneImages:
            return "unused images or the image store are what fill the disk or run out of space"
        case .repairTart:
            return "tart itself is killed or fails on launch"
        case .repairRuntime:
            return "the runtime is not installed or cannot start VMs"
        case .startContainerSystem:
            return "the Apple container system is stopped"
        default:
            return "the logs name the cause this fix addresses"
        }
    }

    /// One criterion per option: the candidates, then `none`.
    static func criteria(for candidates: [Remediation]) -> [String: String] {
        var criteria = [HealingPrompt.none: "Pick none when \(noneWhen)"]
        for candidate in candidates {
            criteria[candidate.kind.rawValue] =
                "Pick \(candidate.kind.rawValue) only when \(precondition(for: candidate.kind))."
        }
        return criteria
    }

    /// The header, then the problem and its logs, trimmed to `budget` characters.
    static func state(for request: HealingAdviceRequest, budget: Int) -> String {
        let room = max(0, budget - header.count - 2)
        return header + "\n\n" + HealingPrompt.prompt(for: request, budget: room)
    }
}
