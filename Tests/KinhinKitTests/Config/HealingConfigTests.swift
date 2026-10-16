import XCTest

@testable import KinhinKit

final class HealingConfigTests: XCTestCase {
    private let accounts = """
        accounts:
          - name: github
            forge: github
            scope: acme/widgets

        """

    func testDefaultsWhenAbsent() throws {
        let config = try ConfigLoader.parse(accounts)
        XCTAssertEqual(config.healing, .default)
        XCTAssertTrue(config.healing.enabled)
        XCTAssertEqual(config.healing.auto, .safe)
        XCTAssertEqual(config.healing.ai, .auto)
        XCTAssertEqual(config.healing.maxAttempts, 3)
    }

    func testEveryKeyParses() throws {
        let config = try ConfigLoader.parse(
            accounts + """
                healing:
                  enabled: false
                  auto: none
                  ai: off
                  max_attempts: 5
                """)
        XCTAssertEqual(
            config.healing, KinhinConfig.HealingConfig(enabled: false, auto: .none, ai: .off, maxAttempts: 5))
    }

    func testBadValuesAreRejectedByName() {
        XCTAssertThrowsError(try ConfigLoader.parse(accounts + "healing:\n  auto: sometimes\n")) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("healing.auto"))
        }
        XCTAssertThrowsError(try ConfigLoader.parse(accounts + "healing:\n  ai: cloud\n")) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("healing.ai"))
        }
        XCTAssertThrowsError(try ConfigLoader.parse(accounts + "healing:\n  max_attempts: 0\n")) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("healing.max_attempts"))
        }
    }

    func testUnknownKeysAreReported() {
        XCTAssertThrowsError(try ConfigLoader.parse(accounts + "healing:\n  enable: true\n")) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("healing.enable"))
        }
    }

    func testAPolicyChangeRebuildsTheEngine() {
        var changed = KinhinConfig.default
        changed.healing.auto = .none
        XCTAssertTrue(FleetEngine.restartRequired(from: .default, to: changed))
    }

    // MARK: - ai: ollama

    private func ollama(_ block: String, ai: String = "ollama") -> String {
        accounts + "healing:\n  ai: \(ai)\n  ollama:\n" + block
    }

    func testAnOllamaBlockParsesWithItsDefaultHost() throws {
        let config = try ConfigLoader.parse(ollama("    model: my-llm\n    fast_model: clef-flash\n"))
        XCTAssertEqual(config.healing.ai, .ollama)
        XCTAssertEqual(
            config.healing.ollama,
            KinhinConfig.HealingConfig.OllamaConfig(model: "my-llm", fastModel: "clef-flash"))
    }

    func testTheFastModelIsOptional() throws {
        let config = try ConfigLoader.parse(ollama("    model: my-llm\n"))
        XCTAssertNil(config.healing.ollama?.fastModel)
        XCTAssertEqual(config.healing.ollama?.model, "my-llm")
    }

    func testAHostOnThisMacMayBePlainHTTPAndAnotherHostMustBeHTTPS() throws {
        let local = try ConfigLoader.parse(ollama("    model: m\n    host: http://localhost:11434\n"))
        XCTAssertEqual(local.healing.ollama?.host.absoluteString, "http://localhost:11434")
        let remote = try ConfigLoader.parse(ollama("    model: m\n    host: https://ollama.example.com\n"))
        XCTAssertEqual(remote.healing.ollama?.host.absoluteString, "https://ollama.example.com")
        XCTAssertThrowsError(try ConfigLoader.parse(ollama("    model: m\n    host: http://ollama.example.com\n"))) {
            error in
            XCTAssertTrue("\(error.localizedDescription)".contains("healing.ollama.host"))
        }
    }

    func testAHostThatIsNotAURLIsRejected() {
        XCTAssertThrowsError(try ConfigLoader.parse(ollama("    model: m\n    host: ollama box\n"))) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("healing.ollama.host"))
        }
    }

    func testTheModelIsRequiredWithOllamaMode() {
        XCTAssertThrowsError(try ConfigLoader.parse(accounts + "healing:\n  ai: ollama\n")) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("healing.ollama"))
        }
        XCTAssertThrowsError(try ConfigLoader.parse(ollama("    fast_model: clef-flash\n"))) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("healing.ollama.model"))
        }
    }

    func testAnOllamaBlockNeedsOllamaMode() {
        XCTAssertThrowsError(try ConfigLoader.parse(ollama("    model: my-llm\n", ai: "auto"))) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("healing.ollama"))
        }
    }

    func testTheFastModelMustBeADifferentModel() {
        XCTAssertThrowsError(try ConfigLoader.parse(ollama("    model: my-llm\n    fast_model: my-llm\n"))) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("fast_model"))
        }
    }

    func testAMisspelledOllamaKeyIsReported() {
        XCTAssertThrowsError(try ConfigLoader.parse(ollama("    model: m\n    modle: typo\n"))) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("healing.ollama.modle"))
        }
    }
}
