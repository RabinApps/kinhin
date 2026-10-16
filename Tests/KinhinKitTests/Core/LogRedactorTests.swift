import XCTest

@testable import KinhinKit

final class LogRedactorTests: XCTestCase {
    private func assertRedacts(_ input: String, secret: String, file: StaticString = #filePath, line: UInt = #line) {
        let output = LogRedactor.redact(input)
        XCTAssertFalse(output.contains(secret), "leaked \(secret) in: \(output)", file: file, line: line)
        XCTAssertTrue(output.contains(LogRedactor.mask), output, file: file, line: line)
    }

    func testRedactsGitHubTokenFamilies() {
        assertRedacts(
            "using ghp_abcdefghijklmnopqrstuvwxyz0123456789", secret: "ghp_abcdefghijklmnopqrstuvwxyz0123456789")
        assertRedacts("ghs_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 expired", secret: "ghs_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
        assertRedacts(
            "pat github_pat_11ABCDEFG0abcdefghijkl_mnopqrstuvwxyz1234",
            secret: "github_pat_11ABCDEFG0abcdefghijkl_mnopqrstuvwxyz1234")
    }

    func testRedactsGitLabBitbucketAndBuildkiteTokens() {
        assertRedacts("runner glrt-abcdefghij0123456789 registered", secret: "glrt-abcdefghij0123456789")
        assertRedacts("token glpat-abcdef_ghij-0123456789", secret: "glpat-abcdef_ghij-0123456789")
        assertRedacts(
            "got ATCTT3xFfGN0abcdefghijklmnopqrstuvwxyz=12AB", secret: "ATCTT3xFfGN0abcdefghijklmnopqrstuvwxyz=12AB")
        assertRedacts("api bkua_abcdefghijklmnopqrstuvwx used", secret: "bkua_abcdefghijklmnopqrstuvwx")
        assertRedacts("PRIVATE-TOKEN: hunter2hunter2", secret: "hunter2hunter2")
    }

    func testRedactsAuthorizationHeaders() {
        assertRedacts("Authorization: token s3cr3tvalue123", secret: "s3cr3tvalue123")
        assertRedacts("authorization: Bearer abc.def.ghi", secret: "abc.def.ghi")
    }

    func testRedactsRegistrationFlagsInAllQuotingStyles() {
        assertRedacts("./config.sh --token 'AAAA1111BBBB' --labels x", secret: "AAAA1111BBBB")
        assertRedacts("./config.sh --token AAAA1111BBBB --labels x", secret: "AAAA1111BBBB")
        assertRedacts("register --token=AAAA1111BBBB", secret: "AAAA1111BBBB")
        assertRedacts(#"run --token "AAAA 1111" next"#, secret: "AAAA 1111")
    }

    func testRedactsKeyValueSecrets() {
        assertRedacts("failed: access_token=xyz987secret", secret: "xyz987secret")
        assertRedacts("password: hunter2hunter2", secret: "hunter2hunter2")
    }

    /// The literal pre-check must never change a result: every sample that
    /// exercises a rule, in several casings and surroundings, redacts the
    /// same with and without the gate.
    func testGatedRedactionMatchesUngatedOnEveryRuleFamily() {
        let samples = [
            "using ghp_abcdefghijklmnopqrstuvwxyz0123456789", "ghu_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345",
            "github_pat_11ABCDEFG0abcdefghijkl_mnopqrstuvwxyz1234", "runner glrt-abcdefghij0123456789 registered",
            "got ATCTT3xFfGN0abcdefghijklmnopqrstuvwxyz=12AB", "ATBBabcdefghijklmnopqrstuvwxyz",
            "api bkua_abcdefghijklmnopqrstuvwx used", "PRIVATE-TOKEN: hunter2hunter2", "private-token hunter2hunter2",
            "Authorization: token s3cr3tvalue123", "AUTHORIZATION Bearer abc.def.ghi",
            "./config.sh --TOKEN 'AAAA1111BBBB'", "register --password=hunter2", "x --pat abc123",
            "BEARER abcdefghijklmnop1234", "GR1348941abcdef0123456789abcd",
            "clone https://user:s3cret@example.com/x.git", "GITHUB_TOKEN=abc123 ran", #"{"api_key": "abc"}"#,
            "APIKEY=zzz", "client_secret: topsecretvalue", "plain line with nothing", "",
        ]
        for sample in samples {
            XCTAssertEqual(
                LogRedactor.applyRules(to: sample, gated: true), LogRedactor.applyRules(to: sample, gated: false),
                "gate changed the result for: \(sample)")
        }
        XCTAssertNotEqual(LogRedactor.redact("AUTHORIZATION Bearer abc.def.ghi"), "AUTHORIZATION Bearer abc.def.ghi")
        XCTAssertNotEqual(LogRedactor.redact("clone https://user:s3cret@example.com/x.git"), "")
        XCTAssertFalse(LogRedactor.redact("clone https://user:s3cret@example.com/x.git").contains("s3cret"))
    }

    func testLeavesOrdinaryLinesAndChecksumsAlone() {
        let lines = [
            "starting fleet engine for github (capacity cap: 2)",
            "runner tokens refreshed",  // mentions "tokens" but holds no secret
            "SHA-256 mismatch (expected 5a2cd92908a93d7276a194e1de6008099f3e7946f3f8e14aa7a1a7b4a31fdec2)",
            "deleting VM kinhin-1790375001 (failed: tart clone failed)",
        ]
        for line in lines {
            XCTAssertEqual(LogRedactor.redact(line), line)
        }
    }

    func testPreservesSurroundingContext() {
        XCTAssertEqual(
            LogRedactor.redact("config: --token 'abc123' --name 'kinhin-1'"),
            "config: --token [REDACTED] --name 'kinhin-1'")
    }

    func testRedactsJSONQuotedAndEnvironmentStyleSecrets() {
        assertRedacts(#"{"token":"AAAA1111BBBB"}"#, secret: "AAAA1111BBBB")
        assertRedacts(#"{"password": "hunter2hunter2"}"#, secret: "hunter2hunter2")
        assertRedacts("GITHUB_TOKEN=AAAA1111BBBB run", secret: "AAAA1111BBBB")
        assertRedacts("registration_token: AAAA1111BBBB", secret: "AAAA1111BBBB")
    }

    func testRedactsURLUserinfoAndBareBearer() {
        assertRedacts("clone https://oauth2:s3cr3tvalue123@gitea.example/org/repo", secret: "s3cr3tvalue123")
        XCTAssertTrue(LogRedactor.redact("https://oauth2:s3cr3t@host/x").contains("@host/x"))
        assertRedacts("sent Bearer abcdefghijklmnop1234", secret: "abcdefghijklmnop1234")
        assertRedacts("ATBBabcdefghijklmnopqrstuvwx1234", secret: "ATBBabcdefghijklmnopqrstuvwx1234")
    }

    func testMasksRegisteredSecretsLiterally() {
        defer { LogRedactor.forgetAllSecretsForTesting() }
        let unprefixed = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
        LogRedactor.registerSecret(unprefixed)
        assertRedacts("request failed for \(unprefixed) at host", secret: unprefixed)
        LogRedactor.registerSecret("short")
        XCTAssertEqual(LogRedactor.redact("a short word"), "a short word")
    }

    /// Registration material (tokens, JIT configs) has no prefix the rules know; it is masked literally, and only
    /// the newest `registrationSecretLimit` values are kept so the per-line scan stays bounded.
    func testMasksRecentRegistrationSecretsAndForgetsTheOldest() {
        defer { LogRedactor.forgetAllSecretsForTesting() }
        let limit = LogRedactor.registrationSecretLimit
        let secrets = (0...limit).map { "jit-config-\($0)-" + String(repeating: "x", count: 12) }
        for secret in secrets { LogRedactor.registerRegistrationSecret(secret) }
        assertRedacts("runner failed: \(secrets[limit])", secret: secrets[limit])
        XCTAssertTrue(LogRedactor.redact(secrets[0]).contains(secrets[0]), "the oldest was evicted")
        LogRedactor.registerRegistrationSecret("tiny")
        XCTAssertEqual(LogRedactor.redact("a tiny word"), "a tiny word")
    }

    /// A secret that contains another is masked whole, not left with the outer part showing.
    func testMasksTheLongerOfNestedSecretsWhole() {
        defer { LogRedactor.forgetAllSecretsForTesting() }
        LogRedactor.registerSecret("inner-secret-value")
        LogRedactor.registerRegistrationSecret("outer-inner-secret-value-tail")
        XCTAssertEqual(LogRedactor.redact("x outer-inner-secret-value-tail y"), "x \(LogRedactor.mask) y")
    }
}
