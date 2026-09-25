import Foundation

// MARK: - Catalog

public enum ToolchainCatalog {
    /// Root tool of a mise spec: "go@1.23.4" → "go"; "java@temurin-17" → "java".
    public static func rootTool(of spec: String) -> String {
        guard let at = spec.firstIndex(of: "@") else { return spec }
        return String(spec[..<at])
    }

    public static func tool(id: String) -> ToolchainEntry? {
        tools.first { $0.id == id }
    }

    public static func stack(id: String) -> ToolchainStack? {
        stacks.first { $0.id == id }
    }
}
