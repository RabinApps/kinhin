import Foundation
import KinhinKit

/// The MCP server: JSON-RPC 2.0, one message per line, over stdio (the MCP
/// stdio transport). Protocol framing only — every tool lives in `MCPTool`.
///
/// Hand-rolled on purpose: the package's only dependency is Yams, and the MCP
/// surface kinhin needs is `initialize`, `ping`, `tools/list` and
/// `tools/call`. Notifications (no `id`) get no answer; a malformed line gets
/// `-32700`; a failed tool call answers with `isError: true` content, not a
/// protocol error.
struct MCPServer {
    /// Injectable so tests can drive the protocol with fake tools.
    var tools: [MCPTool] = MCPTool.all

    /// The version spoken with clients that don't send one. Requests carry
    /// their own `protocolVersion`, which is echoed back — what clients expect.
    static let protocolVersion = "2025-06-18"

    /// What `initialize` tells the client about the server's scope, so an
    /// agent learns the safety rules without trial and error.
    static let instructions = """
        Read-only tools mirror the kinhin CLI's --json documents. Fleet control is \
        limited to pause, resume, stop and daemon_install: reset, cleanup --yes, \
        token entry, and blocking commands (start, watch) are deliberately not \
        exposed here — ask the user to run those in a terminal.
        """

    /// Handles one input line; nil means "no answer" (a notification or an
    /// empty line). Output is one compact JSON line with sorted keys, so tests
    /// and humans can diff it.
    func handle(_ line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return await handle(data)
    }

    func handle(_ data: Data) async -> String? {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return line(Self.errorResponse(id: nil, code: -32700, message: "parse error"))
        }
        guard let request = object as? [String: Any] else {
            return line(Self.errorResponse(id: nil, code: -32600, message: "invalid request"))
        }
        guard let method = request["method"] as? String else {
            // Without a method there is nothing to dispatch; answer only when
            // the sender left an id to answer (a bare object is a no-op).
            if let id = request["id"], !(id is NSNull) {
                return line(Self.errorResponse(id: id, code: -32600, message: "invalid request: missing method"))
            }
            return nil
        }
        // A notification (initialized, cancelled, …): never answered.
        guard let id = request["id"], !(id is NSNull) else { return nil }

        switch method {
        case "initialize":
            return line(Self.resultResponse(id: id, initializeResult(request)))
        case "ping":
            return line(Self.resultResponse(id: id, [:]))
        case "tools/list":
            do {
                return line(Self.resultResponse(id: id, try toolsListResult()))
            } catch {
                return line(Self.errorResponse(id: id, code: -32603, message: "could not list tools: \(error)"))
            }
        case "tools/call":
            switch await toolsCall(request["params"]) {
            case .result(let result):
                return line(Self.resultResponse(id: id, result))
            case .error(let code, let message):
                return line(Self.errorResponse(id: id, code: code, message: message))
            }
        default:
            return line(Self.errorResponse(id: id, code: -32601, message: "method not found: \(method)"))
        }
    }

    // MARK: - Methods

    private func initializeResult(_ request: [String: Any]) -> [String: Any] {
        let requested = (request["params"] as? [String: Any])?["protocolVersion"] as? String
        return [
            "protocolVersion": requested ?? Self.protocolVersion,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "kinhin", "version": kinhinVersion.current],
            "instructions": Self.instructions,
        ]
    }

    private func toolsListResult() throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let advertisements: [[String: Any]] = try tools.map { tool in
            let schema = try JSONSerialization.jsonObject(with: try encoder.encode(tool.inputSchema))
            return ["name": tool.name, "description": tool.description, "inputSchema": schema]
        }
        return ["tools": advertisements]
    }

    private enum CallOutcome {
        case result([String: Any])
        case error(code: Int, message: String)
    }

    private func toolsCall(_ params: Any?) async -> CallOutcome {
        guard let params = params as? [String: Any], let name = params["name"] as? String else {
            return .error(code: -32602, message: "invalid params: tools/call needs params.name")
        }
        guard let tool = tools.first(where: { $0.name == name }) else {
            return .error(code: -32602, message: "unknown tool: \(name)")
        }
        var arguments: Data?
        if let raw = params["arguments"] {
            guard JSONSerialization.isValidJSONObject(raw) else {
                return .error(code: -32602, message: "invalid params: arguments must be a JSON object")
            }
            guard let data = try? JSONSerialization.data(withJSONObject: raw) else {
                return .error(code: -32603, message: "could not encode the tool arguments")
            }
            arguments = data
        }
        do {
            let payload = try await tool.run(arguments)
            return .result(Self.toolResult(text: String(decoding: payload, as: UTF8.self), isError: false))
        } catch {
            // LocalizedError's description is the user-readable message.
            return .result(Self.toolResult(text: error.localizedDescription, isError: true))
        }
    }

    // MARK: - Response shapes

    private static func toolResult(text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private static func resultResponse(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private func line(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"internal error"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
