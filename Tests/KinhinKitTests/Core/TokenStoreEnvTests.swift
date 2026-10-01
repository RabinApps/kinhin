import XCTest

@testable import KinhinKit

#if DEBUG
    /// The debug-only environment token source: no Keychain involved, so these
    /// tests inject the environment and never read the real login keychain.
    final class TokenStoreEnvTests: XCTestCase {
        private var accountName: String!

        override func setUp() {
            super.setUp()
            KeychainTokenStore.resetEnvironmentModeForTesting()
            // A unique name: if a bug ever reached the Keychain it could not
            // clobber a real account's token.
            accountName = "envtest\(UUID().uuidString.prefix(8))"
        }

        override func tearDown() {
            KeychainTokenStore.resetEnvironmentModeForTesting()
            KeychainTokenStore.delete(forge: .github, name: accountName)  // only reached when the Keychain mode is on
            super.tearDown()
        }

        private func useEnvironment(_ extra: [String: String] = [:]) {
            var merged = ["KINHIN_TOKEN_STORE": "env"]
            merged.merge(extra) { $1 }
            let env = merged
            KeychainTokenStore.environmentProvider = { env }
        }

        private var variable: String { KeychainTokenStore.environmentVariableName(for: accountName) }

        // MARK: - Names

        func testVariableNamesFollowTheAccountName() {
            XCTAssertEqual(KeychainTokenStore.environmentVariableName(for: "github"), "KINHIN_TOKEN_GITHUB")
            XCTAssertEqual(KeychainTokenStore.environmentVariableName(for: "gitea"), "KINHIN_TOKEN_GITEA")
            XCTAssertEqual(KeychainTokenStore.environmentVariableName(for: "work"), "KINHIN_TOKEN_WORK")
            XCTAssertEqual(KeychainTokenStore.environmentVariableName(for: "ci-bot"), "KINHIN_TOKEN_CI_BOT")
            XCTAssertEqual(KeychainTokenStore.environmentVariableName(for: "a.b c"), "KINHIN_TOKEN_A_B_C")
            XCTAssertEqual(KeychainTokenStore.environmentVariableName(for: "MixedCase9"), "KINHIN_TOKEN_MIXEDCASE9")
        }

        // MARK: - Mode selection

        func testOnlyTheExactEnvValueTurnsTheEnvironmentOn() {
            KeychainTokenStore.environmentProvider = { [:] }
            XCTAssertEqual(KeychainTokenStore.mode, .keychain, "unset → Keychain")
            for value in ["keychain", "", "ENV", "true", "1"] {
                KeychainTokenStore.environmentProvider = { ["KINHIN_TOKEN_STORE": value] }
                XCTAssertEqual(KeychainTokenStore.mode, .keychain, "'\(value)' must not enable env mode")
            }
            useEnvironment()
            XCTAssertEqual(KeychainTokenStore.mode, .environment)
        }

        func testAThrowawayKeychainServiceAlwaysWinsSoTestsStayHermetic() {
            useEnvironment()
            KeychainTokenStore.serviceOverride = "com.kinhin.runner.tests.\(UUID().uuidString)"
            defer { KeychainTokenStore.serviceOverride = nil }
            XCTAssertEqual(KeychainTokenStore.mode, .keychain)
        }

        // MARK: - Reading

        func testLoadReturnsTheTrimmedValue() throws {
            useEnvironment([variable: "  ghp_abc123\n"])
            XCTAssertEqual(try KeychainTokenStore.load(forge: .github, name: accountName), "ghp_abc123")
        }

        func testMissingEmptyAndBlankReadAsNoToken() throws {
            useEnvironment()
            XCTAssertNil(try KeychainTokenStore.load(forge: .github, name: accountName), "unset")
            useEnvironment([variable: ""])
            XCTAssertNil(try KeychainTokenStore.load(forge: .github, name: accountName), "empty")
            useEnvironment([variable: "   \n"])
            XCTAssertNil(try KeychainTokenStore.load(forge: .github, name: accountName), "blank")
        }

        func testPrimaryAccountsReadTheirForgeVariable() throws {
            useEnvironment(["KINHIN_TOKEN_GITHUB": "ghp_primary", "KINHIN_TOKEN_GITEA": "gt_primary"])
            XCTAssertEqual(try KeychainTokenStore.load(forge: .github), "ghp_primary")
            XCTAssertEqual(try KeychainTokenStore.load(forge: .gitea), "gt_primary")
        }

        // MARK: - Saving stays in memory

        func testSavedTokensLastForTheSessionAndBeatTheEnvironment() throws {
            useEnvironment([variable: "from-env"])
            try KeychainTokenStore.save("typed-in-ui", forge: .github, name: accountName)
            XCTAssertEqual(try KeychainTokenStore.load(forge: .github, name: accountName), "typed-in-ui")

            KeychainTokenStore.delete(forge: .github, name: accountName)
            XCTAssertEqual(
                try KeychainTokenStore.load(forge: .github, name: accountName), "from-env",
                "deleting clears the session value only; the environment is left alone")
        }

        func testNothingReachesTheKeychainInEnvironmentMode() throws {
            useEnvironment()
            try KeychainTokenStore.save("must-not-persist", forge: .github, name: accountName)
            KeychainTokenStore.delete(forge: .github, name: accountName)
            try KeychainTokenStore.save("must-not-persist", forge: .github, name: accountName)

            // Look in the real Keychain (mode switched back) for the unique account.
            KeychainTokenStore.environmentProvider = { [:] }
            XCTAssertNil(try KeychainTokenStore.load(forge: .github, name: accountName))
        }

        // MARK: - Through a real call site

        func testEngineTokenSeesTheEnvironmentToken() throws {
            var cfg = KinhinConfig.default
            cfg.accounts = [AccountConfig(name: accountName, forge: .github, scope: "acme/widgets")]

            useEnvironment()
            XCTAssertNil(try ConfigLoader.engineToken(for: cfg), "no variable → no usable forge")

            useEnvironment([variable: "ghp_dev"])
            XCTAssertNotNil(try ConfigLoader.engineToken(for: cfg), "the variable makes the account usable")
        }
    }
#endif
