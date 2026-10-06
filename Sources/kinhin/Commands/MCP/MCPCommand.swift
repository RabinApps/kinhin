import Foundation
import KinhinKit

/// `kinhin mcp` — the MCP server on stdio: one JSON-RPC message per line in,
/// one compact line out. Stdout carries protocol messages only, so the server
/// never prints prose (its one startup note goes to stderr) — which is also
/// why every tool reuses a command's non-printing core instead of running the
/// command itself.
///
/// The client closing stdin ends the loop. Ctrl-C falls to the default SIGINT
/// disposition: KinhinCLI runs this command without the interrupt bridge,
/// because a cooperative cancel cannot interrupt a blocked stdin read.
enum MCPCommand {
    static func run(_ args: [String]) async throws {
        guard args.dropFirst().isEmpty else {
            fail("usage: kinhin mcp — no arguments; the server speaks JSON-RPC on stdin/stdout", exit: .usage)
        }
        printError("kinhin mcp: serving \(MCPTool.all.count) tools on stdio (JSON-RPC over stdin/stdout)")
        let server = MCPServer()
        for await line in Self.stdinLines() {
            guard let response = await server.handle(line) else { continue }
            // Written unbuffered: piped stdout would otherwise hold answers back.
            FileHandle.standardOutput.write(Data((response + "\n").utf8))
        }
    }

    /// stdin as lines. `readLine` blocks, so it runs on a dedicated thread
    /// instead of the cooperative pool, which the tool handlers still need.
    private static func stdinLines() -> AsyncStream<String> {
        AsyncStream { continuation in
            Thread.detachNewThread {
                while let line = readLine(strippingNewline: true) {
                    continuation.yield(line)
                }
                continuation.finish()
            }
        }
    }
}
