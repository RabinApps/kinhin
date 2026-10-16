import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The LLM tier: `/api/chat` with the answer's JSON schema as `format`.
final class OllamaHealingAdvisorTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func advisor() -> OllamaHealingAdvisor {
        OllamaHealingAdvisor(host: OllamaTestSupport.host, model: "my-llm", session: OllamaTestSupport.session())
    }

    /// Answers `/api/chat` with `content` as the model's reply, and records the request body.
    private func answerChat(_ content: String, log: OllamaRequestLog) {
        StubProtocol.handler = { request in
            log.record(request)
            let reply: [String: Any] = ["message": ["role": "assistant", "content": content]]
            return (200, (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(), [:])
        }
    }

    func testTheNameShowsTheModel() {
        XCTAssertEqual(advisor().name, "ollama:my-llm")
    }

    func testTheRequestAsksTheModelOnceWithTheSchemaAndNoStreaming() async throws {
        let log = OllamaRequestLog()
        answerChat(#"{"remediation":"none","confident":false,"explanation":"nothing fits"}"#, log: log)
        _ = try await advisor().advise(OllamaTestSupport.request)
        let body = try XCTUnwrap(log.last)
        XCTAssertEqual(body["model"] as? String, "my-llm")
        XCTAssertEqual(body["stream"] as? Bool, false)
        let format = try XCTUnwrap(body["format"] as? [String: Any])
        let properties = try XCTUnwrap(format["properties"] as? [String: Any])
        let remediation = try XCTUnwrap(properties["remediation"] as? [String: Any])
        // The reply can only be a candidate's id or none: the allowlist is in the schema.
        XCTAssertEqual(remediation["enum"] as? [String], ["retry_forge_attach", "none"])
        let options = try XCTUnwrap(body["options"] as? [String: Any])
        XCTAssertEqual(options["temperature"] as? Int, 0)
        XCTAssertEqual(options["num_ctx"] as? Int, HealingPrompt.ollamaContextTokens)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["content"], HealingPrompt.instructions)
        XCTAssertTrue(messages.last?["content"]?.contains("HTTP 503 from gitea.local") ?? false)
    }

    func testAPickAndItsConfidenceComeBack() async throws {
        let log = OllamaRequestLog()
        answerChat(
            #"{"remediation":"retry_forge_attach","confident":true,"explanation":"HTTP 503 means the forge is down."}"#,
            log: log)
        let advice = try await advisor().advise(OllamaTestSupport.request)
        XCTAssertEqual(advice?.remediation, "retry_forge_attach")
        XCTAssertEqual(advice?.confident, true)
        XCTAssertEqual(advice?.selfReported, true)
        XCTAssertEqual(advice?.model, "my-llm")
    }

    func testNoneIsNoFix() async throws {
        let log = OllamaRequestLog()
        answerChat(#"{"remediation":"none","confident":false,"explanation":"nothing fits"}"#, log: log)
        let advice = try await advisor().advise(OllamaTestSupport.request)
        XCTAssertNil(advice?.remediation)
        XCTAssertEqual(advice?.explanation, "nothing fits")
    }

    func testTheExplanationIsRedacted() async throws {
        let log = OllamaRequestLog()
        answerChat(
            #"{"remediation":"none","confident":false,"explanation":"auth with ghp_abcdefghijklmnopqrstuvwxyz0123456789"}"#,
            log: log)
        let advice = try await advisor().advise(OllamaTestSupport.request)
        XCTAssertFalse(advice?.explanation.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789") ?? true)
    }

    func testAReplyThatIsNotTheAnswerShapeThrows() async {
        let log = OllamaRequestLog()
        answerChat("I think you should restart it.", log: log)
        do {
            _ = try await advisor().advise(OllamaTestSupport.request)
            XCTFail("a free-text reply is not an answer")
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

    /// Real answers from a local chat model on the default server. Set KINHIN_LIVE_OLLAMA=1; the model
    /// is `gemma4:e2b` unless KINHIN_LIVE_OLLAMA_LLM names another one (it must be pulled already).
    func testLiveAnswersFromALocalChatModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KINHIN_LIVE_OLLAMA"] == "1" else {
            throw XCTSkip("set KINHIN_LIVE_OLLAMA=1 to call a local chat model")
        }
        let model = environment["KINHIN_LIVE_OLLAMA_LLM"] ?? "gemma4:e2b"
        let live = OllamaHealingAdvisor(host: KinhinConfig.HealingConfig.OllamaConfig.defaultHost, model: model)
        guard await live.isAvailable() else { throw XCTSkip("\(model) is not ready on this Mac") }

        let vmGone = HealingAdviceRequest(
            signal: HealingSignal(
                kind: .instanceGone, subject: "kinhin-1-a", detail: "warm VM kinhin-1-a is not in tart list"),
            candidates: [Remediation(.recycleInstance, subject: "kinhin-1-a")],
            context: "warn engine: tart list has no VM named kinhin-1-a")
        let recycle = try await live.advise(vmGone)
        XCTAssertEqual(recycle?.remediation, "recycle_instance")
        XCTAssertEqual(recycle?.model, model)

        let noise = HealingAdviceRequest(
            signal: HealingSignal(kind: .queueUnreadable, subject: "gitea", detail: "queue fetch failed for gitea"),
            candidates: [Remediation(.retryForgeAttach, subject: "gitea")],
            context: "info engine: heartbeat ok\ninfo engine: 0 jobs queued")
        let quiet = try await live.advise(noise)
        XCTAssertNil(quiet?.remediation)
        XCTAssertFalse(quiet?.explanation.isEmpty ?? true)
    }

    func testTheSchemaListsExactlyTheCandidatesAndNone() {
        let schema = OllamaHealingAdvisor.schema(kinds: ["prune_images"])
        let properties = schema["properties"] as? [String: Any]
        let remediation = properties?["remediation"] as? [String: Any]
        XCTAssertEqual(remediation?["enum"] as? [String], ["prune_images", "none"])
        XCTAssertEqual(schema["required"] as? [String], ["remediation", "confident", "explanation"])
    }
}
