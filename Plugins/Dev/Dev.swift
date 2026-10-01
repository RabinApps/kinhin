import Foundation
import PackagePlugin

/// `swift package --disable-sandbox dev [--env-tokens] [app arguments]`: the
/// package's `npm run dev`. Runs scripts/dev-run.sh from the package root. The
/// sandbox has to be off because the script signs the binary and launches the app.
@main
struct Dev: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        // Build through the plugin API: a `swift build` run by the script would wait
        // forever on the package lock this command holds.
        let build = try packageManager.build(.product("kinhin-app"), parameters: .init(configuration: .debug))
        guard build.succeeded else {
            throw DevError.buildFailed(build.logText)
        }

        guard let binary = build.builtArtifacts.first(where: { $0.kind == .executable }) else {
            throw DevError.buildFailed("no executable was produced")
        }

        let script = context.package.directoryURL.appending(path: "scripts/dev-run.sh")
        let process = Process()
        process.executableURL = script
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["KINHIN_APP_BIN": binary.url.path(percentEncoded: false)]) { _, new in new }
        process.currentDirectoryURL = context.package.directoryURL
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DevError.failed(process.terminationStatus)
        }
    }
}

enum DevError: Error, CustomStringConvertible {
    case failed(Int32)
    case buildFailed(String)

    var description: String {
        switch self {
        case .failed(let status): "scripts/dev-run.sh exited with status \(status)"
        case .buildFailed(let log): "swift build failed:\n\(log)"
        }
    }
}
