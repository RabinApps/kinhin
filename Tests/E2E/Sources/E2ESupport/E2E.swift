import Darwin
import Foundation

/// What this machine can run, and which parts of the suite the operator switched on.
public enum E2E {
    /// `KINHIN_E2E=1`: the whole suite is opt-in. Without it every test is disabled, so an accidental
    /// `swift test` in this package does nothing.
    public static let enabled = ProcessInfo.processInfo.environment["KINHIN_E2E"] == "1"

    public static func flag(_ name: String) -> String? {
        let value = ProcessInfo.processInfo.environment[name]
        return (value?.isEmpty ?? true) ? nil : value
    }

    public static let dockerAvailable = Shell.available("docker", ["info", "--format", "{{.ServerVersion}}"])
    public static let appleContainerAvailable = Shell.available("container", ["system", "status"])
    public static let tartAvailable = Shell.available("tart", ["--version"])

    /// `KINHIN_E2E_FORGES=gitea,forgejo` narrows the lifecycle matrix; unset runs every forge that is available.
    public static func selected(_ variable: String, _ name: String) -> Bool {
        guard let list = flag(variable) else { return true }
        return list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(name)
    }

    /// The root of this repository, found from this file's location (Tests/E2E/Sources/E2ESupport/E2E.swift).
    public static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    /// The `kinhin` binary under test. It must be a debug build: only debug builds read tokens from the environment
    /// (`KINHIN_TOKEN_STORE=env`), which keeps the suite off the real Keychain.
    public static let kinhinBinary: String = {
        if let override = flag("KINHIN_E2E_BIN") { return override }
        return repoRoot.appendingPathComponent(".build/debug/kinhin").path
    }()

    /// The Mac's address on the local network. Containers cannot reach the host's `localhost`, so forges started by
    /// the suite are addressed through this (plain http, which kinhin allows only with `allow_insecure_http`).
    public static let lanAddress: String? = {
        for interface in ["en0", "en1", "en2"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
            process.arguments = ["getifaddr", interface]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0, !text.isEmpty { return text }
        }
        return nil
    }()

    /// A currently free TCP port on this machine.
    public static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw E2EError.failed("socket() failed") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY.bigEndian
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw E2EError.failed("bind() failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw E2EError.failed("getsockname() failed") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    public static func randomID() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(6))
    }
}
