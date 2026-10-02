import XCTest

@testable import KinhinKit

final class BuildFileVersionProbeTests: XCTestCase {
    private func specs(_ files: [String: String]) throws -> [String] {
        try ProjectFixture(files).detect().specs
    }

    func testProjectVersionsBecomeSpecs() throws {
        let found = try specs([
            "package.json":
                #"{"engines":{"node":"22"},"devDependencies":{"typescript":"^5.4.2","eslint":"workspace:*"}}"#,
            "go.mod": "module x\n\ngo 1.22\ntoolchain go1.22.5\n",
            "Cargo.toml": "[package]\nrust-version = \"1.75\"\n",
            "Pipfile": "[requires]\npython_version = \"3.11\"\n",
            "mix.exs": "def project, do: [elixir: \"~> 1.15\"]",
            "main.tf": "terraform {\n  required_version = \"~> 1.5\"\n}\n",
            "build.gradle.kts":
                "kotlin { jvmToolchain(17) }\nplugins { id(\"org.jetbrains.kotlin.jvm\") version \"1.9.22\" }",
            "gradle/wrapper/gradle-wrapper.properties":
                "distributionUrl=https\\://services.gradle.org/distributions/gradle-8.5-bin.zip",
        ])
        for expected in [
            "node@22", "typescript@5.4", "eslint", "go@1.22.5", "rust@1.75", "python@3.11", "elixir@1.15",
            "terraform@1.5", "java@17", "kotlin@1.9.22", "gradle@8.5",
        ] {
            XCTAssertTrue(found.contains(expected), "missing \(expected) in \(found)")
        }
    }

    func testMavenCompilerLevelAndWrapper() throws {
        let found = try specs([
            "pom.xml": "<properties><maven.compiler.source>1.8</maven.compiler.source></properties>",
            ".mvn/wrapper/maven-wrapper.properties": "distributionUrl=https://x/apache-maven-3.9.6-bin.zip",
        ])
        XCTAssertTrue(found.contains("java@8"))
        XCTAssertTrue(found.contains("maven@3.9.6"))
    }

    func testFlutterPinsFromFvmThenPubspecAndDartRange() throws {
        let fvm = try ProjectFixture([
            ".fvmrc": #"{"flutter":"3.24.1"}"#,
            "pubspec.yaml": "environment:\n  flutter: \">=3.19.0\"\ndependencies:\n  flutter:\n    sdk: flutter\n",
        ]).detect()
        XCTAssertEqual(fvm.stacks, ["flutter@3.24.1"])
        let pubspec = try ProjectFixture([
            "pubspec.yaml": "environment:\n  flutter: \">=3.19.0\"\ndependencies:\n  flutter:\n    sdk: flutter\n"
        ]).detect()
        XCTAssertEqual(pubspec.stacks, ["flutter@3.19.0"])
        XCTAssertEqual(try specs(["pubspec.yaml": "environment:\n  sdk: \">=3.4.0 <4.0.0\"\n"]), ["dart@3.4"])
    }

    func testToolsWithoutVersionSupportStayBare() throws {
        XCTAssertEqual(
            Set(try specs(["composer.json": #"{"require":{"php":"^8.2"}}"#])), ["composer", "php"])
    }
}
