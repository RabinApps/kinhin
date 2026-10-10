import E2ESupport
import Foundation
import Testing

extension Infra {
    /// Every toolchain in the catalog, installed and run for real. The heavy lifting is `kinhin bench toolchains`, which
    /// installs each tool the way `image prepare` does, verifies it and runs a small workload in a real guest.
    ///
    /// `KINHIN_E2E_TOOLCHAINS=full` runs the whole catalog (hours); the default is a representative smoke set.
    @Suite("Toolchains", .tags(.toolchain))
    struct ToolchainTests {
        /// One tool per installer family: mise (node, go), a brew/apt formula (jq), and a mise-installed Python tool (uv).
        static let smokeSet = ["jq", "node", "go", "uv"]

        static let lanes: [RuntimeKind] = [.docker, .appleContainer, .tartLinux].filter {
            $0.isAvailable && E2E.selected("KINHIN_E2E_RUNTIMES", $0.rawValue)
        }

        @Test("the catalog lists tools and stacks")
        func catalogIsNotEmpty() async throws {
            let sandbox = try Sandbox()
            defer { sandbox.dispose() }
            try sandbox.writeConfig("version: 1\n")
            let result = try await sandbox.kinhin(["toolchains", "--json"])
            let object = try #require(
                try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
            #expect(((object["stacks"] as? [[String: Any]]) ?? []).count >= 5, "stacks missing")
            #expect(result.stdout.contains("flutter"))
        }

        @Test("bench installs, verifies and runs toolchains in a real guest", arguments: ToolchainTests.lanes)
        func installAndRun(_ runtime: RuntimeKind) async throws {
            let full = E2E.flag("KINHIN_E2E_TOOLCHAINS") == "full"
            let sandbox = try Sandbox()
            defer { sandbox.dispose() }
            let account = FleetConfig.Account(
                name: "gitea", forge: "gitea", scope: "acme/widgets", instance: "http://127.0.0.1:9",
                allowInsecureHTTP: true)
            let image = try await ImageBaker.shared.ensure(runtime, accounts: [account])
            defer { Task { await Instances.removeAll(runtime, image: image) } }
            sandbox.setToken("unused", account: "gitea")
            try sandbox.writeConfig(FleetConfig(accounts: [account], runtime: runtime, image: image).yaml())

            // --thorough: cold installs. The default intensity only checks what the image already has, so it
            // skipped every tool not baked in and proved nothing about installing them.
            var arguments = [
                "bench", "toolchains", "--thorough", "--runtime", runtime.kinhinRuntime, "--json", "--yes",
            ]
            arguments += full ? ["--all-toolchains"] : ["--toolchains", Self.smokeSet.joined(separator: ",")]
            let result = try await sandbox.kinhin(arguments, timeout: full ? 4 * 3600 : 1800)

            let report = try #require(
                try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                "no JSON report (exit \(result.status)): \(result.output.suffix(1500))")
            let suites = try #require(report["suites"] as? [[String: Any]])
            let rows = suites.flatMap { ($0["toolchains"] as? [[String: Any]]) ?? [] }
            #expect(!rows.isEmpty, "the toolchains suite produced no rows")

            let failed = rows.filter { ($0["status"] as? String) == "failed" }
            #expect(
                failed.isEmpty,
                "failed toolchains on \(runtime): \(failed.map { "\($0["tool"] ?? "?"): \($0["note"] ?? "")" })")
            let ran = rows.filter { ($0["status"] as? String) == "ran" }
            #expect(!ran.isEmpty, "nothing actually ran; skipped: \(rows.compactMap { $0["skipReason"] })")
            // A skip must say why; a silent skip is how coverage rots.
            for row in rows where (row["status"] as? String) == "skipped" {
                #expect(
                    !((row["skipReason"] as? String) ?? "").isEmpty, "\(row["tool"] ?? "?") skipped without a reason")
            }
            if !full {
                let ranTools = Set(ran.compactMap { $0["tool"] as? String })
                #expect(
                    ranTools.isSuperset(of: Self.smokeSet),
                    "smoke tools that did not run on \(runtime): \(Set(Self.smokeSet).subtracting(ranTools).sorted())")
            }
            #expect(result.ok, "bench exited \(result.status)")
        }

        @Test(
            "a per-job toolchain install works inside a real runner job",
            arguments: LifecycleCase.all.filter { $0.runtime != .host })
        func perJobInstall(_ cell: LifecycleCase) async throws {
            try await Lane.with(forge: cell.forge, runtime: cell.runtime) { lane in
                let (_, proof) = try await lane.runJob(
                    name: "toolchain",
                    // The helper hands new PATH entries to later steps through $GITHUB_PATH; this one runs in the same shell,
                    // so it puts mise's shims on PATH itself.
                    extraStep:
                        "kinhin-toolchain install node@22 >/dev/null\nexport PATH=\"$HOME/.local/share/mise/shims:$PATH\"\nexport E2E_EXTRA=\"$(node -v)\"",
                    timeout: 900)
                #expect(proof.contains("v22"), "node@22 was not installed by the job: \(proof)")
            }
        }
    }
}
