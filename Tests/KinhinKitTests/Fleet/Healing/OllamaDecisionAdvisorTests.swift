import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The System 1 tier: `/v1/systemone`, one `choice` question over the candidates and `none`.
final class OllamaDecisionAdvisorTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func advisor(model: String = "clef-flash") -> OllamaDecisionAdvisor {
        OllamaDecisionAdvisor(host: OllamaTestSupport.host, model: model, session: OllamaTestSupport.session())
    }

    /// Answers `/v1/systemone` with `reply` (the endpoint's JSON) and records the request body.
    private func answerDecision(_ reply: String, log: OllamaRequestLog) {
        StubProtocol.handler = { request in
            log.record(request)
            return (200, OllamaTestSupport.json(reply), [:])
        }
    }

    private func choiceReply(_ choice: String, probability: Double) -> String {
        #"{"answers":{"fix":{"choice":"\#(choice)","probabilities":{"\#(choice)":\#(probability)},"confidence":0.5}},"usage":{"input_tokens":10,"output_tokens":1}}"#
    }

    func testTheNameShowsTheModelAndTheMinimumVersionDependsOnIt() {
        XCTAssertEqual(advisor().name, "ollama:clef-flash")
        XCTAssertEqual(OllamaDecisionAdvisor.minimumVersion(for: "clef-flash"), "0.35.1")
        XCTAssertEqual(OllamaDecisionAdvisor.minimumVersion(for: "nimble-v3:9b"), "0.40.4")
    }

    func testTheRequestIsOneChoiceQuestionOverTheCandidatesAndNone() async throws {
        let log = OllamaRequestLog()
        answerDecision(choiceReply("retry_forge_attach", probability: 0.95), log: log)
        _ = try await advisor().advise(OllamaTestSupport.request)
        let body = try XCTUnwrap(log.last)
        XCTAssertEqual(body["model"] as? String, "clef-flash")
        let questions = try XCTUnwrap(body["questions"] as? [String: Any])
        let fix = try XCTUnwrap(questions["fix"] as? [String: Any])
        XCTAssertEqual(fix["type"] as? String, "choice")
        let criteria = try XCTUnwrap(fix["criteria"] as? [String: String])
        XCTAssertEqual(Set(criteria.keys), ["retry_forge_attach", "none"])
        let state = try XCTUnwrap(body["state"] as? String)
        XCTAssertTrue(state.contains("HTTP 503 from gitea.local"))
    }

    func testAConfidentCandidateIsFinal() async throws {
        let log = OllamaRequestLog()
        answerDecision(choiceReply("retry_forge_attach", probability: 0.95), log: log)
        let advice = try await advisor().advise(OllamaTestSupport.request)
        XCTAssertEqual(advice?.remediation, "retry_forge_attach")
        XCTAssertEqual(advice?.confident, true)
        XCTAssertEqual(advice?.model, "clef-flash")
        XCTAssertEqual(advice?.explanation, "System 1 (clef-flash) chose retry_forge_attach with 95% probability")
    }

    func testACandidateBelowTheThresholdIsNotConfident() async throws {
        let log = OllamaRequestLog()
        answerDecision(choiceReply("retry_forge_attach", probability: 0.6), log: log)
        let advice = try await advisor().advise(OllamaTestSupport.request)
        XCTAssertEqual(advice?.remediation, "retry_forge_attach")
        XCTAssertEqual(advice?.confident, false)
    }

    func testNoneIsNoFixAndSaysSo() async throws {
        let log = OllamaRequestLog()
        answerDecision(choiceReply("none", probability: 0.9), log: log)
        let advice = try await advisor().advise(OllamaTestSupport.request)
        XCTAssertNil(advice?.remediation)
        XCTAssertEqual(advice?.explanation, "System 1 (clef-flash) found no listed fix addresses the problem (90%)")
    }

    func testAChoiceOutsideTheOptionsThrows() async {
        let log = OllamaRequestLog()
        answerDecision(choiceReply("run_shell_command", probability: 0.99), log: log)
        do {
            _ = try await advisor().advise(OllamaTestSupport.request)
            XCTFail("an option kinhin did not offer is not an answer")
        } catch {}
    }

    func testAReplyWithNoChoiceThrows() async {
        let log = OllamaRequestLog()
        answerDecision(#"{"answers":{},"usage":{}}"#, log: log)
        do {
            _ = try await advisor().advise(OllamaTestSupport.request)
            XCTFail("a reply without the question's answer is not advice")
        } catch {}
    }

    func testNoCandidatesMeansNoQuestion() async throws {
        StubProtocol.handler = { _ in
            XCTFail("no request should be sent without candidates")
            return (500, Data(), [:])
        }
        let empty = HealingAdviceRequest(signal: OllamaTestSupport.request.signal, candidates: [], context: "")
        let advice = try await advisor().advise(empty)
        XCTAssertNil(advice)
    }

    /// Real decisions from `clef-flash` on the default local server. Set KINHIN_LIVE_OLLAMA=1 after
    /// `ollama pull clef-flash`; this sends the advisor's own request, not a copy of it.
    func testLiveDecisionsFromClefFlash() async throws {
        guard ProcessInfo.processInfo.environment["KINHIN_LIVE_OLLAMA"] == "1" else {
            throw XCTSkip("set KINHIN_LIVE_OLLAMA=1 to call a local clef-flash")
        }
        let live = OllamaDecisionAdvisor(
            host: KinhinConfig.HealingConfig.OllamaConfig.defaultHost, model: "clef-flash")
        guard await live.isAvailable() else { throw XCTSkip("clef-flash is not ready on this Mac") }

        let vmGone = HealingAdviceRequest(
            signal: HealingSignal(
                kind: .instanceGone, subject: "kinhin-1-a", detail: "warm VM kinhin-1-a is not in tart list"),
            candidates: [Remediation(.recycleInstance, subject: "kinhin-1-a")],
            context: "warn engine: tart list has no VM named kinhin-1-a")
        let recycle = try await live.advise(vmGone)
        XCTAssertEqual(recycle?.remediation, "recycle_instance")
        XCTAssertEqual(recycle?.confident, true)

        let noise = HealingAdviceRequest(
            signal: HealingSignal(kind: .queueUnreadable, subject: "gitea", detail: "queue fetch failed for gitea"),
            candidates: [Remediation(.retryForgeAttach, subject: "gitea")],
            context: "info engine: heartbeat ok\ninfo engine: 0 jobs queued")
        let quiet = try await live.advise(noise)
        XCTAssertNil(quiet?.remediation)
    }
}
