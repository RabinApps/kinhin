import Foundation

/// Which runner agents a bake installs. Token-gated provisioning: an agent is
/// baked in ONLY when the user has a credential for one of its forges. No
/// GitHub PAT, no GitHub agent; no tokens at all fails loudly. Shared by the
/// VM bake (`ImagePreparer`) and the container bakes (`LinuxImageBaker`) so
/// both apply one policy.
struct AgentSelection: Sendable {
    /// The forges that have a stored token.
    let tokenForges: Set<ForgeID>

    /// Resolves the selection. `override` replaces the Keychain probe (tests);
    /// nil probes the Keychain for every forge. Throws
    /// `ImageError.noCredentials` when no forge has a token.
    init(override: Set<ForgeID>?) throws {
        if let override {
            tokenForges = override
        } else {
            var found: Set<ForgeID> = []
            for forge in ForgeID.allCases where try AccountTokens.anyStored(for: forge) { found.insert(forge) }
            tokenForges = found
        }
        guard !selected.isEmpty else {
            throw ImageError.noCredentials(Self.noCredentialsHint)
        }
    }

    /// The hint every bake shows when no platform token is stored.
    static let noCredentialsHint = "store at least one platform token first (kinhin auth set --account NAME)"

    /// Whether `agent` is part of this bake: any forge of its family has a token.
    func includes(_ agent: RunnerAgentSpec) -> Bool {
        agent.forges.contains { tokenForges.contains($0) }
    }

    /// The agents to bake, in bake order.
    var selected: [RunnerAgentSpec] { RunnerAgentSpec.all.filter(includes) }

    /// Every forge whose agent is baked (so a Gitea token also covers Forgejo).
    var bakedForges: Set<ForgeID> { Set(selected.flatMap(\.forges)) }

    /// The install script of every agent in bake order, logging a "found" or
    /// "skipping" line under `tag` for each.
    func installScripts(
        versions: RunnerVersionResolver.Versions, tag: String, script: (RunnerAgentSpec) -> String
    ) -> [String] {
        RunnerAgentSpec.all.compactMap { agent in
            guard includes(agent) else {
                Log.info(tag, agent.skippedLine)
                return nil
            }
            Log.info(tag, agent.foundLine(versions))
            return script(agent)
        }
    }
}
