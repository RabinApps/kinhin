// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "kinhin",
    // The app's String Catalog (Resources/Localizable.xcstrings) is authored in English.
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "kinhin", targets: ["kinhin"]),
        .executable(name: "kinhin-app", targets: ["kinhin-app"]),
        .library(name: "KinhinKit", targets: ["KinhinKit"]),
    ],
    dependencies: [
        // YAML parsing for the config file.
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
        // Self-updater for the menu bar app (download, EdDSA check, in-place install, relaunch).
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.10.0"),
        // OpenTelemetry (opt-in metrics, traces and logs over OTLP, local Prometheus endpoint). The SDK and
        // the OTLP/Prometheus exporters are pinned exactly: metrics and logs are still maturing upstream.
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core.git", exact: "2.6.0"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", exact: "2.6.0"),
        // The gRPC channel the OTLP gRPC exporters take (same pin as opentelemetry-swift's own).
        .package(url: "https://github.com/grpc/grpc-swift.git", exact: "1.27.6"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    ],
    targets: [
        // `swift package --disable-sandbox dev`: runs scripts/dev-run.sh.
        .plugin(
            name: "Dev",
            capability: .command(
                intent: .custom(verb: "dev", description: "Build, sign and run the debug menu bar app"),
                permissions: []
            ),
            path: "Plugins/Dev"
        ),
        // Shared engine library (no UI).
        .target(
            name: "KinhinKit",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetryProtocolExporter", package: "opentelemetry-swift"),
                .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
                .product(name: "PrometheusExporter", package: "opentelemetry-swift"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources/KinhinKit"
        ),
        // Menu bar application.
        .executableTarget(
            name: "kinhin-app",
            dependencies: [
                "KinhinKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/kinhin-app",
            // Forge brand marks and the String Catalog; scripts/build-app.sh
            // copies the resulting bundle into the .app (see ForgeIcon) and
            // hoists its *.lproj folders into the app's own Resources so
            // `Bundle.main` resolves localized strings.
            resources: [
                .copy("Resources/ForgeIcons"),
                .process("Resources/Localizable.xcstrings"),
            ]
        ),
        // Headless CLI.
        .executableTarget(
            name: "kinhin",
            dependencies: ["KinhinKit"],
            path: "Sources/kinhin"
        ),
        // Doubles shared by all three test targets (fake shells, tart, forges).
        // Depends on KinhinKit via @testable, so it is built for testing only;
        // release scripts build products explicitly (`--product`).
        .target(
            name: "KinhinTestSupport",
            dependencies: ["KinhinKit"],
            path: "Tests/KinhinTestSupport"
        ),
        .testTarget(
            name: "KinhinKitTests",
            dependencies: ["KinhinKit", "KinhinTestSupport"],
            path: "Tests/KinhinKitTests"
        ),
       // Executable targets are importable from tests when their entry
        // point is declared with @main (not a main.swift file).
        .testTarget(
            name: "KinhinCLITests",
            dependencies: ["kinhin", "KinhinTestSupport"],
            path: "Tests/KinhinCLITests"
        ),
        .testTarget(
            name: "KinhinAppTests",
            dependencies: ["kinhin-app", "KinhinTestSupport"],
            path: "Tests/KinhinAppTests",
            // The test bundle loads Sparkle through kinhin-app. Its @rpath entries do not reach the
            // artifact (SwiftPM copies the framework only for some products; Swift 6.3 on CI does not
            // copy it next to the test products), so the test binary gets the xcframework slice directly.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker",
                    "\(Context.packageDirectory)/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64",
                ])
            ]
        ),
    ],
    // Strict concurrency on: every mutable field is Mutex-guarded or an
    // immutable Sendable collaborator, so the compiler verifies isolation.
    swiftLanguageModes: [.v6]
)
