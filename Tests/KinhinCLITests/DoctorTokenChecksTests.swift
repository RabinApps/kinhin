import Foundation
import Synchronization
import XCTest

@testable import KinhinKit
@testable import kinhin

/// `kinhin doctor --check-tokens`: every configured account's token is probed
/// against its own forge, the verdicts land in the report (text and JSON), a
/// failure makes doctor not-ready, and without the flag nothing touches the
/// network and the text says so.
final class DoctorTokenChecksTests: XCTestCase {
    private let host = HostResources(logicalCores: 10, memoryGB: 32, freeDiskGB: 200, arm64: true)

    private static func config() -> KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.accounts = [
            AccountConfig(name: "github", forge: .github, scope: "acme"),
            AccountConfig(name: "work-gl", forge: .gitlab, scope: "acme/group"),
            AccountConfig(name: "gitea", forge: .gitea, scope: "acme", instance: "https://gitea.example.com"),
        ]
        return cfg
    }

    private func builder(
        checkTokens: Bool, tokens: [String: String?] = ["github": "a", "work-gl": "b", "gitea": "c"],
        probe: @escaping @Sendable (AccountConfig, String) async -> TokenHealthCheck.Report = { _, _ in
            TokenHealthCheck.Report(ok: true, message: "fine")
        }
    ) -> DoctorReportBuilder {
        DoctorReportBuilder(
            host: host, clt: .ok(version: "26.6"), tartHealth: .healthy, tartList: [],
            config: .loaded(Self.config()),
            authLoad: { _ in nil }, accountLoad: { _, name in tokens[name] ?? nil },
            checkTokens: checkTokens, tokenCheck: probe)
    }

    func testDefaultDoctorDoesNotProbeAndSaysTokensWereNotChecked() async {
        let calls = Mutex(0)
        let sut = builder(checkTokens: false) { _, _ in
            calls.withLock { $0 += 1 }
            return TokenHealthCheck.Report(ok: true, message: "x")
        }
        let report = await sut.build()
        XCTAssertNil(report.tokenChecks)
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertTrue(report.plainText.contains("not checked — run with --check-tokens"), report.plainText)
    }

    func testEveryAccountIsCheckedWithItsOwnTokenInConfigOrder() async throws {
        let seen = Mutex<[String]>([])
        let report = await builder(checkTokens: true) { account, token in
            seen.withLock { $0.append("\(account.name)=\(token)") }
            return TokenHealthCheck.Report(ok: true, message: "ok for \(account.forge.rawValue)")
        }.build()

        let checks = try XCTUnwrap(report.tokenChecks)
        XCTAssertEqual(checks.map(\.account), ["github", "work-gl", "gitea"])
        XCTAssertEqual(checks.map(\.forge), ["github", "gitlab", "gitea"])
        XCTAssertTrue(checks.allSatisfy(\.ok))
        XCTAssertEqual(seen.withLock { $0 }.sorted(), ["gitea=c", "github=a", "work-gl=b"])
        XCTAssertFalse(report.plainText.contains("not checked"))
        XCTAssertTrue(report.plainText.contains("tok check:  gitea: ok for gitea ✓"), report.plainText)
    }

    func testAFailedNonGitHubTokenMakesDoctorNotReadyAndNamesTheFix() async throws {
        let report = await builder(checkTokens: true) { account, _ in
            account.forge == .gitlab
                ? TokenHealthCheck.Report(ok: false, message: "401 Unauthorized")
                : TokenHealthCheck.Report(ok: true, message: "ok")
        }.build()

        let failed = try XCTUnwrap(report.tokenChecks?.first { !$0.ok })
        XCTAssertEqual(failed.account, "work-gl")
        XCTAssertEqual(failed.fix, "kinhin auth set --account work-gl")
        XCTAssertNil(report.tokenChecks?.first { $0.ok }?.fix)
        XCTAssertFalse(report.ready)
        XCTAssertTrue(report.plainText.contains("work-gl: FAILED ✗ — 401 Unauthorized"), report.plainText)
        XCTAssertTrue(report.plainText.contains("fix: kinhin auth set --account work-gl"), report.plainText)
    }

    func testPassingChecksDoNotChangeReadiness() async {
        let without = await builder(checkTokens: false).build()
        let with = await builder(checkTokens: true).build()
        XCTAssertEqual(with.ready, without.ready)
    }

    func testMissingOrUnreadableTokenFailsWithoutAProbe() async throws {
        struct Locked: LocalizedError { var errorDescription: String? { "Keychain is locked" } }
        let calls = Mutex(0)
        let sut = DoctorReportBuilder(
            host: host, clt: .ok(version: "26.6"), tartHealth: .healthy, tartList: [],
            config: .loaded(Self.config()), authLoad: { _ in nil },
            accountLoad: { _, name in
                if name == "gitea" { throw Locked() }
                return name == "github" ? nil : "tok"
            },
            checkTokens: true,
            tokenCheck: { _, _ in
                calls.withLock { $0 += 1 }
                return TokenHealthCheck.Report(ok: true, message: "ok")
            })
        let built = await sut.build()
        let checks = try XCTUnwrap(built.tokenChecks)

        XCTAssertEqual(checks.map(\.ok), [false, true, false])
        XCTAssertEqual(checks[0].message, "No token stored.")
        XCTAssertTrue(checks[2].message.contains("Keychain is locked"))
        XCTAssertEqual(calls.withLock { $0 }, 1, "only the account with a readable token reaches the network")
    }

    func testJSONCarriesTheChecksOnlyWhenRequested() async throws {
        let offReport = await builder(checkTokens: false).build()
        let off = try CLIJSON.data(offReport)
        XCTAssertFalse(String(decoding: off, as: UTF8.self).contains("tokenChecks"))

        let onReport = await builder(checkTokens: true) { _, _ in
            TokenHealthCheck.Report(ok: false, message: "revoked")
        }.build()
        let on = try CLIJSON.data(onReport)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: on) as? [String: Any])
        let checks = try XCTUnwrap(object["tokenChecks"] as? [[String: Any]])
        XCTAssertEqual(checks.count, 3)
        XCTAssertEqual(checks[0]["ok"] as? Bool, false)
        XCTAssertEqual(checks[0]["fix"] as? String, "kinhin auth set --account github")
        XCTAssertEqual(object["ready"] as? Bool, false)
    }

    func testTheCheckTokensSwitchTurnsTheProbeOnForABuiltBuilder() async throws {
        let calls = Mutex(0)
        let sut = builder(checkTokens: false) { _, _ in
            calls.withLock { $0 += 1 }
            return TokenHealthCheck.Report(ok: true, message: "ok")
        }
        var flagged = sut
        flagged.checkTokens = true
        _ = await flagged.build()
        XCTAssertEqual(calls.withLock { $0 }, 3)
    }

    func testOrgScopeStillListsRequirementsWithoutAHiddenNetworkProbe() async {
        let calls = Mutex(0)
        let text = await builder(checkTokens: false) { _, _ in
            calls.withLock { $0 += 1 }
            return TokenHealthCheck.Report(ok: true, message: "ok")
        }.buildPlainText()
        XCTAssertTrue(text.contains("scope:      organization 'acme'"), text)
        XCTAssertFalse(text.contains("org perms:"), text)
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }
}
