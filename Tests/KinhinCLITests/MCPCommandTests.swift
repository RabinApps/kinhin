import XCTest

@testable import kinhin

/// The MCP protocol surface: framing, the handshake, `tools/list`,
/// `tools/call` and the error contract. Tool handlers are injected, so
/// nothing here touches the daemon, the Keychain, the config, or the network.
final class MCPCommandTests: XCTestCase {
    // MARK: - test doubles

    /// Returns the arguments as the payload (or `{}` when none) — enough to
    /// prove the plumbing without any real command behavior.
    private static let echo = MCPTool(
        name: "echo",
        description: "Echoes the call's arguments back (test double).",
        inputSchema: MCPTool.InputSchema(),
        run: { arguments in arguments ?? Data("{}".utf8) }
    )

    private func server(tools: [MCPTool] = [MCPCommandTests.echo]) -> MCPServer {
        MCPServer(tools: tools)
    }

    private func handle(_ line: String, tools: [MCPTool] = [MCPCommandTests.echo]) async throws -> [String: Any] {
        let response = await server(tools: tools).handle(line)
        let text = try XCTUnwrap(response, "a request with an id must be answered")
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - handshake

    func testInitializeEchoesTheClientVersionAndIdentifiesTheServer() async throws {
        let response = try await handle(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}"#
        )
        XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(response["id"] as? Int, 1)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
        let info = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "kinhin")
        XCTAssertNotNil(result["capabilities"] as? [String: Any])
        let instructions = try XCTUnwrap(result["instructions"] as? String)
        XCTAssertTrue(instructions.contains("reset"), "the safety contract must travel with the handshake")
    }

    func testInitializeWithoutAClientVersionFallsBackToTheServers() async throws {
        let response = try await handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, MCPServer.protocolVersion)
    }

    func testPingAnswersAnEmptyResult() async throws {
        let response = try await handle(#"{"jsonrpc":"2.0","id":"p","method":"ping"}"#)
        XCTAssertEqual(response["id"] as? String, "p")
        XCTAssertNotNil(response["result"] as? [String: Any])
    }

    // MARK: - tools/list

    func testToolsListAdvertisesEachToolWithItsSchema() async throws {
        let response = try await handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"] as? String, "echo")
        XCTAssertFalse((tools[0]["description"] as? String ?? "").isEmpty)
        let schema = try XCTUnwrap(tools[0]["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
    }

    func testShippedRegistryIsUniqueWellFormedAndKeepsDangerOut() {
        let names = MCPTool.all.map(\.name)
        // Pinned so the advertised surface can't silently change.
        XCTAssertEqual(
            names,
            [
                "status", "doctor", "setup_status", "runtimes", "auth_status", "pipeline", "logs", "heal_status",
                "pause", "resume", "stop", "daemon_install",
            ])
        XCTAssertEqual(Set(names).count, names.count, "tool names must be unique")
        for tool in MCPTool.all {
            XCTAssertFalse(tool.description.isEmpty, "\(tool.name) needs a description agents can act on")
            XCTAssertEqual(tool.inputSchema.type, "object")
        }
        // The safety contract: irreversible, secret-bearing or blocking work
        // is never reachable through the server.
        // Approving a healing fix stays with a person.
        for forbidden in [
            "reset", "cleanup", "start", "watch", "auth_set", "daemon_uninstall", "heal_approve", "heal_dismiss",
        ] {
            XCTAssertFalse(names.contains(forbidden), "\(forbidden) must not be exposed over MCP")
        }
    }

    // MARK: - tools/call

    func testToolsCallReturnsThePayloadAsTextContent() async throws {
        let response = try await handle(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"note":"hi"}}}"#
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertTrue((content[0]["text"] as? String ?? "").contains("hi"))
    }

    func testFailingToolAnswersIsErrorInBandNotAProtocolError() async throws {
        let failing = MCPTool(
            name: "boom",
            description: "Always fails (test double).",
            inputSchema: MCPTool.InputSchema(),
            run: { _ in throw MCPToolError("cannot do that") }
        )
        let response = try await handle(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"boom"}}"#, tools: [failing])
        XCTAssertNil(response["error"], "a failed tool call is content, not a JSON-RPC error")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertTrue((content[0]["text"] as? String ?? "").contains("cannot do that"))
    }

    func testUnknownToolIsInvalidParams() async throws {
        let response = try await handle(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope"}}"#)
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertTrue((error["message"] as? String ?? "").contains("nope"))
    }

    func testToolsCallWithoutANameIsInvalidParams() async throws {
        let response = try await handle(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{}}"#)
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    // MARK: - protocol errors and notifications

    func testUnknownMethodIsMethodNotFound() async throws {
        let response = try await handle(#"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#)
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    func testMalformedLineGetsParseErrorWithNullId() async throws {
        let response = try await handle("{not json")
        XCTAssertTrue(response["id"] is NSNull, "an unparseable message has no id to answer")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32700)
    }

    func testNotificationGetsNoAnswer() async {
        let response = await server().handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(response)
    }

    func testBlankLinesGetNoAnswer() async {
        let server = self.server()
        let empty = await server.handle("")
        XCTAssertNil(empty)
        let spaces = await server.handle("   ")
        XCTAssertNil(spaces)
    }

    func testResponseIsOneCompactLineWithSortedKeys() async throws {
        let response = await server().handle(#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#)
        let text = try XCTUnwrap(response)
        XCTAssertFalse(text.contains("\n"), "the stdio transport is one message per line")
        XCTAssertTrue(text.hasPrefix(#"{"id":9,"jsonrpc":"2.0","result":{}}"#), "got: \(text)")
    }
}
