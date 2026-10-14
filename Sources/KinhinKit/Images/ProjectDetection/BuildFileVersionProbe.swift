import Foundation
import Yams

/// Versions a project states inside its build files: Gradle and Maven (JDK,
/// wrapper, Kotlin), `pubspec.yaml`, `mix.exs`, Terraform, Cargo, Pipfile
/// and `runtime.txt`. These add a version to tools the manifest probe only
/// spots, so the toolchain matches what the project builds with.
struct BuildFileVersionProbe: ToolchainProbe {
    let name = "build file versions"

    func hits(in reader: ProjectFileReading) throws -> [ToolchainHit] {
        var out: [ToolchainHit] = []
        func add(_ id: String, stack: Bool = false, _ version: String?, _ source: String, _ what: String) {
            guard let version else { return }
            out.append(
                ToolchainHit(
                    id, stack: stack, version: version, source: source, reason: "\(what) \(version)",
                    precedence: .manifest))
        }

        let gradleFiles = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
        for file in gradleFiles {
            guard let text = try reader.text(file) else { continue }
            add("java", Self.capture(#"JavaLanguageVersion\.of\(\s*(\d+)\s*\)"#, in: text), file, "Java toolchain")
            add("java", Self.capture(#"jvmToolchain\(\s*(\d+)\s*\)"#, in: text), file, "jvmToolchain")
            add(
                "java",
                Self.capture(#"sourceCompatibility\s*=\s*['"]?(?:JavaVersion\.VERSION_)?(\d+(?:[._]\d+)?)"#, in: text)?
                    .replacingOccurrences(of: "_", with: "."), file, "sourceCompatibility")
            add(
                "kotlin", Self.capture(#"org\.jetbrains\.kotlin[^\n]*version\s*['"]([\d.]+)['"]"#, in: text), file,
                "Kotlin plugin")
            add(
                "kotlin", Self.capture(#"kotlin\(\s*"[^"]+"\s*\)\s*version\s*"([\d.]+)""#, in: text), file,
                "Kotlin plugin")
        }
        if let text = try reader.text("gradle/wrapper/gradle-wrapper.properties") {
            add(
                "gradle", Self.capture(#"gradle-([\d.]+)-(?:bin|all)\.zip"#, in: text),
                "gradle/wrapper/gradle-wrapper.properties", "wrapper")
        }
        if let text = try reader.text(".mvn/wrapper/maven-wrapper.properties") {
            add(
                "maven", Self.capture(#"apache-maven-([\d.]+)-bin"#, in: text), ".mvn/wrapper/maven-wrapper.properties",
                "wrapper")
        }
        if let text = try reader.text("pom.xml") {
            let java =
                Self.capture(#"<maven\.compiler\.release>\s*(\d+)\s*<"#, in: text)
                ?? Self.capture(#"<java\.version>\s*(\d+(?:\.\d+)?)\s*<"#, in: text)
                ?? Self.capture(#"<maven\.compiler\.(?:source|target)>\s*(\d+(?:\.\d+)?)\s*<"#, in: text)
            add("java", java, "pom.xml", "compiler level")
        }

        if let text = try reader.text("mix.exs") {
            add("elixir", Self.capture(#"elixir:\s*"([^"]+)""#, in: text), "mix.exs", "elixir requirement")
        }
        if let text = try reader.text("Cargo.toml") {
            add("rust", Self.capture(#"(?m)^\s*rust-version\s*=\s*"([^"]+)""#, in: text), "Cargo.toml", "rust-version")
        }
        if let text = try reader.text("Pipfile") {
            add(
                "python", Self.capture(#"python_(?:full_)?version\s*=\s*"([^"]+)""#, in: text), "Pipfile",
                "python_version")
        }
        if let text = try reader.text("runtime.txt") {
            add("python", Self.capture(#"python-([\d.]+)"#, in: text), "runtime.txt", "runtime")
        }

        for file in try reader.rootFiles(withSuffix: ".tf") {
            guard let text = try reader.text(file) else { continue }
            add("terraform", Self.capture(#"required_version\s*=\s*"([^"]+)""#, in: text), file, "required_version")
        }

        out.append(contentsOf: try pubspec(reader))
        return out
    }

    // MARK: - Flutter and Dart

    /// `.fvmrc` / fvm config pin Flutter exactly; otherwise `pubspec.yaml`'s
    /// `environment:` constraint is the floor (Flutter) or the Dart SDK range.
    private func pubspec(_ reader: ProjectFileReading) throws -> [ToolchainHit] {
        var out: [ToolchainHit] = []
        func hit(_ id: String, stack: Bool, _ version: String, _ source: String, _ what: String) {
            out.append(
                ToolchainHit(
                    id, stack: stack, version: version, source: source, reason: "\(what) \(version)",
                    precedence: source.hasPrefix(".fvm") ? .versionFile : .manifest))
        }
        if let data = try reader.read(".fvmrc") ?? reader.read(".fvm/fvm_config.json"),
            // An invalid FVM file only loses the Flutter version hint.
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let version = (json["flutter"] ?? json["flutterSdkVersion"]) as? String
        {
            hit(
                "flutter", stack: true, version, reader.exists(".fvmrc") ? ".fvmrc" : ".fvm/fvm_config.json",
                "fvm pins Flutter")
        }
        // Invalid pubspec.yaml only loses the version hints; detection is advisory.
        guard let text = try reader.text("pubspec.yaml"), let root = try? Yams.compose(yaml: text),
            let environment = root.mapping?["environment"]?.mapping
        else { return out }
        if text.contains("sdk: flutter") {
            if let flutter = environment["flutter"]?.string {
                hit("flutter", stack: true, flutter, "pubspec.yaml", "environment.flutter")
            }
        } else if let dart = environment["sdk"]?.string {
            hit("dart", stack: false, dart, "pubspec.yaml", "environment.sdk")
        }
        return out
    }

    // MARK: - Regex

    /// Group 1 of the first match.
    static func capture(_ pattern: String, in text: String) -> String? {
        // Patterns are constants from this file; an invalid one would only miss its hint.
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
