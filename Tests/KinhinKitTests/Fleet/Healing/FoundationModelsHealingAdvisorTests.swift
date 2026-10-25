#if canImport(FoundationModels)
    import FoundationModels
    import XCTest

    @testable import KinhinKit

    /// The Foundation Models advisor: the prompt and schema everywhere, and one
    /// real on-device call with KINHIN_LIVE_AI=1 on a Mac with Apple Intelligence.
    final class FoundationModelsHealingAdvisorTests: XCTestCase {
        private let request = HealingAdviceRequest(
            signal: HealingSignal(kind: .queueUnreadable, subject: "gitea", detail: "HTTP 503 from gitea.local"),
            candidates: [Remediation(.retryForgeAttach, subject: "gitea")],
            context: "warn engine: queue fetch failed for gitea: HTTP 503\nwarn engine: holding scale-down")

        func testTheSchemaBuilds() throws {
            guard #available(macOS 26, *) else { throw XCTSkip("Foundation Models needs macOS 26") }
            XCTAssertNoThrow(try FoundationModelsHealingAdvisor.schema(for: request.candidates))
        }

        func testNoCandidatesMeansNoQuestion() async throws {
            let empty = HealingAdviceRequest(signal: request.signal, candidates: [], context: "")
            let advice = try await FoundationModelsHealingAdvisor().advise(empty)
            XCTAssertNil(advice)
        }

        func testASlowAnswerTimesOut() async {
            do {
                _ = try await FoundationModelsHealingAdvisor.withDeadline(0.05) {
                    try await Task.sleep(for: .seconds(5))
                    return 1
                }
                XCTFail("expected a timeout")
            } catch {
                XCTAssertTrue("\(error.localizedDescription)".contains("did not answer"))
            }
        }

        /// One real generation: the pick is a candidate or nothing, with an explanation, in time.
        func testLiveAdviceStaysInTheAllowlist() async throws {
            guard ProcessInfo.processInfo.environment["KINHIN_LIVE_AI"] == "1" else {
                throw XCTSkip("set KINHIN_LIVE_AI=1 to call the on-device model")
            }
            let advisor = FoundationModelsHealingAdvisor()
            guard await advisor.isAvailable() else { throw XCTSkip("Apple Intelligence is not available here") }
            let started = Date()
            let advice = try await advisor.advise(request)
            let elapsed = Date().timeIntervalSince(started)
            if let pick = advice?.remediation {
                XCTAssertEqual(pick, "retry_forge_attach")
            }
            XCTAssertFalse(advice?.explanation.isEmpty ?? true, "no explanation")
            XCTAssertLessThan(elapsed, advisor.timeout)
            print("live advice: \(String(describing: advice)) in \(String(format: "%.1f", elapsed))s")
        }
    }
#endif
