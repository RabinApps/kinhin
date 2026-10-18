import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The shared Ollama client: model names, versions, and whether a model is ready.
final class OllamaClientTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func client() -> OllamaClient {
        OllamaClient(host: OllamaTestSupport.host, session: OllamaTestSupport.session())
    }

    func testAVersionIsAtLeastItsMinimumPartByPart() {
        XCTAssertTrue(OllamaClient.isVersion("0.40.4", atLeast: "0.35.1"))
        XCTAssertTrue(OllamaClient.isVersion("0.35.1", atLeast: "0.35.1"))
        XCTAssertFalse(OllamaClient.isVersion("0.35.0", atLeast: "0.35.1"))
        // Compared as numbers, not as text: 9 is below 10.
        XCTAssertFalse(OllamaClient.isVersion("0.9.9", atLeast: "0.10.0"))
        XCTAssertTrue(OllamaClient.isVersion("1.0", atLeast: "0.99.9"))
        XCTAssertTrue(OllamaClient.isVersion("0.40.4-rc1", atLeast: "0.40.4"))
    }

    func testAModelNameWithoutATagMeansLatest() {
        XCTAssertTrue(OllamaClient.has("clef-flash", in: ["clef-flash:latest"]))
        XCTAssertTrue(OllamaClient.has("clef-flash:9b", in: ["clef-flash:9b"]))
        XCTAssertFalse(OllamaClient.has("clef-flash", in: ["clef-flash:9b"]))
        XCTAssertFalse(OllamaClient.has("nimble", in: ["nimble-v3:latest"]))
    }

    func testAModelThatIsPulledAndNewEnoughIsReady() async {
        StubProtocol.handler = { request in
            switch request.url?.path {
            case "/api/tags": return (200, OllamaTestSupport.json(#"{"models":[{"name":"clef-flash:latest"}]}"#), [:])
            case "/api/version": return (200, OllamaTestSupport.json(#"{"version":"0.40.4"}"#), [:])
            default: return (404, Data(), [:])
            }
        }
        let ready = await client().isReady(model: "clef-flash", minimumVersion: "0.35.1")
        XCTAssertTrue(ready)
    }

    func testAMissingModelIsNotReady() async {
        StubProtocol.handler = { request in
            switch request.url?.path {
            case "/api/tags": return (200, OllamaTestSupport.json(#"{"models":[]}"#), [:])
            default: return (200, OllamaTestSupport.json(#"{"version":"0.40.4"}"#), [:])
            }
        }
        let ready = await client().isReady(model: "clef-flash", minimumVersion: "0.35.1")
        XCTAssertFalse(ready)
    }

    func testAnOlderServerIsNotReady() async {
        StubProtocol.handler = { request in
            switch request.url?.path {
            case "/api/tags": return (200, OllamaTestSupport.json(#"{"models":[{"name":"nimble-v3:latest"}]}"#), [:])
            default: return (200, OllamaTestSupport.json(#"{"version":"0.35.1"}"#), [:])
            }
        }
        let ready = await client().isReady(model: "nimble-v3", minimumVersion: "0.40.4")
        XCTAssertFalse(ready)
    }

    func testAServerThatIsDownIsNotReady() async {
        StubProtocol.handler = nil  // the stub fails the request, as a refused connection would
        let ready = await client().isReady(model: "clef-flash", minimumVersion: "0.35.1")
        XCTAssertFalse(ready)
    }

    func testAnErrorStatusThrowsWithTheEndpoint() async {
        StubProtocol.handler = { _ in (500, Data(), [:]) }
        do {
            _ = try await client().modelNames()
            XCTFail("expected an HTTP error")
        } catch {
            XCTAssertTrue("\(error.localizedDescription)".contains("HTTP 500"))
        }
    }
}
