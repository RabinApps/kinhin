import Foundation

/// Project manifests, lockfiles and config files in the checkout root.
struct ManifestProbe: ToolchainProbe {
    let name = "manifests"

    /// `package.json` dependencies that map to a catalog npm tool.
    private static let npmTools: [String: String] = [
        "typescript": "typescript", "eslint": "eslint", "prettier": "prettier", "playwright": "playwright",
        "@playwright/test": "playwright", "cypress": "cypress", "turbo": "turbo", "nx": "nx",
        "netlify-cli": "netlify-cli", "firebase-tools": "firebase-tools",
    ]

    func hits(in reader: ProjectFileReading) throws -> [ToolchainHit] {
        var out: [ToolchainHit] = []
        func add(
            _ id: String, stack: Bool = false, version: String? = nil, _ source: String, _ reason: String
        ) {
            out.append(
                ToolchainHit(id, stack: stack, version: version, source: source, reason: reason, precedence: .manifest))
        }
        /// Adds `id` for every root file that exists among `files`.
        func marker(_ id: String, _ files: [String], stack: Bool = false) {
            if let file = files.first(where: { reader.exists($0) }) { add(id, stack: stack, file, "\(file) present") }
        }

        out.append(contentsOf: try packageJSON(reader))

        marker("pnpm", ["pnpm-lock.yaml"])
        marker("yarn", ["yarn.lock"])
        marker("bun", ["bun.lockb", "bun.lock"])
        marker("deno", ["deno.json", "deno.jsonc"])
        marker("netlify-cli", ["netlify.toml"])
        marker("firebase-tools", ["firebase.json"])
        marker("vercel", ["vercel.json"], stack: true)
        marker("cloudflare", ["wrangler.toml", "wrangler.jsonc", "wrangler.json"], stack: true)
        marker("cmake", ["CMakeLists.txt"])
        marker("just", ["Justfile", "justfile"])
        marker("task", ["Taskfile.yml", "Taskfile.yaml"])
        marker("helm", ["Chart.yaml"])
        marker("kustomize", ["kustomization.yaml", "kustomization.yml"])
        marker("elixir", ["mix.exs"])
        marker("uv", ["uv.lock"])
        marker("python", ["pyproject.toml", "requirements.txt", "Pipfile", "setup.py"])

        if let text = try reader.text("go.mod"),
            let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("go ") })
        {
            // `toolchain go1.22.5` is the exact version; `go 1.22` is the language floor.
            if let toolchain = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("toolchain go") }) {
                add(
                    "go", version: String(toolchain.dropFirst("toolchain go".count)).trimmed(), "go.mod",
                    "toolchain directive")
            }
            add("go", version: String(line.dropFirst(3)).trimmed(), "go.mod", "go directive")
        } else if reader.exists("go.mod") {
            add("go", "go.mod", "go.mod present")
        }

        if let text = try reader.text("Package.swift") {
            // `// swift-tools-version: 6.4` (the minimum the package needs; the closest pin SwiftPM offers).
            let version = text.split(whereSeparator: \.isNewline).first.flatMap { Self.toolsVersion(in: String($0)) }
            add(
                "swift", version: version, "Package.swift",
                version.map { "swift-tools-version \($0)" } ?? "Package.swift present")
        }

        if reader.exists("Cargo.toml") { add("rust", "Cargo.toml", "Cargo.toml present") }
        for file in ["rust-toolchain.toml", "rust-toolchain"] {
            guard let text = try reader.text(file) else { continue }
            let channel =
                text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                    let line = String(line).strippingComment()
                    if line.hasPrefix("channel") { return line.split(separator: "=").last.map { Self.unquote($0) } }
                    return file == "rust-toolchain" && !line.isEmpty && !line.hasPrefix("[") ? line : nil
                }.first
            add("rust", version: channel, file, channel.map { "\(file) channel \($0)" } ?? "\(file) present")
        }

        if let text = try reader.text("pyproject.toml"), let line = Self.tomlLine("requires-python", in: text) {
            add("python", version: line, "pyproject.toml", "requires-python \(line)")
        }
        if let text = try reader.text("pyproject.toml"), text.contains("[tool.uv") {
            add("uv", "pyproject.toml", "[tool.uv] section")
        }

        if let text = try reader.text("Gemfile") {
            let version = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let line = String(line).trimmed()
                guard line.hasPrefix("ruby ") else { return nil }
                return Self.quoted(in: line)
            }.first
            add("ruby", version: version, "Gemfile", version.map { "Gemfile ruby \($0)" } ?? "Gemfile present")
            if text.contains("fastlane") { add("fastlane", "Gemfile", "Gemfile lists fastlane") }
        }
        if reader.exists("fastlane/Fastfile") { add("fastlane", "fastlane/Fastfile", "fastlane/Fastfile present") }

        if let text = try reader.text("pubspec.yaml") {
            let flutter = text.contains("sdk: flutter")
            add(flutter ? "flutter" : "dart", stack: flutter, "pubspec.yaml", "pubspec.yaml present")
        }

        let gradleFiles = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
        // Kotlin Multiplatform often applies the plugin only in its shared and Android modules, so read those too.
        let moduleGradleFiles = [
            "shared/build.gradle.kts", "shared/build.gradle", "androidApp/build.gradle.kts", "androidApp/build.gradle",
        ]
        if let file = gradleFiles.first(where: { reader.exists($0) }) {
            add("java", file, "\(file) present")
            add("gradle", file, "\(file) present")
            let text = try (gradleFiles + moduleGradleFiles).compactMap { try reader.text($0) }.joined(separator: "\n")
            if text.contains("org.jetbrains.kotlin") || text.contains("kotlin(") {
                add("kotlin", file, "Kotlin Gradle plugin")
            }
        }
        if reader.exists("pom.xml") {
            add("java", "pom.xml", "pom.xml present")
            add("maven", "pom.xml", "pom.xml present")
        }
        if reader.exists("build.sbt") {
            add("scala", "build.sbt", "build.sbt present")
            add("sbt", "build.sbt", "build.sbt present")
        }

        if let data = try reader.read("composer.json") {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let php = (json?["require"] as? [String: Any])?["php"] as? String
            add(
                "php", version: php, "composer.json",
                php.map { "composer.json requires php \($0)" } ?? "composer.json present")
            add("composer", "composer.json", "composer.json present")
        }

        if let file = try reader.rootFiles(withSuffix: ".csproj", ".fsproj", ".sln").first {
            add("dotnet", file, "\(file) present")
        } else if let file = try mauiProject(reader) {
            // A .NET MAUI app keeps its .csproj one folder down in some layouts (App/App.csproj).
            add("dotnet", file, "\(file) uses .NET MAUI")
        } else if reader.exists("global.json") {
            add("dotnet", "global.json", "global.json present")
        }

        if try reader.list("").contains(where: { $0 == "Dockerfile" || $0.hasPrefix("Dockerfile.") }) {
            add("hadolint", "Dockerfile", "Dockerfile present")
        }
        if let file = try reader.rootFiles(withSuffix: ".tf").first { add("terraform", file, "\(file) present") }
        return out
    }

    // MARK: - package.json

    private func packageJSON(_ reader: ProjectFileReading) throws -> [ToolchainHit] {
        guard let data = try reader.read("package.json") else { return [] }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            Log.warn("Detect", "skipping package.json: not a JSON object")
            return []
        }
        var out: [ToolchainHit] = []
        func add(_ id: String, _ stack: Bool, _ version: String?, _ source: String, _ reason: String) {
            out.append(
                ToolchainHit(id, stack: stack, version: version, source: source, reason: reason, precedence: .manifest))
        }
        let node = (json["engines"] as? [String: Any])?["node"] as? String
        add("node", false, node, "package.json", node.map { "engines.node \($0)" } ?? "package.json present")

        // "pnpm@9.1.0+sha512.…": the version ends at `+`.
        if let manager = json["packageManager"] as? String {
            let parts = manager.split(separator: "@", maxSplits: 1).map(String.init)
            if parts.count == 2, ["pnpm", "yarn", "bun"].contains(parts[0]) {
                let version = parts[1].split(separator: "+").first.map(String.init)
                add(parts[0], false, version, "package.json", "packageManager \(manager.split(separator: "+")[0])")
            }
        }

        var versions: [String: String] = [:]
        for section in ["dependencies", "devDependencies"] {
            for (name, value) in json[section] as? [String: Any] ?? [:] { versions[name] = value as? String ?? "" }
        }
        let dependencies = Set(versions.keys)
        for name in dependencies.sorted() {
            if let tool = Self.npmTools[name] {
                add(tool, false, versions[name], "package.json", "depends on \(name)")
            }
        }
        if let volta = (json["volta"] as? [String: Any])?["node"] as? String {
            add("node", false, volta, "package.json", "volta pins node")
        }
        if dependencies.contains("expo") {
            add("expo", true, nil, "package.json", "depends on expo")
        } else if dependencies.contains("react-native") {
            add("react-native", true, nil, "package.json", "depends on react-native")
        }
        if dependencies.contains("vercel") {
            add("vercel", true, versions["vercel"], "package.json", "depends on vercel")
        }
        if dependencies.contains("wrangler") {
            add("cloudflare", true, versions["wrangler"], "package.json", "depends on wrangler")
        }
        return out
    }

    // MARK: - Text helpers

    /// The path of a .csproj that sets UseMaui, one folder below the root.
    private func mauiProject(_ reader: ProjectFileReading) throws -> String? {
        for folder in try reader.list("") {
            for name in try reader.list(folder) where name.hasSuffix(".csproj") {
                let path = "\(folder)/\(name)"
                if try reader.text(path)?.contains("<UseMaui>true</UseMaui>") == true { return path }
            }
        }
        return nil
    }

    private static func unquote<S: StringProtocol>(_ value: S) -> String {
        value.trimmed().trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// The value of a top-level `key = "value"` TOML line.
    private static func tomlLine(_ key: String, in text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).strippingComment()
            guard line.hasPrefix(key), let eq = line.firstIndex(of: "=") else { continue }
            guard line[..<eq].trimmed() == key else { continue }
            return unquote(line[line.index(after: eq)...])
        }
        return nil
    }

    /// The version in a `swift-tools-version` comment line.
    static func toolsVersion(in line: String) -> String? {
        guard let range = line.range(of: "swift-tools-version") else { return nil }
        let rest = line[range.upperBound...].drop { !$0.isNumber }
        let version = rest.prefix { $0.isNumber || $0 == "." }
        return version.isEmpty ? nil : String(version)
    }

    private static func quoted(in line: String) -> String? {
        guard let open = line.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        let rest = line[line.index(after: open)...]
        guard let close = rest.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        return String(rest[..<close])
    }
}
