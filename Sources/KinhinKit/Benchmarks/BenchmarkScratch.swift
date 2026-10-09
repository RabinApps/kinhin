import Foundation

/// The per-run host scratch directory: generated sources and payloads live
/// under `<bench root>/<run id>/` (0700, files 0600) and are removed whole
/// after the run unless the caller asked to keep them.
struct BenchmarkScratch: Sendable {
    let root: URL

    init(benchRoot: URL, runID: String) {
        root = benchRoot.appendingPathComponent(runID, isDirectory: true)
    }

    func create() throws {
        try Paths.createPrivateDirectory(root)
    }

    /// Writes a generated file under the scratch directory (0600, atomic).
    @discardableResult
    func write(_ contents: Data, to relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try Paths.createPrivateDirectory(url.deletingLastPathComponent())
        try Paths.writePrivateFile(contents, to: url)
        return url
    }

    /// Removes the directory; a missing one is already clean.
    func remove() {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        bestEffort("bench", "removing scratch directory \(root.lastPathComponent)") {
            try FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Generated sources

    /// A small Swift package: `files` library sources plus an executable.
    /// Written once on the host, shipped into guests as a single script.
    static func swiftPackageFiles(count: Int, product: String = "BenchLib") -> [(path: String, contents: String)] {
        var files: [(String, String)] = [
            (
                "Package.swift",
                """
                // swift-tools-version:5.9
                import PackageDescription
                let package = Package(
                    name: "BenchPkg",
                    products: [.library(name: "\(product)", targets: ["BenchLib"])],
                    targets: [
                        .target(name: "BenchLib"),
                        .executableTarget(name: "BenchApp", dependencies: ["BenchLib"]),
                    ])

                """
            ),
            ("Sources/BenchApp/main.swift", "import BenchLib\nprint(gen0(1))\n"),
        ]
        for index in 0..<max(count, 1) {
            files.append(
                (
                    "Sources/BenchLib/Gen\(index).swift",
                    """
                    public func gen\(index)(_ x: Int) -> Int {
                        var total = x
                        for step in 0..<10 { total = total &* 31 &+ step &+ \(index) }
                        return total
                    }

                    """
                ))
        }
        return files
    }
}
