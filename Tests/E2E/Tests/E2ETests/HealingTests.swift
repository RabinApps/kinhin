import E2ESupport
import Foundation
import Testing

/// The healing agent through the real binary. The quick tier needs nothing but the binary; the lanes run a real
/// daemon against Gitea in Docker (and Tart, when its lane is on), with the agent on second-scale cadences
/// (`KINHIN_HEALING_TIMINGS=fast`, a debug-build switch) and, where a scenario needs one, a fixed advisor
/// (`KINHIN_HEALING_ADVISOR=stub:…`) so the advisor path is deterministic on any Mac.
@Suite("Healing CLI", .tags(.cli), .enabled(if: E2E.enabled))
struct HealingCLITests {
    private func withSandbox<T>(_ body: (Sandbox) async throws -> T) async throws -> T {
        let sandbox = try Sandbox()
        defer { sandbox.dispose() }
        return try await body(sandbox)
    }

    private static let config = """
        version: 1
        accounts:
          - name: github
            forge: github
            scope: acme/widgets

        """

    @Test("heal with no daemon says so, prints a stable document, and exits 1")
    func noDaemon() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig(Self.config)
            let json = try await sandbox.kinhin(["heal", "--json"])
            #expect(json.status == 1, "exit \(json.status): \(json.output)")
            let document = try #require(
                try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any], "\(json.output)")
            #expect(document["daemon"] as? Bool == false)
            #expect((document["events"] as? [Any])?.isEmpty == true)
            #expect((document["pending"] as? [Any])?.isEmpty == true)
            #expect(
                Set(document.keys).isSuperset(of: ["daemon", "enabled", "automatic", "events", "pending", "surfaced"]))

            let text = try await sandbox.kinhin(["heal"])
            #expect(text.status == 1)
            #expect(text.stdout.contains("no daemon running"), "\(text.output)")
            let quiet = try await sandbox.kinhin(["heal", "--quiet"])
            #expect(quiet.status == 1 && quiet.stdout.isEmpty, "\(quiet.output)")
        }
    }

    @Test("approve and dismiss need an id (exit 2) and a daemon (exit 1)")
    func approveAndDismissArguments() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig(Self.config)
            for verb in ["approve", "dismiss"] {
                let missing = try await sandbox.kinhin(["heal", verb])
                #expect(missing.status == 2, "\(verb) with no id: exit \(missing.status): \(missing.output)")
                let noDaemon = try await sandbox.kinhin(["heal", verb, "h-00000000"])
                #expect(noDaemon.status == 1, "\(verb) with no daemon: exit \(noDaemon.status): \(noDaemon.output)")
            }
        }
    }

    @Test("a bad healing: value is a config error (exit 3) that names the key; a good one survives export")
    func healingConfig() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig(Self.config + "healing:\n  auto: sometimes\n")
            let bad = try await sandbox.kinhin(["config", "validate"])
            #expect(bad.status == 3, "exit \(bad.status): \(bad.output)")
            #expect(bad.output.contains("healing.auto"), "\(bad.output)")

            try sandbox.writeConfig(Self.config + "healing:\n  auto: none\n  ai: off\n  max_attempts: 2\n")
            let good = try await sandbox.kinhin(["config", "validate"])
            #expect(good.ok, "\(good.output)")
            let exported = try await sandbox.kinhin(["config", "export"])
            #expect(exported.stdout.contains("healing:") && exported.stdout.contains("max_attempts: 2"))
        }
    }

    @Test("the MCP server lists heal_status and no tool that approves a fix")
    func mcpIsReadOnly() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig("version: 1\n")
            let requests =
                [
                    #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}"#,
                    #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                    #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                    #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"heal_status"}}"#,
                ].joined(separator: "\n") + "\n"
            let result = try await sandbox.kinhin(["mcp"], stdin: requests, timeout: 60)
            #expect(result.stdout.contains("heal_status"), "\(result.output)")
            #expect(!result.stdout.contains("heal_approve") && !result.stdout.contains("heal_dismiss"))
            #expect(
                result.stdout.contains("no daemon running"), "heal_status answers without a daemon: \(result.output)")
        }
    }
}

extension Infra {
    @Suite("Healing", .tags(.fleet), .enabled(if: E2E.dockerAvailable, "needs Docker"))
    struct HealingTests {
        /// One journal entry of `kinhin heal --json`, as much of it as the scenarios judge.
        struct Entry: Decodable, Sendable {
            struct Signal: Decodable, Sendable {
                let kind: String
                let subject: String?
            }
            struct Fix: Decodable, Sendable {
                let kind: String
            }
            let id: String
            let signal: Signal
            let remediation: Fix?
            let source: String
            let outcome: String
            let detail: String
            let explanation: String?

            var kind: String? { remediation?.kind }
        }

        /// The `kinhin heal --json` document, and the command's exit status.
        struct View: Decodable, Sendable {
            let daemon: Bool
            let enabled: Bool
            let events: [Entry]
            let pending: [Entry]
            var status: Int32 = 0

            enum CodingKeys: String, CodingKey { case daemon, enabled, events, pending }
        }

        private static func heal(_ lane: Lane) async throws -> View {
            let result = try await lane.sandbox.kinhin(["heal", "--json"], timeout: 30)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard var view = try? decoder.decode(View.self, from: Data(result.stdout.utf8)) else {
                throw E2EError.failed(
                    "heal --json was not the healing document (exit \(result.status)): \(result.output)")
            }
            view.status = result.status
            return view
        }

        private static func alerts(_ lane: Lane) async throws -> [String] {
            let result = try await lane.sandbox.kinhin(["status", "--json"], timeout: 30)
            let status = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any]
            let fleet = status?["fleet"] as? [String: Any]
            return (fleet?["alerts"] as? [[String: Any]] ?? []).compactMap { $0["source"] as? String }
        }

        /// A Gitea-on-Docker lane with the agent on fast cadences, a runner floor (so the engine tries to spawn) and
        /// `config` appended.
        private static func options(_ config: String, advisor: String? = nil) -> Lane.Options {
            var options = Lane.Options()
            options.minRunners = 1
            // Scenarios that need spawns to happen drop the disk reserve, so a nearly full e2e Mac does not hold
            // every spawn on disk pressure (a real problem the agent would rightly report, but not the one under test).
            // The disk scenarios set their own reserve.
            options.extraConfig = config.contains("reserve:") ? config : "reserve:\n  disk_gb: 0\n" + config
            options.environment["KINHIN_HEALING_TIMINGS"] = "fast"
            if let advisor { options.environment["KINHIN_HEALING_ADVISOR"] = advisor }
            return options
        }

        /// The daemon outlived the scenario, its log never carried the forge token, and the journal is owner-only.
        private static func expectHealthy(_ lane: Lane) async {
            #expect(lane.daemon?.isRunning == true, "the daemon died")
            let token = await lane.fixture.token
            #expect(!lane.sandbox.log().contains(token), "the token reached kinhin's log")
            let journal = lane.sandbox.supportDirectory.appendingPathComponent("state/healing.json")
            if let mode = try? FileManager.default.attributesOfItem(atPath: journal.path)[.posixPermissions]
                as? NSNumber
            {
                #expect(mode.intValue == 0o600, "the healing journal is not owner-only")
            }
        }

        // MARK: - Disk pressure: automatic, then approval

        @Test("disk pressure prunes the toolchain cache on its own, then waits for approval to prune images")
        func diskPressure() async throws {
            // A reserve no Mac can meet holds every spawn on disk pressure; the floor makes the engine try.
            let options = Self.options("reserve:\n  disk_gb: 1000000")
            try await Lane.with(forge: .gitea, runtime: .docker, options: options) { lane in
                // A cache entry well past the 30-day policy, in the sandbox's own cache.
                let cache = lane.sandbox.supportDirectory.appendingPathComponent("toolchain-cache/npm")
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                let stale = cache.appendingPathComponent("stale.tgz")
                try Data(repeating: 7, count: 4096).write(to: stale)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(-60 * 86_400)], ofItemAtPath: stale.path)

                let pruned = try await eventually("the cache prune to run on its own", timeout: 180, interval: 2) {
                    try await Self.heal(lane).events.first {
                        $0.kind == "prune_toolchain_cache" && $0.outcome == "succeeded"
                    }
                }
                #expect(pruned.source == "playbook")
                #expect(!FileManager.default.fileExists(atPath: stale.path), "the stale cache entry is still there")

                // The disk is still "full": the next fix is destructive, so it waits.
                let waiting = try await eventually("an image prune waiting for approval", timeout: 120, interval: 2) {
                    let view = try await Self.heal(lane)
                    return view.pending.contains { $0.kind == "prune_images" } ? view : nil
                }
                #expect(waiting.status == 1, "heal exits 1 while a fix waits")
                #expect(try await Self.alerts(lane).contains("healing"), "no healing alert in status")
                let id = try #require(waiting.pending.first { $0.kind == "prune_images" }?.id)

                let dismissed = try await lane.sandbox.kinhin(["heal", "dismiss", id], timeout: 30)
                #expect(dismissed.ok, "\(dismissed.output)")
                let after = try await Self.heal(lane)
                #expect(after.pending.isEmpty)
                #expect(
                    after.status == 0,
                    "nothing waits on the user any more: \(after.events.filter { $0.outcome == "surfaced" }.map(\.detail))"
                )
                try await eventually("the healing alert to clear", timeout: 30) {
                    try await Self.alerts(lane).contains("healing") ? nil : true
                }
                // Dismissed stays dismissed while the problem lasts: it is not raised again.
                try await Task.sleep(for: .seconds(10))
                #expect(try await Self.heal(lane).pending.isEmpty)
                let wrong = try await lane.sandbox.kinhin(["heal", "approve", "h-00000000"], timeout: 30)
                #expect(wrong.status == 2, "an unknown id is a usage error: \(wrong.output)")
                await Self.expectHealthy(lane)
            }
        }

        @Test("healing.auto: none turns the automatic cache prune into an approval, and approving runs it")
        func autoNone() async throws {
            let options = Self.options("reserve:\n  disk_gb: 1000000\nhealing:\n  auto: none")
            try await Lane.with(forge: .gitea, runtime: .docker, options: options) { lane in
                let pending = try await eventually("the cache prune waiting for approval", timeout: 180) {
                    try await Self.heal(lane).pending.first { $0.kind == "prune_toolchain_cache" }
                }
                let approved = try await lane.sandbox.kinhin(["heal", "approve", pending.id], timeout: 30)
                #expect(approved.ok, "\(approved.output)")
                try await eventually("the approved prune to finish", timeout: 120) {
                    try await Self.heal(lane).events.first { $0.id == pending.id }?.outcome == "succeeded" ? true : nil
                }
                await Self.expectHealthy(lane)
            }
        }

        @Test("healing.enabled: false journals nothing and the fleet still runs jobs")
        func disabled() async throws {
            var options = Self.options("healing:\n  enabled: false")
            options.minRunners = nil
            try await Lane.with(forge: .gitea, runtime: .docker, options: options) { lane in
                let (_, proof) = try await lane.runJob(name: "healing-off", timeout: 420)
                #expect(proof.hasPrefix("Linux"), "proof was: \(proof)")
                let view = try await Self.heal(lane)
                #expect(!view.enabled)
                #expect(view.events.isEmpty)
                await Self.expectHealthy(lane)
            }
        }

        // MARK: - A broken image: no rule, so the advisor (or the user) decides

        /// Restarts `lane` on an image that does not exist, so its runners keep failing to start.
        private static func breakImage(_ lane: Lane) async throws {
            await lane.daemon?.stop()
            var config = try String(contentsOf: lane.sandbox.configURL, encoding: .utf8)
            config = config.replacingOccurrences(of: lane.image, with: "ke2e-no-such-image-\(E2E.randomID())")
            try lane.sandbox.writeConfig(config)
            try await lane.startDaemon()
        }

        private static func spawnFailureEntry(_ lane: Lane, outcome: String? = nil, source: String? = nil)
            async throws -> Entry
        {
            try await eventually("a spawn-failure entry", timeout: 240, interval: 3) {
                try await Self.heal(lane).events.first {
                    $0.signal.kind == "spawn_failures" && (outcome == nil || $0.outcome == outcome)
                        && (source == nil || $0.source == source)
                }
            }
        }

        @Test("with the advisor off, repeated spawn failures on a healthy runtime are surfaced, not acted on")
        func brokenImageIsSurfaced() async throws {
            try await Lane.with(forge: .gitea, runtime: .docker, options: Self.options("healing:\n  ai: off")) { lane in
                try await Self.breakImage(lane)
                let entry = try await Self.spawnFailureEntry(lane, outcome: "surfaced")
                #expect(entry.source == "playbook")
                #expect(entry.remediation == nil, "nothing was chosen")
                await Self.expectHealthy(lane)
            }
        }

        @Test("an advisor's pick outside the allowlist is ignored and the problem surfaced")
        func advisorOutsideTheAllowlist() async throws {
            let options = Self.options("", advisor: "stub:invalid")
            try await Lane.with(forge: .gitea, runtime: .docker, options: options) { lane in
                try await Self.breakImage(lane)
                let entry = try await Self.spawnFailureEntry(lane, outcome: "surfaced")
                #expect(entry.source == "advisor")
                #expect(entry.remediation == nil)
                #expect(lane.sandbox.log().contains("which is not an allowed fix"), "\(lane.logTail())")
                await Self.expectHealthy(lane)
            }
        }

        @Test("an advisor that picks a destructive fix only queues it for approval")
        func advisorCannotEscalate() async throws {
            let options = Self.options("", advisor: "stub:repair_runtime")
            try await Lane.with(forge: .gitea, runtime: .docker, options: options) { lane in
                try await Self.breakImage(lane)
                let entry = try await Self.spawnFailureEntry(lane, outcome: "pending")
                #expect(entry.source == "advisor")
                #expect(entry.kind == "repair_runtime")
                #expect(entry.explanation?.isEmpty == false)
                #expect(try await Self.heal(lane).status == 1)
                await Self.expectHealthy(lane)
            }
        }

        // MARK: - A warm Tart VM deleted behind kinhin's back

        @Test(
            "a warm Tart VM deleted out of band is recycled on its own and the next job still runs",
            .enabled(if: RuntimeKind.tartLinux.isAvailable, "needs the Tart Linux lane (KINHIN_E2E_TART_LINUX_BASE)"))
        func vanishedWarmVMIsRecycled() async throws {
            var options = Self.options("warm_pool: 1")
            options.minRunners = 0
            options.forgeImage = GiteaFixture.floorFreeGiteaImage
            try await Lane.with(forge: .gitea, runtime: .tartLinux, options: options) { lane in
                let warm = try await eventually("a warm instance", timeout: 300, interval: 3) {
                    let result = try await lane.sandbox.kinhin(["status", "--json"], timeout: 30)
                    let status = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any]
                    let records = ((status?["fleet"] as? [String: Any])?["records"] as? [[String: Any]]) ?? []
                    return records.first { ($0["phase"] as? String) == "warm" }?["id"] as? String
                }
                _ = try await Shell.run("tart", ["stop", warm], timeout: 120)
                _ = try await Shell.run("tart", ["delete", warm], timeout: 120)

                let recycled = try await eventually("the vanished warm VM to be recycled", timeout: 300) {
                    try await Self.heal(lane).events.first {
                        $0.kind == "recycle_instance" && $0.outcome == "succeeded"
                    }
                }
                #expect(recycled.signal.subject == warm)
                let (_, proof) = try await lane.runJob(name: "after-recycle", timeout: 600)
                #expect(proof.hasPrefix("Linux"), "proof was: \(proof)")
                await Self.expectHealthy(lane)
            }
        }

        // MARK: - The real on-device advisor (opt-in)

        @Test(
            "the on-device advisor answers from the daemon with an allowed fix or none (KINHIN_E2E_AI=1)",
            .enabled(if: E2E.flag("KINHIN_E2E_AI") != nil, "set KINHIN_E2E_AI=1 on a Mac with Apple Intelligence"))
        func liveAdvisor() async throws {
            // A forge that stops answering leaves its queue unreadable, which no rule covers, so the problem goes to the
            // advisor. Unlike a broken image it needs no spawn, so it runs on a Mac too full to start runners.
            var options = Self.options("")
            options.minRunners = 0
            try await Lane.with(forge: .gitea, runtime: .docker, options: options) { lane in
                let gitea = try #require(lane.fixture as? GiteaFixture)
                try await gitea.pause()
                let entry: Entry
                do {
                    entry = try await eventually(
                        "the advisor's entry for the unreadable queue", timeout: 300, interval: 3
                    ) {
                        try await Self.heal(lane).events.first {
                            $0.signal.kind == "queue_unreadable" && $0.source == "advisor"
                        }
                    }
                } catch {
                    try await gitea.resume()
                    throw error
                }
                try await gitea.resume()
                // The only candidate for a queue problem is re-attaching that account; anything else was refused.
                if let kind = entry.kind { #expect(kind == "retry_forge_attach", "picked \(kind)") }
                #expect(!(entry.explanation ?? "").isEmpty, "the advisor gave no reasoning")
                #expect(!(entry.explanation ?? "").contains(await lane.fixture.token))
                await Self.expectHealthy(lane)
            }
        }
    }
}
