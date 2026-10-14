import Foundation
import KinhinKit

/// One MCP tool: what the server advertises (`tools/list`) and the handler
/// that produces the JSON payload returned as the tool result's text content.
/// Handlers throw; `MCPServer` renders a throw as an `isError` tool result —
/// MCP's contract for a failed call, not a protocol error.
///
/// Every handler reuses a command's *non-printing* core: stdout belongs to the
/// protocol, so a tool may never run a command that prints prose or calls
/// `fail` (which exits the process).
struct MCPTool: Sendable {
    let name: String
    let description: String
    let inputSchema: InputSchema
    /// The tool's arguments as raw JSON (`nil` = none), and the payload to
    /// return as the result text.
    let run: @Sendable (_ arguments: Data?) async throws -> Data

    /// The JSON Schema shape MCP expects under `inputSchema`.
    struct InputSchema: Encodable, Sendable {
        var type = "object"
        var properties: [String: Property] = [:]
        var required: [String] = []

        struct Property: Encodable, Sendable {
            let type: String
            let description: String
        }

        static func only(_ properties: [String: Property], required: [String] = []) -> InputSchema {
            var schema = InputSchema()
            schema.properties = properties
            schema.required = required
            return schema
        }
    }
}

/// A tool-level failure with a user-readable message (bad arguments, refused
/// work): surfaced as `isError` text, never as a protocol error.
struct MCPToolError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// What the fleet-control tools return: `{"message": "…"}`.
struct MCPMessage: Encodable, Sendable {
    let message: String
}

/// The `logs` tool's payload — the log file's tail, redacted for tokens.
struct MCPLogDocument: Encodable, Sendable {
    let lines: [String]
    let path: String
    let count: Int
}

// MARK: - The registry

extension MCPTool {
    /// Every tool the server exposes.
    ///
    /// Read-only tools mirror the CLI's `--json` documents; fleet control is
    /// limited to what a user could undo in a terminal. Deliberately absent:
    /// `reset`, `cleanup --yes` and `auth set` (irreversible or
    /// secret-bearing), and everything that blocks (`start`, `watch`,
    /// `pipeline --follow`).
    static let all: [MCPTool] = [
        status, doctor, setupStatus, runtimes, authStatus, pipeline, logs, healStatus,
        pause, resume, stop, daemonInstall,
    ]

    /// Read-only on purpose: approving a fix stays with a person (`kinhin heal approve`).
    static let healStatus = MCPTool(
        name: "heal_status",
        description:
            "The healing agent's journal (`kinhin heal --json`): fixes it ran on its own, fixes waiting for a "
            + "person to approve with `kinhin heal approve ID`, and problems only the user can fix.",
        inputSchema: InputSchema(),
        run: { _ in try CLIJSON.data(await HealCommand.document(), dates: .iso8601) }
    )

    static let status = MCPTool(
        name: "status",
        description:
            "Fleet status as the JSON document `kinhin status --json` prints: daemon reachability, running/paused/autoResume, queue depth and its freshness.",
        inputSchema: InputSchema(),
        run: { _ in try mcpEncode(await RunCommands.statusDocument()) }
    )

    static let doctor = MCPTool(
        name: "doctor",
        description:
            "Prerequisites, stored tokens, runtime health, the computed capacity cap, per-runtime image disk usage "
            + "(`imageTotalGB`), the prune suggestion (`imagePrune`) and the disk-pressure warning "
            + "(`diskPressure`) — the `kinhin doctor --json` document.",
        inputSchema: InputSchema(),
        run: { _ in
            Paths.ensureSupportDirectories()
            return try mcpEncode(await DoctorCommand.document().data)
        }
    )

    static let setupStatus = MCPTool(
        name: "setup_status",
        description:
            "The first-run checklist (`kinhin setup-status --json`): every check, its detail, and ready: true when the fleet can start.",
        inputSchema: InputSchema(),
        run: { _ in
            Paths.ensureSupportDirectories()
            return try mcpEncode(await SetupStatusComputer().compute())
        }
    )

    static let runtimes = MCPTool(
        name: "runtimes",
        description:
            "Pools, capacity, budget split, health and routes — the `kinhin runtimes --json` document.",
        inputSchema: .only([
            "noHealth": .init(
                type: "boolean",
                description: "Skip probing each runtime's health (faster; availability then comes back empty).")
        ]),
        run: { arguments in
            let noHealth = try boolArgument("noHealth", in: arguments) ?? false
            return try await RuntimesCommand.loadSummary(noHealth: noHealth).json
        }
    )

    static let authStatus = MCPTool(
        name: "auth_status",
        description:
            "Which configured forges have a stored token and whether it's usable — the `kinhin auth status --json` report (tokens are never included).",
        inputSchema: InputSchema(),
        run: { _ in try mcpEncode(AuthCommand.statusReport()) }
    )

    static let pipeline = MCPTool(
        name: "pipeline",
        description:
            "The live pipeline (jobs and steps) the busy VMs are running — the `kinhin pipeline --json` document. Needs a running daemon.",
        inputSchema: .only([
            "vm": .init(type: "string", description: "Only this VM's pipeline (its id, e.g. kinhin-1)."),
            "job": .init(type: "string", description: "Only this job's steps (name or id)."),
        ]),
        run: { arguments in
            guard RPCClient.isDaemonAlive() else {
                throw MCPToolError(
                    "no daemon running; pipelines are read from a running daemon (kinhin daemon install)")
            }
            var options = PipelineCommand.Options()
            options.json = true
            options.vm = try stringArgument("vm", in: arguments)
            options.job = try stringArgument("job", in: arguments)
            return Data(try PipelineCommand.render(options, client: RPCClient()).utf8)
        }
    )

    static let logs = MCPTool(
        name: "logs",
        description:
            "Recent lines from the log file (…/Kinhin/logs/kinhin.log), redacted for tokens — the history behind `kinhin logs`.",
        inputSchema: .only([
            "limit": .init(type: "integer", description: "Trailing lines to return (default 50, max 5000).")
        ]),
        run: { arguments in
            let limit = try intArgument("limit", in: arguments) ?? 50
            let file = Paths.logsDirectory.appendingPathComponent("kinhin.log")
            let tail = SupportBundle.tail(of: file, lines: max(1, min(limit, 5000)))
            let lines = tail.isEmpty ? [] : tail.components(separatedBy: "\n").map { Log.redact($0) }
            return try mcpEncode(MCPLogDocument(lines: lines, path: file.path, count: lines.count))
        }
    )

    static let pause = MCPTool(
        name: "pause",
        description:
            "Hold the fleet: stop scaling while queued jobs wait (same as `kinhin pause`). Needs a running daemon.",
        inputSchema: InputSchema(),
        run: { _ in try mcpEncode(MCPMessage(message: try await RunCommands.control(.pause))) }
    )

    static let resume = MCPTool(
        name: "resume",
        description: "Let the fleet scale again (same as `kinhin resume`). Needs a running daemon.",
        inputSchema: InputSchema(),
        run: { _ in try mcpEncode(MCPMessage(message: try await RunCommands.control(.resume))) }
    )

    static let stop = MCPTool(
        name: "stop",
        description: "Stop the daemon's fleet (same as `kinhin stop`). Stops scaling; it does not reset anything.",
        inputSchema: InputSchema(),
        run: { _ in try mcpEncode(MCPMessage(message: try await RunCommands.control(.stop))) }
    )

    static let daemonInstall = MCPTool(
        name: "daemon_install",
        description:
            "Install and start the headless LaunchAgent daemon (same as `kinhin daemon install`); refuses a debug build.",
        inputSchema: InputSchema(),
        run: { _ in
            try await RunCommands.installLaunchAgent()
            return try mcpEncode(MCPMessage(message: "daemon installed and started"))
        }
    )
}

// MARK: - Argument decoding

/// The tool arguments as a dictionary, or nil when the call carried none.
private func argumentObject(_ arguments: Data?) throws -> [String: Any]? {
    guard let arguments else { return nil }
    let value = try JSONSerialization.jsonObject(with: arguments)
    guard let object = value as? [String: Any] else {
        throw MCPToolError("arguments must be a JSON object")
    }
    return object
}

private func stringArgument(_ key: String, in arguments: Data?) throws -> String? {
    guard let object = try argumentObject(arguments), let value = object[key] else { return nil }
    guard let string = value as? String else { throw MCPToolError("'\(key)' must be a string") }
    return string
}

private func boolArgument(_ key: String, in arguments: Data?) throws -> Bool? {
    guard let object = try argumentObject(arguments), let value = object[key] else { return nil }
    guard let flag = value as? Bool else { throw MCPToolError("'\(key)' must be a boolean") }
    return flag
}

private func intArgument(_ key: String, in arguments: Data?) throws -> Int? {
    guard let object = try argumentObject(arguments), let value = object[key] else { return nil }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
        throw MCPToolError("'\(key)' must be an integer")
    }
    return number.intValue
}

/// The encoder the machine-readable commands use (pretty, sorted keys), so MCP
/// payloads match the CLI's `--json` documents byte for byte.
private func mcpEncode<T: Encodable>(_ value: T) throws -> Data {
    try CLIJSON.data(value)
}
